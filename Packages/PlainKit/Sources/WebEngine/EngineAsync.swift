#if canImport(UIKit)
import Foundation
import UIKit

/// Starts a WebKit call now and delivers its reply, or `fallback` after
/// `EngineChoices.webKitReplyTimeout`, to `completion` exactly once. A frozen, suspended or killed
/// WebContent process can answer late or never (`takeSnapshot`, `fetchData`, `restoreData`);
/// nothing in the engine waits on one forever. `start` runs synchronously, so a snapshot is taken
/// before the caller removes the view from the window.
func callWithWebKitTimeout<Value>(
    fallback: Value, _ start: (@escaping (Value) -> Void) -> Void, completion: @escaping (Value) -> Void
) {
    var delivered = false
    let deliver: (Value) -> Void = { value in
        guard !delivered else { return }
        delivered = true
        completion(value)
    }
    start(deliver)
    Task {
        try? await Task.sleep(for: EngineChoices.webKitReplyTimeout)
        deliver(fallback)
    }
}

/// `callWithWebKitTimeout` for async callers.
func withWebKitTimeout<Value: Sendable>(
    fallback: Value, _ start: (@escaping (Value) -> Void) -> Void
) async -> Value {
    await withCheckedContinuation { continuation in
        callWithWebKitTimeout(fallback: fallback, start) { continuation.resume(returning: $0) }
    }
}

/// `beginBackgroundTask` around work that must finish after the app leaves the screen (saving
/// tabs, running downloads). Only inside the app: test bundles have no `UIApplication`.
enum BackgroundWork {
    static let isInApp = Bundle.main.bundleURL.pathExtension == "app"

    static func begin(_ name: String) -> UIBackgroundTaskIdentifier? {
        guard isInApp else { return nil }
        return UIApplication.shared.beginBackgroundTask(withName: name)
    }

    static func end(_ identifier: UIBackgroundTaskIdentifier?) {
        guard let identifier, identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
#endif
