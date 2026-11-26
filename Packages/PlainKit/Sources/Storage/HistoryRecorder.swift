import BrowserCore
import Foundation

/// Buffers history changes from page loads and writes them in batches.
///
/// Callers hand over a change and return at once; nothing waits on SQLite. The buffer is written
/// in one transaction when it reaches `batchSize` or `interval` after the first buffered change,
/// whichever comes first. Call `flush()` when the app moves to the background.
public actor HistoryRecorder {
    private let database: AppDatabase
    private let interval: Duration
    private let batchSize: Int
    private var pending: [HistoryChange] = []
    private var scheduledFlush: Task<Void, Never>?
    private var lastWrite: Task<Void, Never>?
    /// The last write error, kept so a failure is visible in debugging instead of lost.
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
    public func record(_ visit: HistoryVisit) async {
        await enqueue(.visit(visit))
    }

    /// Queues a title change for a page already visited (or queued).
    public func recordTitle(_ title: String, for url: URL) async {
        await enqueue(.title(title, url: url))
    }

    /// Writes everything buffered now.
    public func flush() async {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard !pending.isEmpty else {
            // Nothing new, but a write may still be running: when flush returns, all is on disk.
            await lastWrite?.value
            return
        }
        let batch = pending
        pending = []
        // Chain each write after the previous one, so batches land in the order they were taken
        // even when a flush starts while another is still writing.
        let previous = lastWrite
        let database = database
        let write = Task {
            await previous?.value
            do {
                try await database.apply(batch)
            } catch {
                lastError = error
            }
        }
        lastWrite = write
        await write.value
    }

    private func enqueue(_ change: HistoryChange) async {
        pending.append(change)
        if pending.count >= batchSize {
            await flush()
        } else if scheduledFlush == nil {
            let interval = interval
            scheduledFlush = Task { [weak self] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.flushFromTimer()
            }
        }
    }

    private func flushFromTimer() async {
        scheduledFlush = nil
        await flush()
    }
}
