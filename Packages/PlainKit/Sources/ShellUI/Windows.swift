#if canImport(UIKit)
import BrowserCore
import Foundation
import PerfSignposts
import UIKit

/// Plain's windows (UIScene multi-window): "Open in New Window" and switching between windows.
///
/// The iPhone Duo's inner screen takes new windows the iPad way; its outer screen and other iPhones
/// do not (Apple's multi-window talk for the Duo, docs/research/duo-pane-windows.md). Plain offers
/// a new window only where the window is regular in both size classes and the app may have more
/// than one scene; the request still handles the system saying no.
public enum Windows {
    /// The activity a new window is asked for with: the page to open and whether it is private.
    public static let activityType = "dev.abrahamgonzalez.plainbrowser.window"
    /// Where a scene keeps its window's id (`SceneState`).
    public static let windowIDKey = "plain.windowID"
    private static let urlKey = "url"
    private static let privateKey = "private"

    /// A new window may open from `traits` now.
    public static func canOpenNew(in traits: UITraitCollection) -> Bool {
        UIApplication.shared.supportsMultipleScenes
            && traits.horizontalSizeClass == .regular && traits.verticalSizeClass == .regular
    }

    /// The activity that asks for a new window showing `url` (nil: the start page).
    public static func activity(opening url: URL?, isPrivate: Bool) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        var info: [String: Any] = [privateKey: isPrivate]
        if let url { info[urlKey] = url.absoluteString }
        activity.userInfo = info
        return activity
    }

    /// What a new window's activity asks for, or nil for any other activity.
    public static func request(in activity: NSUserActivity) -> (url: URL?, isPrivate: Bool)? {
        guard activity.activityType == activityType else { return nil }
        let url = (activity.userInfo?[urlKey] as? String).flatMap(URL.init(string:))
        return (url, activity.userInfo?[privateKey] as? Bool ?? false)
    }

    /// Asks the system for a new window opening `url`. `failed` runs when it says no.
    static func openNew(url: URL?, isPrivate: Bool, failed: @escaping @MainActor () -> Void) {
        Signposts.signposter.emitEvent(Signposts.windowOpen)
        var request = UISceneSessionActivationRequest(role: .windowApplication)
        request.userActivity = activity(opening: url, isPrivate: isPrivate)
        UIApplication.shared.activateSceneSession(for: request) { _ in
            Task { @MainActor in failed() }
        }
    }

    /// The app's other windows (connected or in the app switcher), with the window each shows, in
    /// a stable order.
    static func others(than window: WindowID) -> [(session: UISceneSession, window: WindowID)] {
        SceneState.openSessions.compactMap { session in
            guard let id = SceneState.string(forKey: windowIDKey, in: session).flatMap(UUID.init(uuidString:)),
                  id != window else { return nil }
            return (session, id)
        }
        .sorted { $0.session.persistentIdentifier < $1.session.persistentIdentifier }
    }

    /// Brings `session`'s window forward.
    static func activate(_ session: UISceneSession, failed: @escaping @MainActor () -> Void) {
        Signposts.signposter.emitEvent(Signposts.windowSwitch)
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session)) { _ in
            Task { @MainActor in failed() }
        }
    }
}
#endif
