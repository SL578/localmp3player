import SwiftUI

/// The single styling seam between Standard and Performance mode. Views stay
/// identical; only these modifiers change what actually gets rendered.
extension View {
    /// Background for app-owned chrome that sits above content (bottom bar, panels).
    /// Standard uses a translucent material; Performance paints an opaque color so
    /// the GPU never composites a blur.
    @ViewBuilder
    func modePanelBackground(_ mode: UIMode, theme: AppTheme) -> some View {
        if mode.usesMaterials {
            background(.regularMaterial)
        } else {
            background(theme.surface)
        }
    }

    /// Applies the mode's animation. Performance mode passes nil, so state
    /// changes cut straight to the new value with no interpolated frames.
    @ViewBuilder
    func modeAnimation<V: Equatable>(_ mode: UIMode, value: V) -> some View {
        animation(mode.animation, value: value)
    }

    /// Blanket kill-switch for implicit animations in Performance mode — covers
    /// transitions the app never names explicitly, including ones SwiftUI would
    /// start on its own for list and navigation changes.
    ///
    /// Deliberately *not* an `if/else` returning `self` on one side. A branch in a
    /// `@ViewBuilder` compiles to `_ConditionalContent`, and switching branches is
    /// a change of structural identity — SwiftUI throws the subtree away and
    /// rebuilds it with fresh `@State`. This sits at the root wrapping `RootView`,
    /// so that reset the selected tab back to Library every time the mode changed.
    /// One unconditional modifier keeps identity stable; only its body varies.
    func modeTransactions(_ mode: UIMode) -> some View {
        let disablesAnimation = !mode.usesAnimation
        return transaction { transaction in
            guard disablesAnimation else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    func modeCard(_ mode: UIMode, theme: AppTheme) -> some View {
        if mode.usesMaterials {
            background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Shadows are pure compositing cost, so Performance mode drops them entirely.
    @ViewBuilder
    func modeShadow(_ mode: UIMode, radius: CGFloat) -> some View {
        if mode.usesMaterials {
            shadow(color: .black.opacity(0.18), radius: radius, y: radius / 3)
        } else {
            self
        }
    }

    /// Performance mode pins an opaque navigation bar so scrolling content never
    /// blurs through it. Only safe on inline titles — a visible toolbar
    /// background hides a large navigation title on iOS 26.
    @ViewBuilder
    func modeNavigationChrome(_ mode: UIMode, theme: AppTheme) -> some View {
        if mode.usesMaterials {
            self
        } else {
            toolbarBackground(theme.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// Marks a button that lives *inside* a list or form as an action rather than
    /// a label — New Playlist, Add Tags or Artists, and friends.
    ///
    /// `themedScrollBackground` puts the palette's text colour on list content,
    /// and an explicit foreground style beats `.tint`, so without this these
    /// buttons come out the same colour as the text beside them. Stated per
    /// button on purpose: doing it with a `ButtonStyle` on the list instead put a
    /// custom style in every row's environment, and `swipeActions` then produced
    /// no actions at all — every swipe in the app silently stopped revealing
    /// anything while scrolling carried on working.
    func accentAction(_ theme: AppTheme) -> some View {
        foregroundStyle(theme.accent)
    }

    /// Hands the resolved palette to a sheet. A sheet is presented into its own
    /// context, so this is stated rather than relied on.
    func themedSheet(_ theme: AppTheme) -> some View {
        environment(\.theme, theme)
    }

    /// Paints list/scroll surfaces with the themed background instead of the
    /// system one, and applies the palette to the content sitting on them.
    ///
    /// The text colour lives here rather than at the app root because an explicit
    /// foreground style outranks `.tint`: set any higher, it also repaints the
    /// navigation bar's buttons, and Cancel/Save/Select stop looking tappable.
    /// Scoping it to the content leaves toolbars to the tint, the way iOS
    /// expects. Buttons *inside* the content would otherwise be flattened into
    /// plain text by it, so those state `accentAction` for themselves.
    ///
    /// Only the *primary* style is set. A secondary one passed alongside it also
    /// reaches control chrome and SF Symbol second layers, which made Steppers
    /// and `play.circle.fill` look disabled; secondary text goes through
    /// `.secondaryText()`, which stays scoped to text.
    @ViewBuilder
    func themedScrollBackground(_ theme: AppTheme) -> some View {
        scrollContentBackground(.hidden)
            .background(theme.background)
            .foregroundStyle(theme.primaryText)
    }
}

/// Secondary/tertiary text that follows the user's own palette.
///
/// These exist so the app never has to set a global *secondary* foreground style.
/// That style is not text-only: SwiftUI also paints control chrome with it — a
/// Stepper's +/- background came out in the secondary colour and read as
/// disabled — and SF Symbols use it for their second layer. Scoping it to text
/// keeps the user's colour choice working without repainting controls.
private struct ThemedTextStyle: ViewModifier {
    @Environment(\.theme) private var theme
    let opacity: Double

    func body(content: Content) -> some View {
        content.foregroundStyle(theme.secondaryText.opacity(opacity))
    }
}

extension View {
    func secondaryText() -> some View { modifier(ThemedTextStyle(opacity: 1)) }
    func tertiaryText() -> some View { modifier(ThemedTextStyle(opacity: 0.6)) }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum TimeFormatting {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
