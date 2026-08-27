import SwiftUI

/// The colour a navigation-bar control draws itself in.
///
/// Stated rather than inherited from `.tint`, because UIKit dims the presenting
/// view controller's `tintAdjustmentMode` for as long as anything is presented
/// over it — verified by instrumenting the app: putting up the player flips the
/// root view controller from `.normal` to `.dimmed` and back — and every tinted
/// control greys out with it. That is what turned Shuffle and Import grey while
/// the player slid up.
///
/// **It has to go on the glyph or the text, not on the enclosing `Button`.** A
/// `Text` label inherits a foreground style set on its button; an SF Symbol does
/// not, and stays on the tint. Sort was the one control in the Library's bar
/// that never greyed, and that is why: it was already drawing an `Image` with
/// its own colour stated. Icon buttons should go through `ToolbarGlyph`, which
/// puts it in the right place for you.
///
/// It also has to say what disabled looks like, since taking the colour out of
/// the tint's hands takes the tint's greying-out of a disabled control with it.
private struct ToolbarTint: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? theme.accent : theme.secondaryText.opacity(0.5))
    }
}

extension View {
    /// See `ToolbarTint`. On a text button this can go on the button itself; on
    /// anything drawing a symbol it must go on the `Image`.
    func toolbarTint() -> some View { modifier(ToolbarTint()) }
}

/// One icon button in a navigation bar — the shape every toolbar action in the
/// app takes, with the colour already in the right place.
struct ToolbarGlyph: View {
    private let label: String
    private let systemImage: String
    private let action: () -> Void

    init(_ label: String, systemImage: String, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).toolbarTint()
        }
        .accessibilityLabel(label)
    }
}
