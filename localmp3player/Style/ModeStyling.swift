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

    /// Paints list/scroll surfaces with the themed background instead of the
    /// system one, so custom colours reach the whole screen.
    @ViewBuilder
    func themedScrollBackground(_ theme: AppTheme) -> some View {
        scrollContentBackground(.hidden)
            .background(theme.background)
    }
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
