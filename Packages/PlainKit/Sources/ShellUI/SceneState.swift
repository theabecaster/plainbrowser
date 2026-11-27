#if canImport(UIKit)
import BrowserCore
import UIKit

/// Per-window state that comes back with its scene (the window id, the sidebar's state). It lives
/// in the scene's `UISceneSession.userInfo`, which the system keeps for the owner's next launch.
/// An isolated test run (`TestIsolation`) keeps it in the test defaults instead, per scene, so a
/// test never changes what the owner's windows restore.
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
}
#endif
