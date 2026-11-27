import ShellUI
import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Windows a test run opened never come back in the owner's app (`SceneState`).
        SceneState.destroyTestSessions()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }

    /// Windows the user closed for good (swiped away in the app switcher): their tabs become a
    /// recently closed batch each, as a closed Safari window's do.
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        let windows = sceneSessions.compactMap {
            SceneState.string(forKey: Windows.windowIDKey, in: $0).flatMap(UUID.init(uuidString:))
        }
        guard !windows.isEmpty else { return }
        AppServices.shared.stores.tabs.discard(windows)
    }
}
