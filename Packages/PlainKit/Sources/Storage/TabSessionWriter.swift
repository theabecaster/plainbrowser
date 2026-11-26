import BrowserCore
import Foundation
import GRDB
import PerfSignposts
import Synchronization

/// The one writer of tabs: `TabStore` hands it every change (`TabPersistence`), and it writes
/// them in order, off the main thread.
///
/// `enqueue` only appends to a buffer under a lock, so it returns at once on the main thread. The
/// buffer is written `delay` after the first change in it, in one transaction; a newer session
/// replaces an older one still waiting. Each write compares the session with the last one written
/// and touches only the rows that changed, so a title change writes one row. Writes run one after
/// another in the order they were started. Call `flush()` when the app moves to the background.
///
/// After a write, state files of tabs no row names any more (closed tabs that fell off the
/// recently closed stack, archived tabs deleted or over the cap) are deleted.
///
/// Each `AppDatabase` has exactly one, `AppDatabase.tabSession`.
public final class TabSessionWriter: TabPersistence {
    private let writer: any DatabaseWriter
    private let tabStates: TabStateStore
    private let delay: Duration
    private let archiveLimit: Int

    private struct State {
        var pending: [TabChange] = []
        var scheduled: Task<Void, Never>?
        /// The newest write; each write waits for the one before it.
        var lastWrite: Task<Void, Never>?
        /// The session as the database holds it, for diffing. Nil means unknown: the next write
        /// compares with the rows instead.
        var written: TabSession?
        var lastError: (any Error)?
    }

    private let state = Mutex(State())

    init(
        writer: any DatabaseWriter, tabStates: TabStateStore,
        delay: Duration = FixedChoices.tabSaveDelay, archiveLimit: Int = FixedChoices.archivedTabLimit
    ) {
        self.writer = writer
        self.tabStates = tabStates
        self.delay = delay
        self.archiveLimit = archiveLimit
    }

    /// The last write error, kept so a failure is visible in debugging instead of lost.
    public var lastError: (any Error)? {
        state.withLock { $0.lastError }
    }

    public func enqueue(_ change: TabChange) {
        state.withLock { state in
            if case .session = change {
                state.pending.removeAll { if case .session = $0 { true } else { false } }
            }
            state.pending.append(change)
            schedule(&state)
        }
    }

