import BrowserCore
import Foundation
import GRDB
import PerfSignposts

/// What one maintenance pass removed, for logs and tests.
public struct MaintenanceReport: Hashable, Sendable {
    /// Visits older than `FixedChoices.historyMaxAge`.
    public var expiredVisits = 0
    /// Pages whose last visit expired, plus the least frecent beyond `FixedChoices.historyMaxPlaces`.
    public var removedPlaces = 0
    /// Site icons older than `FixedChoices.faviconMaxAge`.
    public var removedFavicons = 0
}

/// Keeps the database small and fast, off the main thread:
///
/// - **After Clear History (all time) or clearing icons:** `VACUUM`, then
///   `wal_checkpoint(TRUNCATE)`, so deleted rows are gone from the file and the WAL, not just
///   unlinked. Coalesced: Clear History and Data clears history, then icons, and compacts once.
/// - **Daily** (`runDailyMaintenanceIfDue`), at most once per `FixedChoices.maintenanceInterval`:
///   expire old visits, cap history, decay adaptive history, drop stale icons, FTS `optimize`,
///   `PRAGMA optimize`. History pruning runs in `HistoryRecorder`'s write chain, so it is ordered
///   with buffered visits and deletes.
actor DatabaseMaintenance {
    private let writer: any DatabaseWriter
    private let compactionDelay: Duration
    /// The newest maintenance task; each waits for the one before it.
    private var last: Task<Void, Never>?
    /// A compaction is scheduled and has not started yet, so another request can join it.
    private var compactionQueued = false

    init(writer: any DatabaseWriter, compactionDelay: Duration) {
        self.writer = writer
        self.compactionDelay = compactionDelay
    }

    /// Compacts soon, once for any number of requests made before it starts.
    func scheduleCompaction() {
        guard !compactionQueued else { return }
        compactionQueued = true
        let previous = last
        let writer = writer
        let delay = compactionDelay
        last = Task(priority: .utility) {
            await previous?.value
            try? await Task.sleep(for: delay)
            self.compactionStarted()
            try? await AppDatabase.compact(writer)
        }
    }

    private func compactionStarted() {
        compactionQueued = false
    }

    /// Runs `operation` after any maintenance already scheduled.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = last
        let task = Task<T, any Error>(priority: .utility) {
            await previous?.value
            return try await operation()
        }
        last = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Waits until every scheduled maintenance task has finished.
    func idle() async {
        while let current = last {
            await current.value
            if current == last { return }
        }
    }
}

extension AppDatabase {
    static let lastMaintenanceKey = "maintenance.lastRun"

    /// Rewrites the database file without free pages and empties the WAL. Runs on GRDB's writer
    /// queue, never on the main thread. Clear History (all time) and clearing icons schedule it
    /// on their own; call it directly only for tests.
    public func compact() async throws {
        let writer = writer
        try await maintenance.run { try await Self.compact(writer) }
    }

    static func compact(_ writer: any DatabaseWriter) async throws {
        let signpost = Signposts.signposter.beginInterval("storage.compact")
        defer { Signposts.signposter.endInterval("storage.compact", signpost) }
        try await writer.writeWithoutTransaction { db in
            // VACUUM writes the new file through the WAL; the checkpoint moves it into the
            // database and truncates the WAL to zero bytes. A reader still open can keep the
            // checkpoint from truncating; the next one will.
            try db.execute(sql: "VACUUM")
            _ = try? db.checkpoint(.truncate)
        }
    }

    /// Waits for scheduled compaction and maintenance to finish. For tests.
    public func waitForMaintenance() async {
        await maintenance.idle()
    }

    /// Runs daily maintenance in the background once launch has settled
    /// (`FixedChoices.maintenanceLaunchDelay`), if it has not run in the last
    /// `FixedChoices.maintenanceInterval`. Call once after opening the database. Returns at once.
    public func scheduleDailyMaintenance() {
        Task(priority: .background) {
            try? await Task.sleep(for: FixedChoices.maintenanceLaunchDelay)
            _ = try? await self.runDailyMaintenanceIfDue()
        }
    }

    /// Runs `runMaintenance` if the last run was `FixedChoices.maintenanceInterval` or more ago (or
    /// never, or in the future because the clock moved). Returns nil when it was not due.
    ///
    /// The check runs inside the serialized maintenance task, so two callers never both run it.
    @discardableResult
    public func runDailyMaintenanceIfDue(now: Date = Date()) async throws -> MaintenanceReport? {
        try await maintenance.run {
            let lastRun = try await self.lastMaintenance()
            if let lastRun, lastRun <= now, now.timeIntervalSince(lastRun) < FixedChoices.maintenanceInterval {
                return nil
            }
            return try await self.performMaintenance(
                now: now, lastRun: lastRun, maxPlaces: FixedChoices.historyMaxPlaces, maxAge: FixedChoices.historyMaxAge)
        }
    }

