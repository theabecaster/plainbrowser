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

    var url: URL {
        switch self {
        case .visit(let visit): visit.url
        case .title(_, let url): url
        }
    }
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
    // Direct writes are internal: `historyRecorder` is the one owner of history writes, so a
    // delete can never race a batch still waiting in its buffer. The public deletes below go
    // through it.

    func record(_ visit: HistoryVisit) async throws {
        try await apply([.visit(visit)])
    }

    /// Applies history changes in order, in one transaction.
    func apply(_ changes: [HistoryChange]) async throws {
        try await Self.apply(changes, to: writer)
    }

    static func apply(_ changes: [HistoryChange], to writer: any DatabaseWriter) async throws {
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

    /// Removes every visit to `url`, written at once (see `HistoryRecorder.deleteHistory`).
    static func deleteHistory(for url: URL, in writer: any DatabaseWriter) async throws {
        try await writer.write { db in
            _ = try HistoryVisit.filter(Column("url") == url).deleteAll(db)
            _ = try HistoryPlace.filter(Column("url") == url).deleteAll(db)
        }
    }

    /// Removes visits made at or after `start`, or all history when `start` is nil, written at
    /// once (see `HistoryRecorder.clearHistory`). The full-text index follows through its
    /// triggers.
    ///
    /// A page with older visits left keeps its row, with its count, last visit and frecency
    /// rebuilt from those visits, so the address bar ranks it as if the cleared visits never
    /// happened.
    static func clearHistory(since start: Date?, in writer: any DatabaseWriter) async throws {
        try await writer.write { db in
            guard let start else {
                _ = try HistoryVisit.deleteAll(db)
                _ = try HistoryPlace.deleteAll(db)
                return
            }
            let urls = try String.fetchAll(
                db, sql: "SELECT DISTINCT url FROM \(Schema.historyVisit) WHERE visitedAt >= ?", arguments: [start]
            )
            _ = try HistoryVisit.filter(Column("visitedAt") >= start).deleteAll(db)
            for url in urls {
                let left = try Date.fetchAll(
                    db, sql: "SELECT visitedAt FROM \(Schema.historyVisit) WHERE url = ? ORDER BY visitedAt", arguments: [url]
                )
                guard let last = left.last else {
                    try db.execute(sql: "DELETE FROM \(Schema.historyPlace) WHERE url = ?", arguments: [url])
                    continue
                }
                let frecency = left.reduce(nil as Double?) { Frecency.adding(visitAt: $1, to: $0) } ?? 0
                // The title the page had at its newest kept visit, so a title seen only in the
                // cleared time is no longer searchable.
                let title = try String.fetchOne(
                    db,
                    sql: """
                    SELECT title FROM \(Schema.historyVisit)
                    WHERE url = ? AND title IS NOT NULL AND title != ''
                    ORDER BY visitedAt DESC LIMIT 1
                    """,
                    arguments: [url]
                )
                try db.execute(
                    sql: "UPDATE \(Schema.historyPlace) SET visitCount = ?, lastVisitedAt = ?, frecency = ?, title = ? WHERE url = ?",
                    arguments: [left.count, last, frecency, title, url]
                )
            }
        }
    }

    /// Removes every visit to `url`, including visits still buffered in `historyRecorder`.
    public func deleteHistory(for url: URL) async throws {
        try await historyRecorder.deleteHistory(for: url)
    }

    /// Removes visits made since `start`, or all history when `start` is nil, including visits
    /// still buffered in `historyRecorder`.
    public func clearHistory(since start: Date?) async throws {
        try await historyRecorder.clearHistory(since: start)
    }

    /// Visits for the History screen, newest first. An empty `query` means every visit;
    /// otherwise only visits to pages whose title or address match it, through the same
    /// full-text index and word rules as the address bar.
    public func visits(matching query: String, limit: Int) async throws -> [HistoryVisit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await recentVisits(limit: limit) }
        guard let pattern = HistoryQuery(trimmed).pattern, limit > 0 else { return [] }
        return try await writer.read { db in
            // The index finds the pages; their visits come from `historyVisit_on_url`, and the
            // newest `limit` are kept with a top-N sort.
            try HistoryVisit.fetchAll(
                db,
                sql: """
                SELECT v.* FROM \(Schema.historyVisit) v
                WHERE v.url IN (
                    SELECT p.url FROM \(Schema.historySearch) s
                    JOIN \(Schema.historyPlace) p ON p.id = s.rowid
                    WHERE \(Schema.historySearch) MATCH ?
                )
                ORDER BY v.visitedAt DESC
                LIMIT ?
                """,
                arguments: [pattern, limit]
            )
        }
    }

    /// The newest visits first.
    public func recentVisits(limit: Int) async throws -> [HistoryVisit] {
        try await writer.read { db in
            try HistoryVisit.order(Column("visitedAt").desc).limit(limit).fetchAll(db)
        }
    }

    /// History pages whose title or address contain words starting with each typed word. Pages
    /// whose address starts with the typed text come first, so the address bar's top hit is never
    /// crowded out; the rest follow by frecency. This is the address bar's query; it must stay
    /// under 16 ms at p95 with 100k pages (docs/plan.md, section 2).
    public func searchHistory(_ text: String, limit: Int = FixedChoices.maxPageSuggestions) async throws -> [PageCandidate] {
        let query = HistoryQuery(text)
        guard let pattern = query.pattern else { return [] }
        return try await writer.read { db in
            try Self.historyMatches(pattern, addressPrefix: query.addressPrefix, limit: limit, in: db)
        }
    }

    /// History and favorite matches for the address bar, read in one consistent snapshot. Feed the
    /// result to `AddressBarSuggestions.merge` with the engine's suggestions; it deduplicates and
    /// trims to the final page count.
    public func addressBarCandidates(
        for text: String, historyLimit: Int = FixedChoices.maxPageSuggestions
    ) async throws -> (history: [PageCandidate], favorites: [PageCandidate]) {
        let query = HistoryQuery(text)
        return try await writer.read { db in
            let history = try query.pattern.map {
                try Self.historyMatches($0, addressPrefix: query.addressPrefix, limit: historyLimit, in: db)
            } ?? []
            let favorites = try Self.favoriteMatches(query.text, in: db)
            return (history, favorites)
        }
    }

    /// First fetch window, as a multiple of the pages wanted: twice almost always holds enough
    /// distinct pages after variants are merged.
    static let initialFetchFactor = 2
    /// How much the window grows when variants of one page fill it, so the rare retry converges
    /// in a step or two.
    static let fetchGrowthFactor = 4

    /// Up to `limit` distinct pages, best first. Variants of one page (http and https, with and
    /// without www., trailing slash, fragments) count once, using the same key as
    /// `AddressBarSuggestions`, so they can't crowd other pages out.
    static func historyMatches(
        _ pattern: String, addressPrefix: String?, limit: Int, in db: Database
    ) throws -> [PageCandidate] {
        guard limit > 0 else { return [] }
        // The FTS match yields the rows, then SQLite keeps only the best `fetch` in one pass
        // (a top-N sort, never a full one). `LIKE NULL` is NULL for every row when there is no
        // address prefix, so the order falls back to frecency alone.
        let like = addressPrefix.map { HistoryQuery.escapeLike($0) + "%" }
        let statement = try db.cachedStatement(sql: """
            SELECT p.url, p.title, p.frecency
            FROM \(Schema.historySearch) s
            JOIN \(Schema.historyPlace) p ON p.id = s.rowid
            WHERE \(Schema.historySearch) MATCH ?
            ORDER BY (p.address LIKE ? ESCAPE '\\') DESC, p.frecency DESC
            LIMIT ?
            """)
        // When variants eat into the window, fetch again with a bigger one; the cost grows only
        // for that rare case.
        var fetch = initialFetchFactor * limit
        while true {
            let rows = try Row.fetchAll(statement, arguments: [pattern, like, fetch])
            var seen = Set<String>()
            var pages: [PageCandidate] = []
            for row in rows {
                guard let url = URL(string: row["url"]),
                      seen.insert(AddressBarSuggestions.addressKey(url)).inserted
                else { continue }
                pages.append(PageCandidate(url: url, title: row["title"], frecency: row["frecency"], isFavorite: false))
                if pages.count == limit { return pages }
            }
            if rows.count < fetch { return pages }
            fetch *= fetchGrowthFactor
        }
    }
}

