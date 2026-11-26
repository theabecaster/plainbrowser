import Foundation
import GRDB

/// The app's one SQLite database. Owns the schema (migrations) and is the only place that talks to
/// GRDB. Every call is async and runs on GRDB's own queue, never on the main thread.
public final class AppDatabase: Sendable {
    private let writer: any DatabaseWriter

    /// Opens (or creates) the database at `url` and migrates it to the current schema. Opening and
    /// migrating touch the disk, so they run on the global executor, never on the caller's actor.
    @concurrent
    public static func open(at url: URL) async throws -> AppDatabase {
        try AppDatabase(DatabasePool(path: url.path))
    }

    /// An empty database in memory, for tests and previews.
    @concurrent
    public static func inMemory() async throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1.history") { db in
            try db.create(table: HistoryVisit.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull()
                t.column("title", .text)
                t.column("visitedAt", .datetime).notNull().indexed()
            }
        }
        return migrator
    }

    public func record(_ visit: HistoryVisit) async throws {
        try await writer.write { db in
            var visit = visit
            try visit.insert(db)
        }
    }

    /// The newest visits first.
    public func recentVisits(limit: Int) async throws -> [HistoryVisit] {
        try await writer.read { db in
            try HistoryVisit.order(Column("visitedAt").desc).limit(limit).fetchAll(db)
        }
    }
}

/// One page load the user saw.
public struct HistoryVisit: Equatable, Sendable, Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "historyVisit"

    public var id: Int64?
    public var url: URL
    public var title: String?
    public var visitedAt: Date

    public init(url: URL, title: String?, visitedAt: Date) {
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
