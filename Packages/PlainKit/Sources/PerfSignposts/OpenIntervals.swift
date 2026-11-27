import Foundation
import os

/// Intervals that begin in one call and end when the system says the interaction is done (a tap,
/// then the keyboard at rest), so a call site adds one line. One interval per name at a time, and
/// exclusive (no signpost ID) like the other measured intervals, so `XCTOSSignpostMetric` finds it.
@MainActor
public enum OpenIntervals {
    private struct Open {
        let state: OSSignpostIntervalState
        let observer: any NSObjectProtocol
        let token: Int
    }

    private static var open: [String: Open] = [:]
    private static var nextToken = 0

    /// Begins `name` and ends it the next time `notification` posts. A `name` still open ends
    /// first ("superseded"); one whose notification never comes ends after `timeout`
    /// ("timedOut"), so a stale interval never stretches over a later interaction.
    public static func begin(
        _ name: StaticString, until notification: Notification.Name, timeout: Duration = .seconds(2)
    ) {
        let key = name.description
        end(key, name, message: "superseded")
        nextToken += 1
        let token = nextToken
        let state = Signposts.signposter.beginInterval(name)
        let observer = NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { finish(key, name, token: token) }
        }
        open[key] = Open(state: state, observer: observer, token: token)
        Task {
            try? await Task.sleep(for: timeout)
            guard open[key]?.token == token else { return }
            end(key, name, message: "timedOut")
        }
    }

    private static func finish(_ key: String, _ name: StaticString, token: Int) {
        guard let entry = open[key], entry.token == token else { return }
        open[key] = nil
        NotificationCenter.default.removeObserver(entry.observer)
        Signposts.signposter.endInterval(name, entry.state)
    }

    private static func end(_ key: String, _ name: StaticString, message: StaticString) {
        guard let entry = open.removeValue(forKey: key) else { return }
        NotificationCenter.default.removeObserver(entry.observer)
        Signposts.signposter.endInterval(name, entry.state, "\(message)")
    }
}
