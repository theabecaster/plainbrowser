import BrowserCore
import Foundation

/// The one writer of history. Buffers changes from page loads and writes them in batches, and
/// runs deletes in order with those batches.
///
/// `record` and `recordTitle` return without waiting on SQLite. The buffer is written in one
/// transaction when it reaches `batchSize` or `interval` after the first buffered change,
/// whichever comes first. Call `flush()` when the app moves to the background.
///
/// Deletes drop matching changes still in the buffer and run after every write already started,
/// so a cleared history never comes back from a late batch.
public actor HistoryRecorder {
    private let database: AppDatabase
    private let interval: Duration
    private let batchSize: Int
    private var pending: [HistoryChange] = []
    private var scheduledFlush: Task<Void, Never>?
    /// The newest write; each write waits for the one before it, so they land in order.
    private var lastWrite: Task<Void, Never>?
    /// The last batch write error, kept so a failure is visible in debugging instead of lost.
    public private(set) var lastError: (any Error)?

    public init(
        database: AppDatabase,
        interval: Duration = FixedChoices.historyFlushInterval,
        batchSize: Int = FixedChoices.historyFlushBatchSize
    ) {
        self.database = database
        self.interval = interval
        self.batchSize = max(1, batchSize)
    }

    /// Queues a visit.
    public func record(_ visit: HistoryVisit) {
        enqueue(.visit(visit))
    }

    /// Queues a title change for a page already visited (or queued).
    public func recordTitle(_ title: String, for url: URL) {
        enqueue(.title(title, url: url))
    }

    /// Writes everything buffered and returns when all writes so far are on disk.
    public func flush() async {
        startBatchWrite()
        await lastWrite?.value
    }

    /// Removes every visit to `url`, including ones not written yet.
    public func deleteHistory(for url: URL) async throws {
        pending.removeAll { $0.url == url }
        try await afterPendingWrites { try await $0.deleteHistory(for: url) }
    }

    /// Removes all history, including changes not written yet.
    public func clearHistory() async throws {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        pending.removeAll()
        try await afterPendingWrites { try await $0.clearHistory() }
    }

    private func enqueue(_ change: HistoryChange) {
        pending.append(change)
        if pending.count >= batchSize {
            startBatchWrite()
        } else if scheduledFlush == nil {
            let interval = interval
            scheduledFlush = Task { [weak self] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.startBatchWrite()
            }
        }
    }

    /// Takes the buffer and chains its write after the previous one, without waiting for it.
    private func startBatchWrite() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        let previous = lastWrite
        let database = database
        lastWrite = Task {
            await previous?.value
            do {
                try await database.apply(batch)
            } catch {
                self.lastError = error
            }
        }
    }

    private func afterPendingWrites(_ operation: @escaping @Sendable (AppDatabase) async throws -> Void) async throws {
        let previous = lastWrite
        let database = database
        let task = Task<Void, any Error> {
            await previous?.value
            try await operation(database)
        }
        lastWrite = Task { _ = try? await task.value }
        try await task.value
    }
}
