#if canImport(UIKit)
import BrowserCore
import UIKit

/// Per-window state that comes back with its scene (the window id, the sidebar's state). It lives
/// in the scene's `UISceneSession.userInfo`, which the system keeps for the owner's next launch.
/// An isolated test run (`TestIsolation`) keeps it in the test defaults instead, per scene, so a
/// test never changes what the owner's windows restore.
///
/// It is also the one place that reads the app's scene sessions and destroys one, so a window a
/// test opened never comes back in the owner's app (`isTestSession`).
public enum SceneState {
    public static func string(forKey key: String, in session: UISceneSession) -> String? {
        if TestIsolation.isActive { return TestIsolation.defaults.string(forKey: isolatedKey(key, session)) }
        return session.userInfo?[key] as? String
    }

    public static func set(_ value: String, forKey key: String, in session: UISceneSession) {
        if TestIsolation.isActive {
            TestIsolation.defaults.set(value, forKey: isolatedKey(key, session))
            return
        }
        var info = session.userInfo ?? [:]
        info[key] = value
        session.userInfo = info
    }

    private static func isolatedKey(_ key: String, _ session: UISceneSession) -> String {
        "\(key).\(session.persistentIdentifier)"
    }

    // MARK: Sessions

    /// `key`'s value in every scene session the app has, connected or not (the app switcher's
    /// windows).
    public static func valuesOfOpenSessions(forKey key: String) -> Set<String> {
        Set(UIApplication.shared.openSessions.compactMap { string(forKey: key, in: $0) })
    }

    /// The app's open scene sessions.
    public static var openSessions: Set<UISceneSession> { UIApplication.shared.openSessions }

    /// Marks a scene session a test run made (a window it asked for with New Window or Open in New
    /// Window), so the owner's next normal launch destroys it. Only sessions made for Plain's own
    /// new-window request are marked: the owner's sessions, which the system reconnects for a test
    /// run, never are. The mark is the only thing an isolated run writes to a session.
    static func markTestSession(_ session: UISceneSession) {
        guard TestIsolation.isActive else { return }
        var info = session.userInfo ?? [:]
        info[testSessionKey] = true
        session.userInfo = info
    }

    /// A session a test run opened (`markIfTestSession`). Only a normal launch asks.
    public static func isTestSession(_ session: UISceneSession) -> Bool {
        !TestIsolation.isActive && session.userInfo?[testSessionKey] as? Bool == true
    }

    /// Removes every session a test run opened, connected or not.
    public static func destroyTestSessions() {
        for session in UIApplication.shared.openSessions where isTestSession(session) { destroy(session) }
    }

    /// Removes `session` and its window from the app switcher.
    public static func destroy(_ session: UISceneSession) {
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }

    /// `session` connected; `isNewWindow`: for Plain's new-window request. In an isolated run that
    /// session is the test's, and is marked.
    public static func sessionDidConnect(_ session: UISceneSession, isNewWindow: Bool) {
        if isNewWindow { markTestSession(session) }
    }

    private static let testSessionKey = "plain.testSession"
}
#endif
