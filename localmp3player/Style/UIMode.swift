import Combine
import SwiftUI

enum UIMode: String, CaseIterable, Identifiable {
    case standard
    case performance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .performance: return "Performance"
        }
    }

    var detail: String {
        switch self {
        case .standard:
            return "Normal iOS polish — system materials and expressive transitions."
        case .performance:
            return "Flat colors, no blur, glass, shadows, or animation. The lightest possible draw on battery and CPU."
        }
    }

    var systemImage: String {
        switch self {
        case .standard: return "sparkles"
        case .performance: return "bolt.fill"
        }
    }

    /// Every animation in the app routes through here, so Performance Mode can
    /// flatten the whole app without touching individual views. Performance
    /// returns nil — nothing animates, nothing is interpolated frame by frame.
    var animation: Animation? {
        switch self {
        case .standard: return .snappy(duration: 0.28)
        case .performance: return nil
        }
    }

    var usesAnimation: Bool { self == .standard }

    var usesMaterials: Bool { self == .standard }
}

private struct UIModeKey: EnvironmentKey {
    static let defaultValue: UIMode = .standard
}

extension EnvironmentValues {
    var uiMode: UIMode {
        get { self[UIModeKey.self] }
        set { self[UIModeKey.self] = newValue }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let uiMode = "uiMode"
        static let songSort = "songSort"
    }

    @Published var uiMode: UIMode {
        didSet { UserDefaults.standard.set(uiMode.rawValue, forKey: Keys.uiMode) }
    }

    @Published var songSort: SongSort {
        didSet { UserDefaults.standard.set(songSort.rawValue, forKey: Keys.songSort) }
    }

    init() {
        let storedMode = UserDefaults.standard.string(forKey: Keys.uiMode)
        uiMode = storedMode.flatMap(UIMode.init(rawValue:)) ?? .standard
        let storedSort = UserDefaults.standard.string(forKey: Keys.songSort)
        songSort = storedSort.flatMap(SongSort.init(rawValue:)) ?? .title
    }
}
