import BrowserCore
import Foundation
import GRDB

/// One page load the user saw.
public struct HistoryVisit: Hashable, Sendable, Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = Schema.historyVisit

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

/// A change to history, applied in order as part of a batch (see `HistoryRecorder`).
public enum HistoryChange: Hashable, Sendable {
    /// The user saw `url`.
    case visit(HistoryVisit)
    /// The page at `url` reported its title, usually after the visit was recorded.
    case title(String, url: URL)
}

/// One row per address: the aggregate the address bar ranks and searches.
struct HistoryPlace: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = Schema.historyPlace

    var id: Int64?
    var url: URL
    var address: String
    var title: String?
    var visitCount: Int
    var lastVisitedAt: Date
    var frecency: Double

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Adds one visit to the place for `url`, creating it on first visit.
    static func recordVisit(url: URL, title: String?, at date: Date, in db: Database) throws {
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        if var place = try HistoryPlace.filter(Column("url") == url).fetchOne(db) {
            place.visitCount += 1
            place.lastVisitedAt = max(place.lastVisitedAt, date)
            place.frecency = Frecency.adding(visitAt: date, to: place.frecency)
            if let title { place.title = title }
            try place.update(db)
        } else {
            var place = HistoryPlace(
                url: url, address: searchableAddress(url), title: title, visitCount: 1,
                lastVisitedAt: date, frecency: Frecency.adding(visitAt: date, to: nil)
            )
            try place.insert(db)
        }
    }

    /// The URL as people type it: no scheme, no `www.`, no trailing slash or fragment.
    static func searchableAddress(_ url: URL) -> String {
        var text = url.absoluteString
        if let scheme = url.scheme, let range = text.range(of: scheme + "://", options: [.anchored, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        while text.hasSuffix("/") { text.removeLast() }
        return text.removingPercentEncoding ?? text
    }
}

extension AppDatabase {
    /// Records one visit. Page loads should go through `HistoryRecorder`, which batches them.
    public func record(_ visit: HistoryVisit) async throws {
        try await apply([.visit(visit)])
    }

    /// Applies history changes in order, in one transaction.
    public func apply(_ changes: [HistoryChange]) async throws {
        guard !changes.isEmpty else { return }
        try await writer.write { db in
            for change in changes {
                switch change {
                case .visit(var visit):
                    try visit.insert(db)
                    try HistoryPlace.recordVisit(url: visit.url, title: visit.title, at: visit.visitedAt, in: db)
                case .title(let title, let url):
                    guard !title.isEmpty else { continue }
                    try HistoryPlace.filter(Column("url") == url).updateAll(db, Column("title").set(to: title))
                    // Name the newest visit too, so the History screen shows the title.
                    try db.execute(
                        sql: """
                        UPDATE \(Schema.historyVisit) SET title = ?
                        WHERE id = (SELECT id FROM \(Schema.historyVisit) WHERE url = ? ORDER BY visitedAt DESC LIMIT 1)
                        """,
                        arguments: [title, url]
                    )
                }
            }
        }
    }

    /// The newest visits first.
    public func recentVisits(limit: Int) async throws -> [HistoryVisit] {
        try await writer.read { db in
            try HistoryVisit.order(Column("visitedAt").desc).limit(limit).fetchAll(db)
        }
    }

    /// History pages whose title or address contain words starting with each typed word, best
    /// frecency first. This is the address bar's query; it must stay under 16 ms at p95 with
    /// 100k pages (docs/plan.md, section 2).
    public func searchHistory(_ text: String, limit: Int = FixedChoices.maxPageSuggestions) async throws -> [PageCandidate] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try await writer.read { db in
            try Self.historyMatches(pattern, limit: limit, in: db)
        }
    }

    /// History and favorite matches for the address bar, read in one consistent snapshot. Feed the
    /// result to `AddressBarSuggestions.merge` with the engine's suggestions.
    public func addressBarCandidates(
        for text: String, historyLimit: Int = FixedChoices.maxPageSuggestions
    ) async throws -> (history: [PageCandidate], favorites: [PageCandidate]) {
        let pattern = FTS5Pattern(matchingAllPrefixesIn: text)
        return try await writer.read { db in
            let history = try pattern.map { try Self.historyMatches($0, limit: historyLimit, in: db) } ?? []
            let favorites = try Self.favoriteMatches(text, in: db)
            return (history, favorites)
        }
    }

    static func historyMatches(_ pattern: FTS5Pattern, limit: Int, in db: Database) throws -> [PageCandidate] {
        // The FTS match yields the rows, then SQLite keeps only the `limit` best by frecency.
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT p.url, p.title, p.frecency
            FROM \(Schema.historySearch) s
            JOIN \(Schema.historyPlace) p ON p.id = s.rowid
            WHERE \(Schema.historySearch) MATCH ?
            ORDER BY p.frecency DESC
            LIMIT ?
            """,
            arguments: [pattern, limit]
        )
        return rows.compactMap { row in
            guard let url = URL(string: row["url"]) else { return nil }
            return PageCandidate(url: url, title: row["title"], frecency: row["frecency"], isFavorite: false)
        }
    }

    /// Removes every visit to `url`.
    public func deleteHistory(for url: URL) async throws {
        try await writer.write { db in
            _ = try HistoryVisit.filter(Column("url") == url).deleteAll(db)
            _ = try HistoryPlace.filter(Column("url") == url).deleteAll(db)
        }
    }

    /// Removes all history. The full-text index follows through its triggers.
    public func clearHistory() async throws {
        try await writer.write { db in
            _ = try HistoryVisit.deleteAll(db)
            _ = try HistoryPlace.deleteAll(db)
        }
    }
}
