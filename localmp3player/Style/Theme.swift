import Combine
import SwiftUI
import UIKit

// MARK: - Appearance

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    /// Follows the clock rather than the system setting.
    case dynamic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .dynamic: return "Dynamic"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "iphone"
        case .light: return "sun.max"
        case .dark: return "moon"
        case .dynamic: return "clock"
        }
    }

    var detail: String {
        switch self {
        case .system: return "Follows the iOS appearance setting."
        case .light: return "Always light."
        case .dark: return "Always dark."
        case .dynamic: return "Light during the day, dark at night."
        }
    }
}

/// Time-of-day rule for `.dynamic`. Kept as fixed hours rather than real sunrise
/// times so the app never needs location access or a network call.
enum DaylightWindow {
    static let lightStartHour = 7
    static let darkStartHour = 19

    static func scheme(at date: Date, calendar: Calendar = .current) -> ColorScheme {
        let hour = calendar.component(.hour, from: date)
        return (hour >= lightStartHour && hour < darkStartHour) ? .light : .dark
    }

    static var summary: String {
        "Dark from \(darkStartHour):00 to \(lightStartHour):00."
    }
}

// MARK: - Color tokens

/// Every colour the app paints itself with. Anything the user can see is one of
/// these, so the colour settings screen can stay a simple loop over the cases.
enum ThemeColorToken: String, CaseIterable, Identifiable {
    case accent
    case background
    case surface
    case primaryText
    case secondaryText
    case separator
    case liked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accent: return "Accent"
        case .background: return "Background"
        case .surface: return "Bars & Cards"
        case .primaryText: return "Primary Text"
        case .secondaryText: return "Secondary Text"
        case .separator: return "Separators"
        case .liked: return "Liked Heart"
        }
    }

    var detail: String {
        switch self {
        case .accent: return "Buttons, links, selected tab"
        case .background: return "Behind every screen"
        case .surface: return "Bottom bar, mini player, cards"
        case .primaryText: return "Song titles and headings"
        case .secondaryText: return "Artists, durations, captions"
        case .separator: return "Row dividers"
        case .liked: return "The like heart"
        }
    }

    func defaultColor(for scheme: ColorScheme) -> Color {
        let hex = scheme == .dark ? darkDefault : lightDefault
        return Color(hex: hex) ?? .gray
    }

    private var lightDefault: String {
        switch self {
        case .accent: return "007AFF"
        case .background: return "FFFFFF"
        case .surface: return "F2F2F7"
        case .primaryText: return "000000"
        case .secondaryText: return "6C6C70"
        case .separator: return "C6C6C8"
        case .liked: return "FF2D55"
        }
    }

    private var darkDefault: String {
        switch self {
        case .accent: return "0A84FF"
        case .background: return "000000"
        case .surface: return "1C1C1E"
        case .primaryText: return "FFFFFF"
        case .secondaryText: return "98989F"
        case .separator: return "38383A"
        case .liked: return "FF375F"
        }
    }
}

/// A fully resolved palette for one colour scheme.
struct AppTheme {
    var scheme: ColorScheme = .light
    var colors: [ThemeColorToken: Color] = [:]

    func color(_ token: ThemeColorToken) -> Color {
        colors[token] ?? token.defaultColor(for: scheme)
    }

    var accent: Color { color(.accent) }
    var background: Color { color(.background) }
    var surface: Color { color(.surface) }
    var primaryText: Color { color(.primaryText) }
    var secondaryText: Color { color(.secondaryText) }
    var separator: Color { color(.separator) }
    var liked: Color { color(.liked) }

    static let fallback = AppTheme()
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.fallback
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - Store

/// Persists the appearance choice and any colour overrides. Overrides are stored
/// per scheme, so light and dark can be customised independently.
@MainActor
final class ThemeStore: ObservableObject {
    private enum Keys {
        static let appearance = "appearance"
        static let overrides = "colorOverrides"
    }

    @Published var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
            refreshDynamicScheme()
        }
    }

    /// Recomputed on a timer so `.dynamic` flips over without a relaunch.
    @Published private(set) var dynamicScheme: ColorScheme

    @Published private var overrides: [String: String] {
        didSet { UserDefaults.standard.set(overrides, forKey: Keys.overrides) }
    }

    private var ticker: Timer?

    init() {
        let stored = UserDefaults.standard.string(forKey: Keys.appearance)
        appearance = stored.flatMap(AppearanceMode.init(rawValue:)) ?? .system
        overrides = UserDefaults.standard.dictionary(forKey: Keys.overrides) as? [String: String] ?? [:]
        dynamicScheme = DaylightWindow.scheme(at: Date())
        startTicker()
    }

    deinit { ticker?.invalidate() }

    /// The scheme the app should actually paint, given the user's choice and the
    /// system setting when they deferred to it.
    func effectiveScheme(system: ColorScheme) -> ColorScheme {
        switch appearance {
        case .system: return system
        case .light: return .light
        case .dark: return .dark
        case .dynamic: return dynamicScheme
        }
    }

    /// Nil lets iOS decide; anything else pins the window.
    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        case .dynamic: return dynamicScheme
        }
    }

    func palette(for scheme: ColorScheme) -> AppTheme {
        var colors: [ThemeColorToken: Color] = [:]
        for token in ThemeColorToken.allCases {
            colors[token] = customColor(token, scheme: scheme) ?? token.defaultColor(for: scheme)
        }
        return AppTheme(scheme: scheme, colors: colors)
    }

    // MARK: Overrides

    func customColor(_ token: ThemeColorToken, scheme: ColorScheme) -> Color? {
        Color(hex: overrides[key(token, scheme: scheme)])
    }

    func color(_ token: ThemeColorToken, scheme: ColorScheme) -> Color {
        customColor(token, scheme: scheme) ?? token.defaultColor(for: scheme)
    }

    func setColor(_ color: Color, for token: ThemeColorToken, scheme: ColorScheme) {
        guard let hex = color.hexString else { return }
        overrides[key(token, scheme: scheme)] = hex
    }

    func isCustomised(_ token: ThemeColorToken, scheme: ColorScheme) -> Bool {
        overrides[key(token, scheme: scheme)] != nil
    }

    func resetColor(_ token: ThemeColorToken, scheme: ColorScheme) {
        overrides.removeValue(forKey: key(token, scheme: scheme))
    }

    func resetAllColors(scheme: ColorScheme) {
        for token in ThemeColorToken.allCases {
            overrides.removeValue(forKey: key(token, scheme: scheme))
        }
    }

    var hasAnyCustomColors: Bool { !overrides.isEmpty }

    private func key(_ token: ThemeColorToken, scheme: ColorScheme) -> String {
        "\(token.rawValue).\(scheme == .dark ? "dark" : "light")"
    }

    // MARK: Dynamic clock

    private func startTicker() {
        ticker?.invalidate()
        // Five minutes is plenty to catch a 7:00/19:00 boundary without waking
        // the CPU often.
        ticker = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshDynamicScheme() }
        }
    }

    func refreshDynamicScheme() {
        let current = DaylightWindow.scheme(at: Date())
        if current != dynamicScheme { dynamicScheme = current }
    }
}

// MARK: - Color <-> hex

extension Color {
    /// sRGB hex, used for persistence. Returns nil for colours that can't be
    /// resolved to concrete components.
    var hexString: String? {
        let resolved = UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        let clamp = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}
