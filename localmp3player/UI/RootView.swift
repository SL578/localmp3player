import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case library
    case playlists
    case tags
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Library"
        case .playlists: return "Playlists"
        case .tags: return "Tags"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library: return "music.note.list"
        case .playlists: return "music.note.house"
        case .tags: return "tag"
        case .settings: return "gearshape"
        }
    }
}

/// Hosts the four tabs and the app's own bottom bar.
///
/// The bottom bar is hand-rolled rather than a `TabView`: the system tab bar in
/// iOS 26 always draws a glass material (which Performance mode has to be able to
/// turn off), and swapping a `tabViewBottomAccessory` in and out as playback
/// starts restructured the view tree, which reset the selected tab back to
/// Library mid-navigation.
struct RootView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @EnvironmentObject private var playback: PlaybackController

    @StateObject private var importCoordinator = ImportCoordinator(context: PersistenceController.shared.viewContext)
    @State private var tab: AppTab = .library
    @State private var showingNowPlaying = false
    /// Tabs are built on first visit and then kept, so launch only pays for the
    /// Library and each tab still keeps its navigation stack once opened.
    @State private var visited: Set<AppTab> = [.library]
    /// Settings is the one tab whose push state resets on leaving, so drilling
    /// into Colors and switching tabs away and back always lands back on
    /// Settings' own root rather than wherever you left off. Held here, not in
    /// SettingsView itself, because panes are kept alive behind an opacity
    /// change rather than removed — SettingsView never disappears, so it has no
    /// lifecycle event of its own to reset on.
    @State private var settingsPath = NavigationPath()
    /// One counter per tab, bumped when that tab is tapped while already showing.
    /// A pane is kept alive behind an opacity change, so it never disappears and
    /// has no lifecycle event to reset on — the panes watch this instead.
    @State private var popSignal: [AppTab: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                pane(.library) { LibraryView(popToRoot: popSignal[.library, default: 0]) }
                pane(.playlists) { PlaylistsView(popToRoot: popSignal[.playlists, default: 0]) }
                pane(.tags) { TagsView(popToRoot: popSignal[.tags, default: 0]) }
                pane(.settings) { SettingsView(path: $settingsPath) }
            }
            BottomBar(
                tab: $tab,
                onReselect: reselect,
                onOpenPlayer: { showingNowPlaying = true }
            )
        }
        .background(theme.background)
        .onChange(of: tab) { oldValue, newValue in
            visited.insert(newValue)
            if oldValue == .settings, newValue != .settings {
                settingsPath = NavigationPath()
            }
        }
        .environmentObject(importCoordinator)
        // Cover art for anything imported before art was stored at full size.
        // Not a setting and not a prompt — it has one right answer, so it just
        // happens, once, and skips a library that is already current.
        .task { await ArtworkUpgrade.runIfNeeded(in: context) }
        // Files shared or opened into the app from elsewhere. Read from
        // `ExternalURLInbox` rather than `onOpenURL`, which hands over one URL
        // for a whole multi-file share — see `SceneDelegate`.
        .onReceive(NotificationCenter.default.publisher(for: ExternalURLInbox.didReceive)) { _ in
            collectSharedFiles()
        }
        // Launch, and coming back to the app afterwards. Both are asked rather
        // than only the notification, because the share extension leaves its
        // files in the shared inbox whether or not opening the app took — and a
        // share that launched the app is delivered before this view exists to be
        // notified at all.
        .task { collectSharedFiles() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { collectSharedFiles() }
        }
        // The review sheet hangs off `LibraryView`, and every pane is alive
        // behind an opacity change — presenting from one that isn't visible puts
        // the sheet over the wrong screen. Keyed off the phase rather than off
        // the arrival of URLs, so it holds for files that reached the app
        // through the shared inbox without a URL of their own.
        .onChange(of: importCoordinator.phase) { _, phase in
            if phase == .reviewing { tab = .library }
        }
        .sheet(isPresented: $showingNowPlaying) {
            NavigationStack {
                NowPlayingView()
            }
            .environmentObject(playback)
            .environment(\.uiMode, uiMode)
            .themedSheet(theme)
            .tint(theme.accent)
            .foregroundStyle(theme.primaryText, theme.secondaryText)
            .modeTransactions(uiMode)
        }
    }

    /// Hands over anything that arrived as a URL and asks the coordinator to
    /// look in the inboxes as well. Called with nothing to hand over on an
    /// ordinary launch, which costs two directory reads and finds nothing.
    private func collectSharedFiles() {
        importCoordinator.accept(externalURLs: ExternalURLInbox.take())
    }

    /// Tapping the tab you are already on takes that tab back to its own root —
    /// the standard behaviour, and the only way out of a pane that otherwise
    /// remembers exactly where you left it.
    private func reselect(_ candidate: AppTab) {
        if candidate == .settings {
            settingsPath = NavigationPath()
        } else {
            popSignal[candidate, default: 0] += 1
        }
    }

    /// A visited pane stays alive so each tab keeps its own navigation stack and
    /// scroll position when you come back to it.
    @ViewBuilder
    private func pane<Content: View>(_ owner: AppTab, @ViewBuilder content: () -> Content) -> some View {
        if visited.contains(owner) {
            let isActive = tab == owner
            content()
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
        }
    }
}

