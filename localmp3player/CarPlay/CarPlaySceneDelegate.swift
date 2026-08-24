import CarPlay
import UIKit

/// CarPlay entry point.
///
/// Note: `MPPlayableContentDataSource` (the original spec's API) has been
/// deprecated since iOS 14 and is no longer called by CarPlay, so the browse
/// hierarchy is built with the CarPlay framework's template API instead. The
/// data it renders comes from `LibraryQuery`/`SmartPlaylistEngine` — the same
/// queries the phone UI uses.
///
/// TODO: request the `com.apple.developer.carplay-audio` entitlement from Apple
/// and add it to localmp3player.entitlements. Until then this scene only
/// connects in the CarPlay simulator.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var browser: CarPlayBrowser?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let browser = CarPlayBrowser(interfaceController: interfaceController)
        self.browser = browser
        interfaceController.setRootTemplate(browser.makeRootTemplate(), animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        browser = nil
    }
}
