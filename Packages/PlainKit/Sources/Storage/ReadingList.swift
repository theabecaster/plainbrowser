import BrowserCore
import Foundation
import GRDB

/// A page saved to read later (docs/research/bookmarks.md). Unread until it is opened from the
/// reading list. Its reader copy, when the page had an article, is stored apart
/// (`AppDatabase.savedCopy(for:)`), so lists never read it.
public struct ReadingListItem: Hashable, Sendable, Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = Schema.readingListItem

    public var id: Int64?
    public var url: URL
    /// The URL as people type it, for the full-text index (`HistoryPlace.searchableAddress`).
    var address: String
    public var title: String?
    /// The publication's name from the article, if it named one.
    public var siteName: String?
    /// The article's first lines or description, if it had any.
    public var excerpt: String?
    public var addedAt: Date
    /// When it was opened from the list (or marked read); nil while unread.
    public var readAt: Date?
    /// The saved copy's length in characters; nil when the page was saved as a link only.
    public var copyLength: Int?

    public var isRead: Bool { readAt != nil }
    public var hasCopy: Bool { copyLength != nil }

    /// Minutes to read the saved copy (at least 1), or nil without one.
    public var readingMinutes: Int? {
        copyLength.map { max(1, Int((Double($0) / Double(FixedChoices.readingCharactersPerMinute)).rounded())) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// What the page menu saves: the page, and its article when the reader found one.
public struct SavedPage: Sendable {
    public var url: URL
    public var title: String?
    public var siteName: String?
    public var excerpt: String?
    /// The reader copy, encoded by the caller (the reader's article as JSON), or nil.
    public var copy: Data?
    /// The copy's text length, for the reading time.
    public var copyLength: Int?

    public init(
        url: URL, title: String?, siteName: String? = nil, excerpt: String? = nil, copy: Data? = nil, copyLength: Int? = nil
    ) {
        self.url = url
        self.title = title
        self.siteName = siteName
        self.excerpt = excerpt
        self.copy = copy
        self.copyLength = copyLength
    }
}

extension AppDatabase {
    /// Saves `page` for later, or saves it again: it moves to the top as unread, and a new copy
    /// replaces the old one (a page saved again without an article keeps the copy it had).
    /// The copy is compressed before the write, off the database's queue.
    @discardableResult
    public func saveForLater(_ page: SavedPage, at date: Date = Date()) async throws -> ReadingListItem {
        let compressed = try await Self.compress(page.copy)
        return try await writer.write { db in
            let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            var item = try ReadingListItem.filter(Column("url") == page.url).fetchOne(db)
                ?? ReadingListItem(
                    id: nil, url: page.url, address: HistoryPlace.searchableAddress(page.url), title: nil,
                    siteName: nil, excerpt: nil, addedAt: date, readAt: nil, copyLength: nil
                )
            if let title, !title.isEmpty { item.title = title }
            if let siteName = page.siteName { item.siteName = siteName }
            if let excerpt = page.excerpt { item.excerpt = excerpt }
            item.addedAt = date
            item.readAt = nil
            if compressed != nil { item.copyLength = page.copyLength ?? 0 }
            try item.save(db)
            if let compressed, let id = item.id {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO \(Schema.readingListCopy) (itemID, data) VALUES (?, ?)",
                    arguments: [id, compressed]
                )
            }
            return item
        }
    }

    /// The reading list item for exactly `url`, or nil when the page is not saved.
    public func readingListItem(for url: URL) async throws -> ReadingListItem? {
        try await writer.read { db in
            try ReadingListItem.filter(Column("url") == url).fetchOne(db)
        }
    }

    /// Whether `url` is a favorite and whether it is in the reading list, in one read (the page
    /// menu asks both as it opens).
    public func marks(for url: URL) async throws -> (isFavorite: Bool, isSaved: Bool) {
        try await writer.read { db in
            let favorite = try Favorite.filter(Column("url") == url).fetchCount(db) > 0
            let saved = try ReadingListItem.filter(Column("url") == url).fetchCount(db) > 0
            return (favorite, saved)
        }
    }

    /// Unread pages first, newest saved first; then read pages, most recently read first. An empty
    /// `query` lists everything; otherwise only pages whose title or address match, with the
    /// address bar's word rules (`HistoryQuery`).
    public func readingList(matching query: String = "", limit: Int = 1_000) async throws -> [ReadingListItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return try await writer.read { db in
                try ReadingListItem.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM \(Schema.readingListItem)
                    ORDER BY readAt IS NOT NULL, readAt DESC, addedAt DESC
                    LIMIT ?
                    """,
                    arguments: [limit]
                )
            }
        }
        guard let pattern = HistoryQuery(trimmed).pattern else { return [] }
        return try await writer.read { db in
            try ReadingListItem.fetchAll(
                db,
                sql: """
                SELECT r.* FROM \(Schema.readingListSearch) s
                JOIN \(Schema.readingListItem) r ON r.id = s.rowid
                WHERE \(Schema.readingListSearch) MATCH ?
                ORDER BY r.readAt IS NOT NULL, r.readAt DESC, r.addedAt DESC
                LIMIT ?
                """,
                arguments: [pattern, limit]
            )
        }
    }

    /// Whether the reading list has any unread page.
    public func hasUnreadReadingList() async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM \(Schema.readingListItem) WHERE readAt IS NULL)"
            ) ?? false
        }
    }

    /// Marks the item read (`at` a date) or unread (nil).
    public func setReadingListItemRead(id: Int64, at date: Date?) async throws {
        try await writer.write { db in
            _ = try ReadingListItem.filter(key: id).updateAll(db, Column("readAt").set(to: date))
        }
    }

    /// Marks the page at `url` read, if it is saved and unread.
    public func markReadingListRead(url: URL, at date: Date = Date()) async throws {
        try await writer.write { db in
            _ = try ReadingListItem.filter(Column("url") == url && Column("readAt") == nil)
                .updateAll(db, Column("readAt").set(to: date))
        }
    }

    /// Removes the item and its copy.
    public func removeReadingListItem(id: Int64) async throws {
        try await writer.write { db in
            _ = try ReadingListItem.deleteOne(db, key: id)
        }
    }

    /// Removes the page at `url` from the reading list, with its copy.
    public func removeFromReadingList(url: URL) async throws {
        try await writer.write { db in
            _ = try ReadingListItem.filter(Column("url") == url).deleteAll(db)
        }
    }

    /// The saved copy of the page at `url` (as the caller encoded it), or nil when it has none.
    /// Decompressed off the database's queue.
    public func savedCopy(for url: URL) async throws -> Data? {
        let compressed = try await writer.read { db in
            try Data.fetchOne(
                db,
                sql: """
                SELECT c.data FROM \(Schema.readingListCopy) c
                JOIN \(Schema.readingListItem) r ON r.id = c.itemID
                WHERE r.url = ?
                """,
                arguments: [url]
            )
        }
        guard let compressed else { return nil }
        return try await Self.decompress(compressed)
    }

    @concurrent
    static func compress(_ data: Data?) async throws -> Data? {
        guard let data else { return nil }
        return try (data as NSData).compressed(using: .lzfse) as Data
    }

    @concurrent
    static func decompress(_ data: Data) async throws -> Data {
        try (data as NSData).decompressed(using: .lzfse) as Data
    }

    /// Saved pages whose title or address match, for the address bar: unread ones are marked
    /// (`PageCandidate.isSaved`) and rank after favorites; read ones match as plain pages, with
    /// the page's history frecency when it has one.
    static func readingListMatches(_ query: HistoryQuery, limit: Int, in db: Database) throws -> [PageCandidate] {
        guard let pattern = query.pattern, limit > 0 else { return [] }
        let statement = try db.cachedStatement(sql: """
            SELECT r.url, r.title, r.readAt IS NULL AS unread, p.frecency
            FROM \(Schema.readingListSearch) s
            JOIN \(Schema.readingListItem) r ON r.id = s.rowid
            LEFT JOIN \(Schema.historyPlace) p ON p.url = r.url
            WHERE \(Schema.readingListSearch) MATCH ?
            ORDER BY unread DESC, r.addedAt DESC
            LIMIT ?
            """)
        return try Row.fetchAll(statement, arguments: [pattern, limit]).compactMap { row in
            guard let url = URL(string: row["url"]) else { return nil }
            return PageCandidate(
                url: url, title: row["title"], frecency: row["frecency"], isFavorite: false, isSaved: row["unread"]
            )
        }
    }
}
