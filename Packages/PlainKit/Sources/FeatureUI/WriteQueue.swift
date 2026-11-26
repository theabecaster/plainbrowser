/// Runs async writes one after another, in the order they were started, without making the caller
/// wait. A screen's edits (a reorder, then a rename) must reach the store in the order the user
/// made them.
final class WriteQueue {
    private var last: Task<Void, Never>?

    /// Starts `operation` after every earlier one finishes. `onError` runs on the main actor.
    func enqueue(
        _ operation: @escaping @Sendable () async throws -> Void,
        onError: @escaping @MainActor (any Error) -> Void
    ) {
        let previous = last
        last = Task {
            await previous?.value
            do {
                try await operation()
            } catch {
                onError(error)
            }
        }
    }

    /// Runs `operation` after every earlier one finishes and returns its result. Reads go through
    /// here too, so a read never sees the store from before a change the user already made.
    func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = last
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation()
        }
        last = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Returns when every write started so far has finished.
    func drain() async {
        await last?.value
    }
}