    func lastMaintenance() async throws -> Date? {
        try await writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM \(Schema.setting) WHERE key = ?", arguments: [Self.lastMaintenanceKey]
            )
            .flatMap(Double.init)
            .map(Date.init(timeIntervalSince1970:))
        }
    }

    /// One maintenance pass. `maxPlaces` and `maxAge` are for tests.
    func runMaintenance(
        now: Date,
        lastRun: Date?,
        maxPlaces: Int = FixedChoices.historyMaxPlaces,
        maxAge: TimeInterval = FixedChoices.historyMaxAge
    ) async throws -> MaintenanceReport {
        try await maintenance.run {
            try await self.performMaintenance(now: now, lastRun: lastRun, maxPlaces: maxPlaces, maxAge: maxAge)
        }
    }

    /// The pass itself. Run it only inside `maintenance.run`.
    private func performMaintenance(
        now: Date, lastRun: Date?, maxPlaces: Int, maxAge: TimeInterval
    ) async throws -> MaintenanceReport {
        let signpost = Signposts.signposter.beginInterval("storage.maintenance")
        defer { Signposts.signposter.endInterval("storage.maintenance", signpost) }
        let report = ReportBox()
        // History pruning goes through the one history writer, after the visits it has buffered.
        try await historyRecorder.afterBufferedWrites { writer in
            let pruned = try await writer.write { db in
                try Self.prune(now: now, lastRun: lastRun, maxPlaces: maxPlaces, maxAge: maxAge, in: db)
            }
            report.set(pruned)
        }
        try await writer.write { db in
            // Merges the full-text index's segments, so searches read fewer b-trees.
            try db.execute(sql: "INSERT INTO \(Schema.historySearch)(\(Schema.historySearch)) VALUES('optimize')")
            try db.execute(
                sql: """
                INSERT INTO \(Schema.setting) (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [Self.lastMaintenanceKey, String(now.timeIntervalSince1970)]
            )
        }
        // Refreshes the query planner's statistics where they went stale; cheap when nothing did.
        try await writer.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA optimize") }
        return report.value
    }

    /// Expires old visits and pages, caps history, ages adaptive history and drops stale icons, in
    /// one transaction.
    static func prune(
        now: Date, lastRun: Date?, maxPlaces: Int, maxAge: TimeInterval, in db: Database
    ) throws -> MaintenanceReport {
        var report = MaintenanceReport()
        let cutoff = now.addingTimeInterval(-maxAge)

        try db.execute(sql: "DELETE FROM \(Schema.historyVisit) WHERE visitedAt < ?", arguments: [cutoff])
        report.expiredVisits = db.changesCount

        // Pages last seen before the cutoff have no visits left. Their frecency is negligible.
        var gone = try String.fetchAll(
            db, sql: "SELECT url FROM \(Schema.historyPlace) WHERE lastVisitedAt < ?", arguments: [cutoff]
        )
        // Beyond the cap, the least frecent go, with their visits.
        let remaining = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(Schema.historyPlace)") ?? 0
        let excess = remaining - gone.count - max(0, maxPlaces)
        if excess > 0 {
            gone += try String.fetchAll(
                db,
                sql: """
                SELECT url FROM \(Schema.historyPlace) WHERE lastVisitedAt >= ?
                ORDER BY frecency ASC LIMIT ?
                """,
                arguments: [cutoff, excess]
            )
        }
        let deletePlace = try db.makeStatement(sql: "DELETE FROM \(Schema.historyPlace) WHERE url = ?")
        let deleteVisits = try db.makeStatement(sql: "DELETE FROM \(Schema.historyVisit) WHERE url = ?")
        let deletePicks = try db.makeStatement(sql: "DELETE FROM \(Schema.inputHistory) WHERE url = ?")
        for url in gone {
            try deletePlace.execute(arguments: [url])
            try deleteVisits.execute(arguments: [url])
            try deletePicks.execute(arguments: [url])
        }
        report.removedPlaces = gone.count

        // A first run ages picks by one day; later runs by the days since the last one.
        let days = lastRun.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 1
        try InputHistory.decay(days: days, in: db)

        try db.execute(
            sql: "DELETE FROM \(Schema.favicon) WHERE updatedAt < ?",
            arguments: [now.addingTimeInterval(-FixedChoices.faviconMaxAge)]
        )
        report.removedFavicons = db.changesCount
        return report
    }
}

/// Carries the prune report out of the history writer's closure.
private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report = MaintenanceReport()

    var value: MaintenanceReport { lock.withLock { report } }
    func set(_ report: MaintenanceReport) { lock.withLock { self.report = report } }
}
