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
            // The primary text color is deliberately *not* set here.
            //
            // An explicit foreground style beats `.tint` for any control below
            // it, so setting the palette at the root painted every toolbar
            // button in the text color — Cancel, Save and Select read as plain
            // labels rather than buttons. It now goes on the content instead,
            // through `themedScrollBackground`, which every screen already
            // applies; toolbars are left to the tint, the way iOS expects.
            .symbolRenderingMode(.monochrome)
            .background(palette.background)
            .modeTransactions(uiMode)
            .onAppear { MotionControl.apply(uiMode) }
            .onChange(of: uiMode) { _, mode in MotionControl.apply(mode) }
            .onChange(of: scenePhase) { _, phase in
                // Catch a day/night boundary crossed while the app was backgrounded.
                if phase == .active {
                    theme.refreshDynamicScheme()
                    MotionControl.apply(uiMode)
                }
            }
    }
}
