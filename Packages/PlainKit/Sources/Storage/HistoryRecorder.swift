import BrowserCore
import Foundation
import GRDB

/// The one writer of history. Buffers changes from page loads and writes them in batches, and
/// runs deletes in order with those batches.
///
/// `record` and `recordTitle` return without waiting on SQLite. The buffer is written in one
/// transaction when it reaches `batchSize` or `interval` after the first buffered change,
/// whichever comes first. Call `flush()` when the app moves to the background.
///
/// Deletes drop matching changes still in the buffer and run after every write already started,
/// so a cleared history never comes back from a late batch.
///
/// Each `AppDatabase` has exactly one, `AppDatabase.historyRecorder`; two recorders on one
/// database could reorder a delete and a buffered visit.
public actor HistoryRecorder {
    private let writer: any DatabaseWriter
    private let interval: Duration
    private let batchSize: Int
    private var pending: [HistoryChange] = []
    private var scheduledFlush: Task<Void, Never>?
    /// The newest write; each write waits for the one before it, so they land in order.
    private var lastWrite: Task<Void, Never>?
    /// The last batch write error, kept so a failure is visible in debugging instead of lost.
    public private(set) var lastError: (any Error)?

    /// A recorder of its own on `database`, for tests that tune the batching. The app uses
    /// `database.historyRecorder`.
    init(
        database: AppDatabase,
        interval: Duration = FixedChoices.historyFlushInterval,
        batchSize: Int = FixedChoices.historyFlushBatchSize
    ) {
        self.init(writer: database.writer, interval: interval, batchSize: batchSize)
    }

    init(
        writer: any DatabaseWriter,
        interval: Duration = FixedChoices.historyFlushInterval,
        batchSize: Int = FixedChoices.historyFlushBatchSize
    ) {
        self.writer = writer
        self.interval = interval
        self.batchSize = max(1, batchSize)
    }

    /// Queues a visit.
    public func record(_ visit: HistoryVisit) {
        enqueue(.visit(visit))
    }

    /// Queues a title change for a page already visited (or queued). Pass the visit's
    /// `visitedAt` to name that visit only (see `HistoryChange.title`).
    public func recordTitle(_ title: String, for url: URL, visitedAt: Date? = nil) {
        enqueue(.title(title, url: url, visitedAt: visitedAt))
    }

    /// Queues an address-bar pick: the user typed `input` and picked the suggestion for `url`
    /// (adaptive history, see `InputHistory`).
    public func recordPick(input: String, url: URL, at date: Date = Date()) {
        enqueue(.pick(input: input, url: url, at: date))
    }

    /// Writes everything buffered and returns when all writes so far are on disk.
    public func flush() async {
        startBatchWrite()
        await lastWrite?.value
    }

    /// Removes every visit to `url`, including ones not written yet.
    public func deleteHistory(for url: URL) async throws {
        pending.removeAll { $0.url == url }
        try await afterPendingWrites { try await AppDatabase.deleteHistory(for: url, in: $0) }
    }

    /// Removes visits made at or after `start`, or all history when `start` is nil, including
    /// visits not written yet.
    public func clearHistory(since start: Date? = nil) async throws {
        if let start {
            pending.removeAll {
                switch $0 {
                case .visit(let visit): visit.visitedAt >= start
                case .pick(_, _, let date): date >= start
                case .title: false
                }
            }
        } else {
            pending.removeAll()
        }
        if pending.isEmpty {
            scheduledFlush?.cancel()
            scheduledFlush = nil
        }
        try await afterPendingWrites { try await AppDatabase.clearHistory(since: start, in: $0) }
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
        let writer = writer
        lastWrite = Task {
            await previous?.value
            do {
                try await AppDatabase.apply(batch, to: writer)
            } catch {
                self.lastError = error
            }
        }
    }

    /// Runs `operation` after every write already started, in the same chain (deletes, maintenance).
    func afterPendingWrites(_ operation: @escaping @Sendable (any DatabaseWriter) async throws -> Void) async throws {
        let previous = lastWrite
        let writer = writer
        let task = Task<Void, any Error> {
            await previous?.value
            try await operation(writer)
        }
        lastWrite = Task { _ = try? await task.value }
        try await task.value
    }
}
