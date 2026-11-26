import BrowserCore
import Foundation
import GRDB
import PerfSignposts

/// One tab row: an open tab (`isArchived` false, in a window) or an archived one. The web view's
/// `interactionState` (back/forward list and scroll) is a file in `TabStateStore`, not in this
/// row; the thumbnail is a file the engine owns, named here.
public struct TabRecord: Hashable, Sendable, Codable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = Schema.tab
    /// Ids are text (`uuidString`), so SQL can name them. GRDB 7 only reads this function form; a
    /// `databaseUUIDEncodingStrategy` property is silently ignored and stores 16-byte blobs.
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    public var id: UUID
    public var url: URL?
    public var title: String?
    /// Sort key among the window's open tabs; 0 is first.
    public var position: Int
    public var lastActiveAt: Date
    public var isArchived: Bool
    public var archivedAt: Date?
    /// Nil for archived tabs, and for rows written before windows existed.
    public var windowID: UUID?
    public var openerID: UUID?
    public var isPinned: Bool
    public var createdAt: Date?
    public var thumbnailFile: String?
    public var thumbnailRevision: Int?

    public init(
        id: UUID, url: URL?, title: String?, position: Int, lastActiveAt: Date,
        isArchived: Bool = false, archivedAt: Date? = nil, windowID: UUID? = nil, openerID: UUID? = nil,
        isPinned: Bool = false, createdAt: Date? = nil, thumbnailFile: String? = nil, thumbnailRevision: Int? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.position = position
        self.lastActiveAt = lastActiveAt
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.windowID = windowID
        self.openerID = openerID
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.thumbnailFile = thumbnailFile
        self.thumbnailRevision = thumbnailRevision
    }

    init(entry: TabEntry, windowID: UUID?, position: Int) {
        self.init(
            id: entry.id, url: entry.url, title: entry.title, position: position, lastActiveAt: entry.lastActiveAt,
            windowID: windowID, openerID: entry.openerID, isPinned: entry.isPinned, createdAt: entry.createdAt,
            thumbnailFile: entry.thumbnail?.fileName, thumbnailRevision: entry.thumbnail?.revision
        )
    }

    public var entry: TabEntry {
        TabEntry(
            id: id, url: url, title: title, openerID: openerID, isPinned: isPinned,
            createdAt: createdAt ?? lastActiveAt, lastActiveAt: lastActiveAt,
            thumbnail: thumbnailFile.map { TabThumbnail(fileName: $0, revision: thumbnailRevision ?? 0) }
        )
    }
}

/// A tab in the archive, for the archive screen and its search.
public struct ArchivedTab: Hashable, Sendable, Identifiable {
    public var entry: TabEntry
    public var archivedAt: Date
    public var id: TabID { entry.id }

    public init(entry: TabEntry, archivedAt: Date) {
        self.entry = entry
        self.archivedAt = archivedAt
    }
}

/// One window's pane selection.
struct TabWindowRecord: Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = Schema.tabWindow
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    var id: UUID
    var position: Int
    var panes: String
    var focusedPane: Int

    init(_ window: WindowSession, position: Int) {
        id = window.id
        self.position = position
        panes = window.panes.map { $0?.uuidString ?? "" }.joined(separator: ",")
        focusedPane = window.focusedPane
    }

    var paneTabIDs: [TabID?] {
        panes.split(separator: ",", omittingEmptySubsequences: false).map { UUID(uuidString: String($0)) }
    }
}

/// One tab of a recently closed batch.
struct ClosedTabRecord: Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = Schema.closedTab
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    var rowID: Int64?
    var batchID: UUID
    var tabPosition: Int
    var closedAt: Date
    var id: UUID
    var windowID: UUID
    var windowIndex: Int
    var previousTabID: UUID?
    var pane: Int?
    var wasFocused: Bool
    var url: URL?
    var title: String?
    var openerID: UUID?
    var isPinned: Bool
    var createdAt: Date
    var lastActiveAt: Date
    var thumbnailFile: String?
    var thumbnailRevision: Int?

    init(_ tab: ClosedTab, batch: ClosedTabBatch, position: Int) {
        batchID = batch.id
        tabPosition = position
        closedAt = batch.closedAt
        id = tab.entry.id
        windowID = tab.windowID
        windowIndex = tab.index
        previousTabID = tab.previousTabID
        pane = tab.pane
        wasFocused = tab.wasFocused
        url = tab.entry.url
        title = tab.entry.title
        openerID = tab.entry.openerID
        isPinned = tab.entry.isPinned
        createdAt = tab.entry.createdAt
        lastActiveAt = tab.entry.lastActiveAt
        thumbnailFile = tab.entry.thumbnail?.fileName
        thumbnailRevision = tab.entry.thumbnail?.revision
    }

    var closedTab: ClosedTab {
        ClosedTab(
            entry: TabEntry(
                id: id, url: url, title: title, openerID: openerID, isPinned: isPinned, createdAt: createdAt,
                lastActiveAt: lastActiveAt,
                thumbnail: thumbnailFile.map { TabThumbnail(fileName: $0, revision: thumbnailRevision ?? 0) }
            ),
            windowID: windowID, index: windowIndex, previousTabID: previousTabID, pane: pane,
            wasFocused: wasFocused
        )
    }
}