private struct BottomBar: View {
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @EnvironmentObject private var playback: PlaybackController
    @Binding var tab: AppTab
    let onReselect: (AppTab) -> Void
    let onOpenPlayer: () -> Void

    var body: some View {
        Group {
            if uiMode.usesMaterials {
                // Standard: a floating glass slab, matching the platform look.
                stack
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .modeShadow(uiMode, radius: 10)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
            } else {
                // Performance: edge-to-edge opaque fill, so nothing is composited
                // through a blur and there is no shadow to rasterize.
                stack
                    .background(theme.surface)
                    .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
            }
        }
        .modeAnimation(uiMode, value: playback.currentSong?.id)
    }

    private var stack: some View {
        VStack(spacing: 0) {
            if playback.currentSong != nil {
                MiniPlayerBar(onTap: onOpenPlayer)
                Rectangle().fill(theme.separator).frame(height: 0.5)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(AppTab.allCases) { candidate in
                    button(for: candidate)
                }
            }
            .padding(.top, 8)
            // Standard floats the bar as a slab, so the row is centred inside it
            // and inset from the ends, keeping the selected bubble off the edge.
            // Performance runs to the bottom edge, where the safe area already
            // leaves the space below and only the top needs padding.
            .padding(.bottom, uiMode.usesMaterials ? 8 : 0)
            .padding(.horizontal, uiMode.usesMaterials ? 6 : 0)
        }
    }

    /// Performance keeps every tab captioned: its bar runs to the bottom of the
    /// screen, so there's room for the text and nothing to relieve.
    @ViewBuilder
    private func button(for candidate: AppTab) -> some View {
        if uiMode.usesMaterials {
            pillButton(for: candidate)
        } else {
            captionedButton(for: candidate)
        }
    }

    private func captionedButton(for candidate: AppTab) -> some View {
        Button {
            select(candidate)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: candidate.systemImage)
                    .font(.system(size: 20))
                Text(candidate.title)
                    .font(.caption2)
            }
            .foregroundStyle(tab == candidate ? theme.accent : theme.secondaryText)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(tab == candidate ? [.isSelected, .isButton] : .isButton)
    }

    /// Standard's bar is a floating slab, where four icons with four captions
    /// under them came out cramped. Only the selected tab spells itself out, in a
    /// bubble; the rest are identifiable by glyph and still carry their name for
    /// VoiceOver.
    private func pillButton(for candidate: AppTab) -> some View {
        let isSelected = tab == candidate
        return Button {
            select(candidate)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: candidate.systemImage)
                    .font(.system(size: 19))
                if isSelected {
                    Text(candidate.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
            .padding(.horizontal, isSelected ? 12 : 8)
            .padding(.vertical, 7)
            .background(selectionBubble(isSelected))
            // The selected tab takes the width its label needs; the other three
            // share what's left. Splitting the bar four ways equally instead cut
            // the label off as "Play…".
            .frame(maxWidth: isSelected ? nil : .infinity)
            .fixedSize(horizontal: isSelected, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func select(_ candidate: AppTab) {
        guard tab != candidate else {
            onReselect(candidate)
            return
        }
        withAnimation(uiMode.animation) { tab = candidate }
    }

    /// Only ever drawn in Standard, so it's free to be glass.
    @ViewBuilder
    private func selectionBubble(_ isSelected: Bool) -> some View {
        if isSelected {
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 0.5))
        }
    }
}

#Preview {
    RootView()
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
        .environmentObject(AppSettings())
        .environmentObject(ThemeStore())
        .environmentObject(PlaybackController.shared)
}
