import SwiftUI

@main
struct localmp3playerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings()
    @StateObject private var theme = ThemeStore()
    @StateObject private var playback = PlaybackController.shared

    private let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .environment(\.managedObjectContext, persistence.viewContext)
                .environment(\.uiMode, settings.uiMode)
                .environmentObject(settings)
                .environmentObject(theme)
                .environmentObject(playback)
                .preferredColorScheme(theme.preferredColorScheme)
        }
    }
}

/// Resolves the palette once, as high in the tree as possible, so every view
/// below reads a single already-computed `AppTheme`.
private struct ThemedRoot: View {
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.uiMode) private var uiMode
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        let scheme = theme.effectiveScheme(system: systemScheme)
        let palette = theme.palette(for: scheme)

        RootView()
            .environment(\.theme, palette)
            .tint(palette.accent)
            .foregroundStyle(palette.primaryText, palette.secondaryText)
            .background(palette.background)
            .modeTransactions(uiMode)
            .onChange(of: scenePhase) { _, phase in
                // Catch a day/night boundary crossed while the app was backgrounded.
                if phase == .active { theme.refreshDynamicScheme() }
            }
    }
}
