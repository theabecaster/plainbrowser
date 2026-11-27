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
    /// How the user reached the page; typed visits weigh more in frecency.
    public var kind: VisitKind

    public init(url: URL, title: String?, visitedAt: Date, kind: VisitKind = .link) {
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.kind = kind
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A change to history, applied in order as part of a batch (see `HistoryRecorder`).
public enum HistoryChange: Hashable, Sendable {
    /// The user saw `url`.
    case visit(HistoryVisit)
    /// The page at `url` reported its title, usually after the visit was recorded. With
    /// `visitedAt`, it names that visit only, and nothing when that visit is gone (cleared), so
    /// a title can never land on an older visit. Without it, it names the newest visit.
    case title(String, url: URL, visitedAt: Date? = nil)
    /// The user typed `input` in the address bar and picked the suggestion for `url`.
    case pick(input: String, url: URL, at: Date)

    var url: URL {
        switch self {
        case .visit(let visit): visit.url
        case .title(_, let url, _): url
        case .pick(_, let url, _): url
        }
    }

    /// Stored dates keep milliseconds; a visit's own date matches within this.
    static let visitDateTolerance: TimeInterval = 0.002
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

    /// Adds one visit to the place for `url`, creating it on first visit. `weight` is the
    /// visit's `VisitKind.weight`.
    static func recordVisit(url: URL, title: String?, at date: Date, weight: Double = 1, in db: Database) throws {
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        if var place = try HistoryPlace.filter(Column("url") == url).fetchOne(db) {
            place.visitCount += 1
            place.lastVisitedAt = max(place.lastVisitedAt, date)
            place.frecency = Frecency.adding(visitAt: date, weight: weight, to: place.frecency)
            if let title { place.title = title }
            try place.update(db)
        } else {
            var place = HistoryPlace(
                url: url, address: searchableAddress(url), title: title, visitCount: 1,
                lastVisitedAt: date, frecency: Frecency.adding(visitAt: date, weight: weight, to: nil)
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
                    try HistoryPlace.recordVisit(
                        url: visit.url, title: visit.title, at: visit.visitedAt, weight: visit.kind.weight, in: db)
                case .pick(let input, let url, let date):
                    try InputHistory.recordPick(input: input, url: url, at: date, in: db)
                case .title(let title, let url, let visitedAt):
                    guard !title.isEmpty else { continue }
                    // Name the visit, so the History screen shows the title.
                    if let visitedAt {
                        let tolerance = HistoryChange.visitDateTolerance
                        try db.execute(
                            sql: """
                            UPDATE \(Schema.historyVisit) SET title = ?
                            WHERE url = ? AND visitedAt BETWEEN ? AND ?
                            """,
                            arguments: [
                                title, url,
                                visitedAt.addingTimeInterval(-tolerance), visitedAt.addingTimeInterval(tolerance),
                            ]
                        )
                        // That visit was cleared: the title must not reach the page's other visits.
                        guard db.changesCount > 0 else { continue }
                    } else {
                        try db.execute(
                            sql: """
                            UPDATE \(Schema.historyVisit) SET title = ?
                            WHERE id = (SELECT id FROM \(Schema.historyVisit) WHERE url = ? ORDER BY visitedAt DESC LIMIT 1)
                            """,
                            arguments: [title, url]
                        )
                    }
                    try HistoryPlace.filter(Column("url") == url).updateAll(db, Column("title").set(to: title))
                }
            }
        }
    }

    /// Removes every visit to `url`, written at once (see `HistoryRecorder.deleteHistory`).
    static func deleteHistory(for url: URL, in writer: any DatabaseWriter) async throws {
        try await writer.write { db in
            _ = try HistoryVisit.filter(Column("url") == url).deleteAll(db)
            _ = try HistoryPlace.filter(Column("url") == url).deleteAll(db)
            try InputHistory.delete(url: url.absoluteString, in: db)
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
                try db.execute(sql: "DELETE FROM \(Schema.inputHistory)")
                return
            }
            // Picks made in the cleared time go with it.
            try db.execute(sql: "DELETE FROM \(Schema.inputHistory) WHERE lastUsedAt >= ?", arguments: [start])
            let urls = try String.fetchAll(
                db, sql: "SELECT DISTINCT url FROM \(Schema.historyVisit) WHERE visitedAt >= ?", arguments: [start]
            )
            _ = try HistoryVisit.filter(Column("visitedAt") >= start).deleteAll(db)
            for url in urls {
                let left = try Row.fetchAll(
                    db, sql: "SELECT visitedAt, kind FROM \(Schema.historyVisit) WHERE url = ? ORDER BY visitedAt", arguments: [url]
                ).map { row -> (date: Date, kind: VisitKind) in
                    (row["visitedAt"], VisitKind(rawValue: row["kind"]) ?? .link)
                }
                guard let last = left.last?.date else {
                    try db.execute(sql: "DELETE FROM \(Schema.historyPlace) WHERE url = ?", arguments: [url])
                    try InputHistory.delete(url: url, in: db)
                    continue
                }
                let frecency = left.reduce(nil as Double?) {
                    Frecency.adding(visitAt: $1.date, weight: $1.kind.weight, to: $0)
                } ?? 0
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
    ///
    /// Clearing everything also compacts the database file soon after, off the main thread, so
    /// the deleted rows do not linger on disk (see `Maintenance.swift`).
    public func clearHistory(since start: Date?) async throws {
        try await historyRecorder.clearHistory(since: start)
        if start == nil { await maintenance.scheduleCompaction() }
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

    /// History, favorite and reading list matches for the address bar, read in one consistent
    /// snapshot. Feed the result to `AddressBarSuggestions.merge` with the engine's suggestions; it
    /// deduplicates and trims to the final page count.
    public func addressBarCandidates(
        for text: String, historyLimit: Int = FixedChoices.maxPageSuggestions
    ) async throws -> (history: [PageCandidate], favorites: [PageCandidate], saved: [PageCandidate]) {
        let query = HistoryQuery(text)
        return try await writer.read { db in
            var history = try query.pattern.map {
                try Self.historyMatches($0, addressPrefix: query.addressPrefix, limit: historyLimit, in: db)
            } ?? []
            // The site itself, so `AddressBarSuggestions` can make it the top hit even when deep
            // pages on it rank higher.
            var keys = history.map { AddressBarSuggestions.addressKey($0.url) }
            if let site = try Self.siteMatch(query, in: db) {
                let key = AddressBarSuggestions.addressKey(site.url)
                if !keys.contains(key) {
                    history.append(site)
                    keys.append(key)
                }
            }
            // Pages picked before for input like this one, marked on the row already there.
            for picked in try InputHistory.matches(for: query.inputKey, in: db) {
                if let index = keys.firstIndex(of: AddressBarSuggestions.addressKey(picked.url)) {
                    history[index].adaptiveUse = max(history[index].adaptiveUse ?? 0, picked.adaptiveUse ?? 0)
                } else {
                    history.append(picked)
                    keys.append(AddressBarSuggestions.addressKey(picked.url))
                }
            }
            let favorites = try Self.favoriteMatches(query.text, in: db)
            let saved = try Self.readingListMatches(query, limit: historyLimit, in: db)
            return (history, favorites, saved)
        }
    }

    /// The best root page (`github.com`, no path) whose address starts with the typed text, while
    /// the text can still be a host. Nil once it has a path or a space, or when no such page is in
    /// history. A range scan on the partial index of root pages (`historyPlace_sites`), so it costs
    /// the same at 100k pages as at 100.
    static func siteMatch(_ query: HistoryQuery, in db: Database) throws -> PageCandidate? {
        guard let prefix = query.addressPrefix?.lowercased(), !prefix.contains("/"), !prefix.contains("?") else {
            return nil
        }
        // The `instr` terms repeat the index's WHERE clause, so SQLite can use it.
        let statement = try db.cachedStatement(sql: """
            SELECT url, title, frecency FROM \(Schema.historyPlace) INDEXED BY historyPlace_sites
            WHERE address >= ? AND address < ?
              AND instr(address, '/') = 0 AND instr(address, '?') = 0
            ORDER BY frecency DESC
            LIMIT 1
            """)
        guard let row = try Row.fetchOne(statement, arguments: [prefix, prefix + "\u{10FFFF}"]),
              let url = URL(string: row["url"])
        else { return nil }
        return PageCandidate(url: url, title: row["title"], frecency: row["frecency"], isFavorite: false)
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
    /// The text as adaptive history stores it: lowercased, without scheme or `www.`.
    let inputKey: String

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
        inputKey = text.lowercased()
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

/// Stored as its raw value in `historyVisit.kind`.
extension VisitKind: DatabaseValueConvertible {}
