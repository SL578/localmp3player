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
}
