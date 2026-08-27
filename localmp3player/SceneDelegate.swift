import UIKit

/// Every URL handed to the app from outside it, from the one place iOS reports
/// the whole batch.
///
/// SwiftUI's `onOpenURL` takes a single URL, and for a multi-file share it is
/// called **once** — sharing four songs from Files imported one, which is
/// exactly what it was told about. iOS delivers the batch as a *set* of
/// `UIOpenURLContext`, one per file, and only `UISceneDelegate` sees that set,
/// so the app listens there instead and republishes the lot.
///
/// Both entry points matter: `willConnectTo` is the share that launches the app,
/// `openURLContexts` the share that arrives while it is already running.
@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        deliver(options.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        deliver(URLContexts)
    }

    /// Synchronous on purpose. A share that launches the app is delivered in
    /// `willConnectTo`, which runs before SwiftUI has built anything; parking the
    /// URLs there and then means `RootView`'s `task` finds them on its first
    /// pass. Hopping to a later turn of the run loop instead put the hand-off in
    /// a race with that pass.
    private func deliver(_ contexts: Set<UIOpenURLContext>) {
        let urls = contexts.map(\.url)
        guard !urls.isEmpty else { return }
        ExternalURLInbox.deliver(urls)
    }
}

/// Holds incoming URLs until a view is around to act on them.
///
/// A share that launches the app arrives in `willConnectTo`, which happens
/// before any SwiftUI view exists to receive a notification — so the URLs are
/// parked here and whoever wakes up first takes them.
@MainActor
enum ExternalURLInbox {
    static let didReceive = Notification.Name("ExternalURLInbox.didReceive")

    private static var pending: [URL] = []

    static func deliver(_ urls: [URL]) {
        pending += urls
        NotificationCenter.default.post(name: didReceive, object: nil)
    }

    static func take() -> [URL] {
        defer { pending = [] }
        return pending
    }
}
