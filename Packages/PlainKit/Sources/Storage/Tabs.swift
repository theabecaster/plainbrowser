import BrowserCore
import Foundation
import GRDB

/// What survives a relaunch for one tab. The web view's `interactionState` (back/forward list and
/// scroll) is a blob in `TabStateStore`, not in this row.
public struct TabRecord: Hashable, Sendable, Codable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = Schema.tab
    public static let databaseUUIDEncodingStrategy = DatabaseUUIDEncodingStrategy.uppercaseString

    public var id: UUID
    public var url: URL?
    public var title: String?
    /// Sort key among open tabs; 0 is first.
    public var position: Int
    public var lastActiveAt: Date
    public var isArchived: Bool
    public var archivedAt: Date?

    public init(
        id: UUID, url: URL?, title: String?, position: Int, lastActiveAt: Date,
        isArchived: Bool = false, archivedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.position = position
        self.lastActiveAt = lastActiveAt
        self.isArchived = isArchived
        self.archivedAt = archivedAt
    }
}

extension AppDatabase {
    /// Open tabs in order.
    public func openTabs() async throws -> [TabRecord] {
        try await writer.read { db in
            try TabRecord.filter(Column("isArchived") == false).order(Column("position")).fetchAll(db)
        }
    }

    /// Archived tabs, most recently archived first.
    public func archivedTabs() async throws -> [TabRecord] {
        try await writer.read { db in
            try TabRecord.filter(Column("isArchived") == true).order(Column("archivedAt").desc).fetchAll(db)
        }
    }

    /// Archived tabs whose title or address contains `text`, most recently archived first.
    public func searchArchivedTabs(_ text: String) async throws -> [TabRecord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await archivedTabs() }
        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let like = "%\(escaped)%"
        return try await writer.read { db in
            try TabRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM \(Schema.tab)
                WHERE isArchived AND (title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\')
                ORDER BY archivedAt DESC
                """,
                arguments: [like, like]
            )
        }
    }

    /// Inserts or updates tabs in one transaction.
    public func saveTabs(_ tabs: [TabRecord]) async throws {
        guard !tabs.isEmpty else { return }
        try await writer.write { db in
            for tab in tabs {
                try tab.upsert(db)
            }
        }
    }

    /// Archives open tabs last used before `cutoff`, and returns their ids. The tab's state file
    /// is kept, so an archived tab reopens where it was.
    @discardableResult
    public func archiveTabs(lastActiveBefore cutoff: Date, now: Date = Date()) async throws -> [UUID] {
        try await writer.write { db in
            let due = TabRecord.filter(Column("isArchived") == false && Column("lastActiveAt") < cutoff)
            let ids = try due.fetchAll(db).map(\.id)
            try due.updateAll(db, Column("isArchived").set(to: true), Column("archivedAt").set(to: now))
            return ids
        }
    }

    /// Deletes tabs and their state files.
    public func deleteTabs(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await writer.write { db in
            _ = try TabRecord.deleteAll(db, ids: ids)
        }
        await tabStates.delete(ids)
    }

    /// Deletes state files that no tab row refers to (left behind by a crash between the two
    /// writes). Run once at launch, off the critical path.
    public func removeOrphanedTabStates() async throws {
        let ids = try await writer.read { db in
            try UUID.fetchSet(db, sql: "SELECT id FROM \(Schema.tab)")
        }
        await tabStates.removeAll(except: ids)
    }
}

/// `WKWebView.interactionState` blobs, one file per tab, in a folder this type owns.
///
/// All file work runs off the caller's actor (`@concurrent`), so the main thread never touches
/// the disk.
public struct TabStateStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The file holding the state of tab `id`.
    public func fileURL(for id: UUID) -> URL {
        directory.appending(path: id.uuidString + ".state", directoryHint: .notDirectory)
    }

    /// Writes the state for tab `id`, replacing any earlier one atomically.
    @concurrent
    public func write(_ data: Data, for id: UUID) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: id), options: .atomic)
    }

    /// The state for tab `id`, or nil when there is none.
    @concurrent
    public func read(for id: UUID) async throws -> Data? {
        do {
            return try Data(contentsOf: fileURL(for: id))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    @concurrent
    public func delete(_ ids: [UUID]) async {
        for id in ids {
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }
    }

    /// Removes every state file except those of `keep`.
    @concurrent
    public func removeAll(except keep: Set<UUID>) async {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "state" {
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            if id.map({ !keep.contains($0) }) ?? true {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
