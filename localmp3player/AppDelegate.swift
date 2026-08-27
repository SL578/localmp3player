import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Touch the store early so CarPlay can connect before the phone UI exists.
        _ = PersistenceController.shared
        // Drop half-staged files from an import that never reached the library.
        // Safe here: nothing can be staged before the first launch completes.
        AudioFileStore.clearStaging()
        return true
    }

    /// Installs `SceneDelegate` on the app's own window scene. It is the only
    /// place `scene(_:openURLContexts:)` — the whole of a multi-file share —
    /// can be heard from. CarPlay keeps the configuration the Info.plist scene
    /// manifest names for it.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: connectingSceneSession.configuration.name,
            sessionRole: connectingSceneSession.role
        )
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = SceneDelegate.self
        }
        return configuration
    }
}
