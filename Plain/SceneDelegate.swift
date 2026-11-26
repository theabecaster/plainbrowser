import PerfSignposts
import ShellUI
import UIKit
import WebEngine

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let pool = WebViewPool()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = BrowserViewController(pool: pool) {
            Signposts.signposter.endInterval(Signposts.launch, launchInterval)
        }
        window.makeKeyAndVisible()
        self.window = window
    }
}
