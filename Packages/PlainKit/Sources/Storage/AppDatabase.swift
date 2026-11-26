import Foundation
import GRDB

/// The app's one SQLite database. Owns the schema (migrations) and is the only place that talks to
/// GRDB. Every call is async and runs on GRDB's own queues, never on the main thread.
///
/// The API is split by feature in extensions: history (`History.swift`), favorites, tabs, favicons
/// and settings.
public final class AppDatabase: Sendable {
    let writer: any DatabaseWriter
    /// Tab `interactionState` blobs, stored as files next to the database.
    public let tabStates: TabStateStore
    /// The one writer of history: page loads record through it, and history deletes go through
    /// it so they are ordered with visits still buffered.
    public let historyRecorder: HistoryRecorder

    /// Opens (or creates) the database at `url` and migrates it to the current schema. Tab state
    /// files live in a `TabState` folder next to it unless `tabStateDirectory` says otherwise.
    ///
    /// Opening and migrating touch the disk, so they run on the global executor, never on the
    /// caller's actor.
    @concurrent
    public static func open(at url: URL, tabStateDirectory: URL? = nil) async throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.label = "Plain.AppDatabase"
        configuration.prepareDatabase { db in
            // WAL (DatabasePool's default) plus NORMAL sync is durable across app crashes and
            // skips an fsync per transaction. Only a power loss can drop the last transaction.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        let states = tabStateDirectory ?? url.deletingLastPathComponent().appending(path: "TabState", directoryHint: .isDirectory)
        return try AppDatabase(pool, tabStates: TabStateStore(directory: states))
    }

    /// An empty database in memory, for tests and previews. Tab state files go to a fresh
    /// temporary folder.
    public static func inMemory() throws -> AppDatabase {
        let states = FileManager.default.temporaryDirectory
            .appending(path: "PlainTabState-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try AppDatabase(DatabaseQueue(), tabStates: TabStateStore(directory: states))
    }

    private init(_ writer: any DatabaseWriter, tabStates: TabStateStore) throws {
        self.writer = writer
        self.tabStates = tabStates
        historyRecorder = HistoryRecorder(writer: writer)
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        Schema.register(in: &migrator)
        return migrator
    }
}
