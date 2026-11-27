import Foundation
import Synchronization

/// Runs `operation` and returns its result, or throws `CancellationError` as soon as the caller
/// is cancelled, without waiting for `operation` to notice. WebKit's script calls can't be
/// interrupted; this lets a cancelled read return at once while the call ends on its own, its
/// answer dropped.
@MainActor func abandoningOnCancel<Value: Sendable>(
    _ operation: @escaping @MainActor () async throws -> Value
) async throws -> Value {
    let gate = CancelGate<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let task = Task { @MainActor in
                do { gate.resume(.success(try await operation())) } catch { gate.resume(.failure(error)) }
            }
            gate.attach(continuation, task: task)
        }
    } onCancel: {
        gate.resume(.failure(CancellationError()))
    }
}

/// Resumes one continuation exactly once, from whichever side gets there first: the operation's
/// result or the cancellation (which may arrive on any thread, even before the continuation).
private nonisolated final class CancelGate<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var task: Task<Void, Never>?
        var early: Result<Value, any Error>?
        var done = false
    }

    private let state = Mutex(State())

    func attach(_ continuation: CheckedContinuation<Value, any Error>, task: Task<Void, Never>) {
        let early: Result<Value, any Error>? = state.withLock { state in
            if let early = state.early {
                state.done = true
                return early
            }
            state.continuation = continuation
            state.task = task
            return nil
        }
        if let early {
            if case .failure(let error) = early, error is CancellationError { task.cancel() }
            continuation.resume(with: early)
        }
    }

    func resume(_ result: Result<Value, any Error>) {
        let pending: (CheckedContinuation<Value, any Error>, Task<Void, Never>?)? = state.withLock { state in
            guard !state.done else { return nil }
            guard let continuation = state.continuation else {
                if state.early == nil { state.early = result }
                return nil
            }
            state.done = true
            state.continuation = nil
            return (continuation, state.task)
        }
        guard let (continuation, task) = pending else { return }
        if case .failure(let error) = result, error is CancellationError { task?.cancel() }
        continuation.resume(with: result)
    }
}

/// `operation`'s result, or nil when it takes longer than `limit`, returning at the limit even if
/// `operation` doesn't notice its cancellation (a WebKit script call): its late answer is dropped.
@MainActor func abandoning<Value: Sendable>(
    after limit: Duration, _ operation: @escaping @MainActor () async throws -> Value
) async throws -> Value? {
    let task = Task { @MainActor in try await abandoningOnCancel(operation) }
    let timer = Task {
        try await Task.sleep(for: limit)
        task.cancel()
    }
    defer { timer.cancel() }
    do {
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    } catch is CancellationError {
        try Task.checkCancellation()
        return nil
    }
}
