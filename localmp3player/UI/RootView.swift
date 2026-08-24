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
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme
    @EnvironmentObject private var playback: PlaybackController

    @StateObject private var importCoordinator = ImportCoordinator(context: PersistenceController.shared.viewContext)
    @State private var tab: AppTab = .library
    @State private var showingNowPlaying = false
    /// Tabs are built on first visit and then kept, so launch only pays for the
    /// Library and each tab still keeps its navigation stack once opened.
    @State private var visited: Set<AppTab> = [.library]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                pane(.library) { LibraryView() }
                pane(.playlists) { PlaylistsView() }
                pane(.tags) { TagsView() }
                pane(.settings) { SettingsView() }
            }
            BottomBar(tab: $tab, onOpenPlayer: { showingNowPlaying = true })
        }
        .background(theme.background)
        .onChange(of: tab) { _, newValue in visited.insert(newValue) }
        .environmentObject(importCoordinator)
        .sheet(isPresented: $showingNowPlaying) {
            NavigationStack {
                NowPlayingView(showsDoneButton: true)
            }
            .environmentObject(playback)
            .environment(\.uiMode, uiMode)
            .environment(\.theme, theme)
            .tint(theme.accent)
            .foregroundStyle(theme.primaryText, theme.secondaryText)
            .modeTransactions(uiMode)
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
        }
    }

    private func button(for candidate: AppTab) -> some View {
        Button {
            tab = candidate
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
}

#Preview {
    RootView()
        .environment(\.managedObjectContext, PersistenceController.preview.viewContext)
        .environmentObject(AppSettings())
        .environmentObject(ThemeStore())
        .environmentObject(PlaybackController.shared)
}
