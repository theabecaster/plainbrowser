import BrowserCore
import Foundation
import GRDB

/// A page pinned above the keyboard, in the user's order.
public struct Favorite: Hashable, Sendable, Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = Schema.favorite

    public var id: Int64?
    public var url: URL
    public var title: String?
    /// Sort key; 0 is first. Kept dense (0, 1, 2, ...) by every write.
    public var position: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension AppDatabase {
    /// Favorites in display order.
    public func favorites() async throws -> [Favorite] {
        try await writer.read { db in
            try Favorite.order(Column("position")).fetchAll(db)
        }
    }

    /// Adds `url` at the end, or returns the existing favorite for it.
    @discardableResult
    public func addFavorite(url: URL, title: String?) async throws -> Favorite {
        try await writer.write { db in
            if let existing = try Favorite.filter(Column("url") == url).fetchOne(db) { return existing }
            let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position) + 1, 0) FROM \(Schema.favorite)") ?? 0
            var favorite = Favorite(id: nil, url: url, title: title, position: next)
            try favorite.insert(db)
            return favorite
        }
    }

    public func renameFavorite(id: Int64, title: String) async throws {
        try await writer.write { db in
            _ = try Favorite.filter(key: id).updateAll(db, Column("title").set(to: title))
        }
    }

    public func removeFavorite(id: Int64) async throws {
        try await writer.write { db in
            _ = try Favorite.deleteOne(db, key: id)
            try Self.renumberFavorites(in: db, order: nil)
        }
    }

    /// Moves the favorite with `id` to `index` (clamped), shifting the others.
    public func moveFavorite(id: Int64, to index: Int) async throws {
        try await writer.write { db in
            var ids = try Int64.fetchAll(db, sql: "SELECT id FROM \(Schema.favorite) ORDER BY position")
            guard let from = ids.firstIndex(of: id) else { return }
            ids.remove(at: from)
            ids.insert(id, at: min(max(0, index), ids.count))
            try Self.renumberFavorites(in: db, order: ids)
        }
    }

    /// Case- and diacritic-insensitive form, so "cafe" matches "Café" as in history search.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func renumberFavorites(in db: Database, order: [Int64]?) throws {
        let ids = try order ?? Int64.fetchAll(db, sql: "SELECT id FROM \(Schema.favorite) ORDER BY position")
        let statement = try db.cachedStatement(sql: "UPDATE \(Schema.favorite) SET position = ? WHERE id = ?")
        for (position, id) in ids.enumerated() {
            try statement.execute(arguments: [position, id])
        }
    }

    /// Favorites whose title or address contains every typed word, in favorites order, with the
    /// page's history frecency attached when it has one.
    static func favoriteMatches(_ text: String, in db: Database) throws -> [PageCandidate] {
        let words = fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT f.url, COALESCE(f.title, p.title) AS title, p.frecency
            FROM \(Schema.favorite) f
            LEFT JOIN \(Schema.historyPlace) p ON p.url = f.url
            ORDER BY f.position
            """
        )
        // Favorites are a short list, so filtering here is cheaper than building a LIKE query.
        return rows.compactMap { row in
            guard let url = URL(string: row["url"]) else { return nil }
            let title: String? = row["title"]
            let haystack = fold(HistoryPlace.searchableAddress(url) + " " + (title ?? ""))
            guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
            return PageCandidate(url: url, title: title, frecency: row["frecency"], isFavorite: true)
        }
    }
}