    private func schedule(_ state: inout State) {
        guard state.scheduled == nil else { return }
        let delay = delay
        state.scheduled = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.startWrite()
        }
    }

    /// Writes everything enqueued so far and returns when it is on disk.
    public func flush() async {
        startWrite()
        let last = state.withLock { $0.lastWrite }
        await last?.value
    }

    /// Reads the session in the write chain, after every write already started, and keeps it as
    /// the diff baseline, so a write can never land between the read and the baseline.
    func load() async throws -> TabSession {
        let read: Task<Result<TabSession, any Error>, Never> = state.withLock { state in
            let previous = state.lastWrite
            let writer = writer
            let task = Task.detached(priority: .userInitiated) { [self] () -> Result<TabSession, any Error> in
                await previous?.value
                do {
                    let session = try await writer.read { db in try AppDatabase.readTabSession(db) }
                    self.state.withLock { $0.written = session }
                    return .success(session)
                } catch {
                    return .failure(error)
                }
            }
            state.lastWrite = Task { _ = await task.value }
            return task
        }
        return try await read.value.get()
    }

    /// Takes the buffer and chains its write after the previous one, without waiting for it.
    func startWrite() {
        state.withLock { state in
            state.scheduled?.cancel()
            state.scheduled = nil
            guard !state.pending.isEmpty else { return }
            let batch = state.pending
            state.pending = []
            let previous = state.lastWrite
            state.lastWrite = Task.detached(priority: .utility) { [self] in
                await previous?.value
                await write(batch)
            }
        }
    }

    private func write(_ batch: [TabChange]) async {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabSave, id: signposter.makeSignpostID())
        defer { signposter.endInterval(Signposts.tabSave, interval) }
        let written = state.withLock { $0.written }
        let archiveLimit = archiveLimit
        // A failed transaction rolls back, so the rows are as before. Try again in place: later
        // batches wait behind this one in the chain, so nothing newer can land first.
        for attempt in 1 ... FixedChoices.tabWriteAttempts {
            do {
                let result = try await writer.write { db in
                    try Self.apply(batch, written: written, archiveLimit: archiveLimit, in: db)
                }
                state.withLock { $0.written = result.written }
                if !result.unreferenced.isEmpty {
                    await tabStates.delete(Array(result.unreferenced))
                }
                return
            } catch {
                state.withLock { $0.lastError = error }
                if attempt < FixedChoices.tabWriteAttempts {
                    try? await Task.sleep(for: FixedChoices.tabWriteRetryDelay)
                }
            }
        }
    }

    struct WriteResult {
        var written: TabSession?
        /// Tabs no row names any more; their state files can go.
        var unreferenced: Set<TabID>
    }

    static func apply(_ batch: [TabChange], written: TabSession?, archiveLimit: Int, in db: Database) throws -> WriteResult {
        var written = written
        var candidates = Set<TabID>()
        for change in batch {
            switch change {
            case .session(let session):
                candidates.formUnion(try writeSession(session, over: written, in: db))
                written = session
            case .archive(let entries, let date):
                for entry in entries {
                    var record = TabRecord(entry: entry, windowID: nil, position: 0)
                    record.isArchived = true
                    record.archivedAt = date
                    try record.upsert(db)
                }
                let overflow = try String.fetchAll(
                    db,
                    sql: """
                    SELECT id FROM \(Schema.tab) WHERE isArchived
                    ORDER BY archivedAt DESC LIMIT -1 OFFSET ?
                    """,
                    arguments: [archiveLimit]
                )
                try deleteRows(overflow, archived: true, in: db)
                candidates.formUnion(overflow.compactMap(UUID.init(uuidString:)))
                // The written session no longer holds them as open.
                let archived = Set(entries.map(\.id))
                written?.tabs.removeAll { archived.contains($0.id) }
            case .unarchive(let ids):
                // The tab is open again (a later session writes its open row) or already closed
                // again; either way it is no longer in the archive.
                try deleteRows(ids.map(\.uuidString), archived: true, in: db)
                candidates.formUnion(ids)
            case .deleteArchived(let ids):
                let doomed = try ids.map { $0.map(\.uuidString) }
                    ?? String.fetchAll(db, sql: "SELECT id FROM \(Schema.tab) WHERE isArchived")
                try deleteRows(doomed, archived: true, in: db)
                candidates.formUnion(doomed.compactMap(UUID.init(uuidString:)))
            }
        }
        guard !candidates.isEmpty else { return WriteResult(written: written, unreferenced: []) }
        let referenced = try AppDatabase.referencedTabIDs(db)
        return WriteResult(written: written, unreferenced: candidates.subtracting(referenced))
    }

    /// Writes the rows that differ between `session` and `old` (or the rows on disk when `old` is
    /// nil). Returns ids that left the open tabs or the recently closed stack.
    private static func writeSession(_ session: TabSession, over old: TabSession?, in db: Database) throws -> Set<TabID> {
        let new = openRecords(session)
        var gone = Set<TabID>()
        if let old {
            let previous = openRecords(old)
            for (id, record) in new where previous[id] != record {
                try record.upsert(db)
            }
            gone = Set(previous.keys).subtracting(new.keys)
        } else {
            for record in new.values { try record.upsert(db) }
            let stored = try UUID.fetchSet(db, sql: "SELECT id FROM \(Schema.tab) WHERE NOT isArchived")
            gone = stored.subtracting(new.keys)
        }
        try deleteRows(gone.map(\.uuidString), archived: false, in: db)

        if old?.windows != session.windows {
            try TabWindowRecord.deleteAll(db)
            for (position, window) in session.windows.enumerated() {
                try TabWindowRecord(window, position: position).insert(db)
            }
        }

        if old?.recentlyClosed != session.recentlyClosed {
            let oldBatches = old.map { Set($0.recentlyClosed.map(\.id)) }
            let newBatches = Set(session.recentlyClosed.map(\.id))
            if let oldBatches, isAppendOnly(from: old!.recentlyClosed, to: session.recentlyClosed) {
                // The usual case: batches pushed on top, old ones dropped from the bottom or the
                // top. Rows of kept batches stay as they are.
                let dropped = oldBatches.subtracting(newBatches)
                if !dropped.isEmpty {
                    try ClosedTabRecord.filter(dropped.map(\.uuidString).contains(Column("batchID"))).deleteAll(db)
                }
                for batch in session.recentlyClosed where !oldBatches.contains(batch.id) {
                    try insert(batch, in: db)
                }
            } else {
                try ClosedTabRecord.deleteAll(db)
                for batch in session.recentlyClosed { try insert(batch, in: db) }
            }
            let oldClosed = Set((old?.recentlyClosed ?? []).flatMap { $0.tabs.map(\.entry.id) })
            let newClosed = Set(session.recentlyClosed.flatMap { $0.tabs.map(\.entry.id) })
            gone.formUnion(oldClosed.subtracting(newClosed))
        }
        return gone
    }

    /// True when `new` is `old` with batches removed and new ones only added after the kept ones,
    /// so stack order (row order) stays right without rewriting kept rows.
    private static func isAppendOnly(from old: [ClosedTabBatch], to new: [ClosedTabBatch]) -> Bool {
        let oldIDs = Set(old.map(\.id))
        let kept = new.prefix { oldIDs.contains($0.id) }
        guard new.dropFirst(kept.count).allSatisfy({ !oldIDs.contains($0.id) }) else { return false }
        // Kept batches must be unchanged and in the same relative order.
        let oldKept = old.filter { batch in kept.contains { $0.id == batch.id } }
        return oldKept == Array(kept)
    }

    private static func insert(_ batch: ClosedTabBatch, in db: Database) throws {
        for (position, tab) in batch.tabs.enumerated() {
            try ClosedTabRecord(tab, batch: batch, position: position).insert(db)
        }
    }

    private static func openRecords(_ session: TabSession) -> [TabID: TabRecord] {
        let entries = Dictionary(session.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var records: [TabID: TabRecord] = [:]
        records.reserveCapacity(entries.count)
        for window in session.windows {
            for (position, id) in window.tabIDs.enumerated() {
                guard let entry = entries[id], records[id] == nil else { continue }
                records[id] = TabRecord(entry: entry, windowID: window.id, position: position)
            }
        }
        // Tabs no window lists (rows from before windows existed) are rows too.
        for (position, entry) in session.tabs.enumerated() where records[entry.id] == nil {
            records[entry.id] = TabRecord(entry: entry, windowID: nil, position: position)
        }
        return records
    }

    private static func deleteRows(_ ids: [String], archived: Bool, in db: Database) throws {
        guard !ids.isEmpty else { return }
        // Bound the statement size; SQLite limits host parameters.
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ ids[$0 ..< min($0 + 500, ids.count)] }) {
            try db.execute(
                sql: """
                DELETE FROM \(Schema.tab) WHERE isArchived = ? AND id IN (\(databaseQuestionMarks(count: chunk.count)))
                """,
                arguments: StatementArguments([archived] + chunk.map { $0 as any DatabaseValueConvertible })
            )
        }
    }
}
