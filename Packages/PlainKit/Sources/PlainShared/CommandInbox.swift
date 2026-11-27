import Foundation

/// Where App Intents hand their command to the app. An intent can run before the scene has built
/// the browser (Siri or a control launching Plain cold), so commands wait here until the scene
/// sets `handler`, then go to it in order.
///
/// One per process: the intents are created by the system, so they cannot be given a reference.
/// The scene delegate is the only handler.
@MainActor
public final class CommandInbox {
    public static let shared = CommandInbox()

    private var pending: [PlainCommand] = []

    /// Receives every command, the waiting ones first as soon as it is set.
    public var handler: ((PlainCommand) -> Void)? {
        didSet { drain() }
    }

    public init() {}

    public func send(_ command: PlainCommand) {
        pending.append(command)
        drain()
    }

    private func drain() {
        guard let handler else { return }
        while !pending.isEmpty {
            handler(pending.removeFirst())
        }
    }
}
