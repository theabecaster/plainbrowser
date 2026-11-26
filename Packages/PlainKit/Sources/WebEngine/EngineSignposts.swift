import os
import PerfSignposts

extension Signposts {
    /// Wraps a question to the shell (dialog, sign-in, permission...) in an `engine.prompt`
    /// interval, so the time a user spends on it shows up next to the page's own intervals.
    static func prompt<Value>(_ kind: String, _ body: () async -> Value) async -> Value {
        let state = signposter.beginInterval(enginePrompt, id: signposter.makeSignpostID(), "\(kind, privacy: .public)")
        let value = await body()
        signposter.endInterval(enginePrompt, state)
        return value
    }
}
