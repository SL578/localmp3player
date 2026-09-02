import SwiftUI

/// Which kind of navigation title a screen carries, so `modeNavigationChrome`
/// knows whether it is allowed to pin the bar.
///
/// Not a styling choice — a statement of fact about the screen. It has to match
/// the screen's actual `navigationBarTitleDisplayMode`, and getting it wrong
/// either hides the title or lets content show through the bar.
enum ModeTitleStyle {
    case inline
    case large
}

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

    /// A symbol that swaps between two names with no transition at all.
    ///
    /// SF Symbols cross-fade by default when the name behind an `Image` changes,
    /// and the play/pause glyph is the one place in the app where that is felt
    /// rather than seen: the button is the direct response to a tap, so a fade
    /// reads as the app hesitating. `contentTransition(.identity)` turns off the
    /// symbol's own interpolation and the nil animation covers any transaction
    /// the change is swept up in, which is why both are stated. Not routed
    /// through `UIMode`: this is instant in *both* modes on purpose.
    func instantSymbolSwap<V: Equatable>(value: V) -> some View {
        contentTransition(.identity)
            .animation(nil, value: value)
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
    /// background hides a large navigation title on iOS 26 — so the caller says
    /// which kind of title it has and gets the best bar available for it.
    ///
    /// The two can't both be had on one screen, and the choice is made per title
    /// style rather than app-wide because dropping `.visible` everywhere
    /// regressed the inline screens: Now Playing's bar went clear, artwork
    /// scrolled up into the status bar, and iOS started restyling the close
    /// chevron against whatever pixels were behind it, in visible steps.
    @ViewBuilder
    func modeNavigationChrome(
        _ mode: UIMode,
        theme: AppTheme,
        title: ModeTitleStyle = .inline
    ) -> some View {
        if mode.usesMaterials {
            self
        } else {
            switch title {
            case .inline:
                // Pinned. Nothing ever shows through, and the bar's own buttons
                // sit on a known colour instead of on the content behind them.
                toolbarBackground(theme.background, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            case .large:
                // Colour stated, visibility left alone: `.visible` here would
                // hide the title outright. The bar is clear at the top of a
                // list, where the themed background is behind it anyway, and
                // takes this colour once content scrolls under it. It is a flat
                // fill either way — no material is ever substituted.
                toolbarBackground(theme.background, for: .navigationBar)
            }
        }
    }
}

extension ToolbarContent {
    /// Strips the Liquid Glass capsule iOS 26 draws behind a navigation-bar item.
    ///
    /// That capsule is a material like any other, and Performance mode already
    /// refuses materials everywhere else — but this one had to be found by
    /// measurement rather than by reading, because it is drawn by the *system*
    /// rather than asked for by the app. **It samples the scroll content behind
    /// the bar, not the bar's own fill**, so `modeNavigationChrome`'s pinned
    /// opaque background does not stop it: the fill under the Now Playing
    /// chevron measured rgb 25 at the top of the scroll, 46 with the artwork
    /// passing behind the bar, and 25 again once the artwork had gone by. In
    /// Standard mode that is a cross-fade and reads as the glass doing its job;
    /// with `UIView.setAnimationsEnabled(false)` it is a hard step, which is
    /// what the user saw as the chevron changing colour while they scrolled.
    ///
    /// Reached through `modeToolbar` rather than called directly, so a screen
    /// cannot declare a toolbar and forget this.
    ///
    /// Stated as a value rather than an `if` on the mode, for the reason in
    /// `modeTransactions`: a branch in a `@ToolbarContentBuilder` is a change of
    /// structural identity, and this sits on items that would otherwise be
    /// rebuilt on every mode change for no gain. The `#available` branch is
    /// fine — it is fixed for the life of the process.
    @ToolbarContentBuilder
    fileprivate func modeToolbarBackground(_ mode: UIMode) -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(mode.usesMaterials ? .automatic : .hidden)
        } else {
            self
        }
    }
}

extension View {
    /// `toolbar`, with the mode's own answer about the bar items' background
    /// already applied. Every toolbar in the app goes through this.
    ///
    /// A wrapper rather than a modifier the caller adds afterwards, because the
    /// thing it turns off is drawn by the system whether or not the app asks for
    /// it: a `.toolbar` written the plain way silently opts back into the
    /// sampling glass. See `modeToolbarBackground` for what that looks like.
    func modeToolbar<Content: ToolbarContent>(
        _ mode: UIMode,
        @ToolbarContentBuilder content: () -> Content
    ) -> some View {
        toolbar { content().modeToolbarBackground(mode) }
    }
}

extension View {
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