extension AppDatabase {
    /// The open session for `TabStore(session:)`: windows, their regular tabs and selection, and
    /// the recently closed stack. The archive is not read; it loads when its screen opens.
    /// Runs on GRDB's queue, never the caller's.
    public func loadTabSession() async throws -> TabSession {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabSessionLoad, id: signposter.makeSignpostID())
        defer { signposter.endInterval(Signposts.tabSessionLoad, interval) }
        return try await tabSession.load()
    }

    static func readTabSession(_ db: Database) throws -> TabSession {
        let windowRecords = try TabWindowRecord.order(Column("position")).fetchAll(db)
        let records = try TabRecord.filter(Column("isArchived") == false).order(Column("position")).fetchAll(db)
        var idsByWindow: [UUID: [TabID]] = [:]
        for record in records {
            if let window = record.windowID { idsByWindow[window, default: []].append(record.id) }
        }
        let windows = windowRecords.map { record in
            WindowSession(
                id: record.id, tabIDs: idsByWindow[record.id] ?? [], panes: record.paneTabIDs,
                focusedPane: record.focusedPane
            )
        }
        let closedRecords = try ClosedTabRecord.order(Column("rowID")).fetchAll(db)
        var batches: [ClosedTabBatch] = []
        for record in closedRecords {
            if batches.last?.id == record.batchID {
                batches[batches.count - 1].tabs.append(record.closedTab)
            } else {
                batches.append(ClosedTabBatch(id: record.batchID, closedAt: record.closedAt, tabs: [record.closedTab]))
            }
        }
        return TabSession(windows: windows, tabs: records.map(\.entry), recentlyClosed: batches)
    }

    /// Archived tabs, most recently archived first, a page at a time.
    public func archivedTabs(limit: Int = FixedChoices.archiveSearchLimit, offset: Int = 0) async throws -> [ArchivedTab] {
        await tabSession.flush()
        return try await writer.read { db in
            try TabRecord.filter(Column("isArchived") == true)
                .order(Column("archivedAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
                .map(Self.archivedTab)
        }
    }

    /// Archived tabs whose title or address has words starting with each typed word, most
    /// recently archived first. Empty text lists the archive.
    public func searchArchivedTabs(_ text: String, limit: Int = FixedChoices.archiveSearchLimit) async throws -> [ArchivedTab] {
        guard let pattern = Self.archivePattern(text) else { return try await archivedTabs(limit: limit) }
        await tabSession.flush()
        return try await writer.read { db in
            try TabRecord.fetchAll(
                db,
                sql: """
                SELECT \(Schema.tab).* FROM \(Schema.tab)
                JOIN \(Schema.tabSearch) ON \(Schema.tabSearch).rowid = \(Schema.tab).rowid
                WHERE \(Schema.tabSearch) MATCH ? AND \(Schema.tab).isArchived
                ORDER BY \(Schema.tab).archivedAt DESC
                LIMIT ?
                """,
                arguments: [pattern, limit]
            ).map(Self.archivedTab)
        }
    }

    public func archivedTabCount() async throws -> Int {
        await tabSession.flush()
        return try await writer.read { db in
            try TabRecord.filter(Column("isArchived") == true).fetchCount(db)
        }
    }

    /// Every tab id a row still names (open, archived or recently closed). The engine prunes
    /// thumbnail files outside this set.
    public func referencedTabIDs() async throws -> Set<TabID> {
        await tabSession.flush()
        return try await writer.read { db in try Self.referencedTabIDs(db) }
    }

    /// Deletes state files that no tab row refers to (left behind by a crash between the two
    /// writes). Run once at launch, off the critical path.
    ///
    /// Safe alongside tab saves, given the callers' contract: save a tab's row before its first
    /// state file. Files written after cleanup started are skipped. A file written before that
    /// belongs to a row saved before that, which the id snapshot (taken after the start) holds.
    /// File work runs off GRDB's queues, so other writes never wait for it.
    ///
    /// - Parameters:
    ///   - extra: ids to keep besides the rows' (the caller's open tabs whose rows may not be
    ///     written yet).
    ///   - cutoff: only files written before it may go; take it before anything the caller
    ///     flushes, so a tab made meanwhile keeps its file. Defaults to now.
    public func removeOrphanedTabStates(alsoKeeping extra: Set<TabID> = [], writtenBefore cutoff: Date? = nil) async throws {
        let started = cutoff ?? Date()
        let ids = try await writer.read { db in try Self.referencedTabIDs(db) }
        await tabStates.removeOrphans(keeping: ids.union(extra), writtenBefore: started)
    }

    static func referencedTabIDs(_ db: Database) throws -> Set<TabID> {
        try UUID.fetchSet(db, sql: "SELECT id FROM \(Schema.tab) UNION SELECT id FROM \(Schema.closedTab)")
    }

    private static func archivedTab(_ record: TabRecord) -> ArchivedTab {
        ArchivedTab(entry: record.entry, archivedAt: record.archivedAt ?? record.lastActiveAt)
    }

    /// Each typed word as a quoted prefix phrase (`"recipes.ex"*`), which FTS5 always parses and
    /// which matches the word's tokens in order. Nil when there is nothing to search for.
    static func archivePattern(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .map { word in
                let clean = String(String.UnicodeScalarView(word.unicodeScalars.filter {
                    !CharacterSet.controlCharacters.contains($0)
                }))
                return "\"" + clean.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
            }
        return words.isEmpty ? nil : words.joined(separator: " ")
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

    /// Removes state files of tabs not in `keep` that were last written before `cutoff`.
    @concurrent
    func removeOrphans(keeping keep: Set<UUID>, writtenBefore cutoff: Date) async {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where file.pathExtension == "state" {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), keep.contains(id) { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