/// Typed address-bar text, shaped like the index: the scheme and `www.` people type are dropped,
/// because indexed addresses don't hold them ("https://www.swift.org/doc" searches "swift.org/doc").
struct HistoryQuery {
    let text: String
    /// The FTS5 MATCH expression, or nil when the text has nothing to search for.
    let pattern: String?
    /// The text as the start of an address, or nil when it can't be one (it has spaces).
    let addressPrefix: String?

    init(_ typed: String) {
        // Control characters (NUL ends an FTS5 string early) become spaces.
        var text = String(String.UnicodeScalarView(typed.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] {
            if let range = text.range(of: scheme, options: [.anchored, .caseInsensitive]) {
                text.removeSubrange(range)
                break
            }
        }
        if let range = text.range(of: "www.", options: [.anchored, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        self.text = text
        addressPrefix = text.isEmpty || text.contains(where: \.isWhitespace) ? nil : text
        // Each typed word becomes a quoted prefix phrase, `"github.com/ap"*`, which FTS5 always
        // parses (no syntax errors from user text) and which matches the word's tokens in order.
        // Built by hand because GRDB's FTS5Pattern opens a scratch database per call to validate.
        let words = text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        if words.isEmpty {
            pattern = nil
        } else if text.count < FixedChoices.minTitleSearchLength {
            // Too short to mean a word in a title: match only addresses that start with it. This
            // also keeps the first keystroke, the query with the most matches, cheap.
            pattern = "address : ^ " + words[0]
        } else {
            pattern = words.joined(separator: " ")
        }
    }

    /// Escapes `LIKE` wildcards for use with `ESCAPE '\'`.
    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
