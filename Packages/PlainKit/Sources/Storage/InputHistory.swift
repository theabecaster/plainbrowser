import BrowserCore
import Foundation
import GRDB

/// Adaptive history, like Firefox's `moz_inputhistory`: which page the user picked from the
/// address bar after typing what. Next time, typing text that starts the same way makes that page
/// the top hit (`PageCandidate.adaptiveUse`).
///
/// Each pick sets `useCount = useCount * FixedChoices.inputHistoryPickRetention + 1` (Firefox's
/// update). Daily maintenance decays every count
/// by `FixedChoices.inputHistoryDailyDecay` and forgets those under
/// `FixedChoices.inputHistoryMinimumUse`. Writes go through `HistoryRecorder` (`.pick`), so they
/// are ordered with history deletes.
enum InputHistory {
    static func recordPick(input: String, url: URL, at date: Date, in db: Database) throws {
        let key = HistoryQuery(input).inputKey
        guard !key.isEmpty else { return }
        try db.execute(
            sql: """
            INSERT INTO \(Schema.inputHistory) (input, url, useCount, lastUsedAt) VALUES (?, ?, 1, ?)
            ON CONFLICT(input, url) DO UPDATE SET
                useCount = useCount * \(FixedChoices.inputHistoryPickRetention) + 1,
                lastUsedAt = max(lastUsedAt, excluded.lastUsedAt)
            """,
            arguments: [key, url.absoluteString, date]
        )
    }

    static func delete(url: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM \(Schema.inputHistory) WHERE url = ?", arguments: [url])
    }

    /// Pages picked after input that starts with `inputKey`, strongest first. A range scan on the
    /// primary key, so it costs microseconds.
    static func matches(for inputKey: String, in db: Database) throws -> [PageCandidate] {
        guard !inputKey.isEmpty else { return [] }
        let statement = try db.cachedStatement(sql: """
            SELECT i.url, max(i.useCount) AS use, p.title, p.frecency
            FROM \(Schema.inputHistory) i
            LEFT JOIN \(Schema.historyPlace) p ON p.url = i.url
            WHERE i.input >= ? AND i.input < ?
            GROUP BY i.url
            ORDER BY use DESC
            LIMIT ?
            """)
        // Every string that starts with `inputKey` sorts below it plus the highest code point.
        let rows = try Row.fetchAll(statement, arguments: [inputKey, inputKey + "\u{10FFFF}", FixedChoices.inputHistoryMatches])
        return rows.compactMap { row in
            guard let url = URL(string: row["url"]) else { return nil }
            return PageCandidate(
                url: url, title: row["title"], frecency: row["frecency"], isFavorite: false, adaptiveUse: row["use"])
        }
    }

    /// Ages every pick by `days` days of decay and forgets the faint ones.
    static func decay(days: Double, in db: Database) throws {
        guard days > 0 else { return }
        let factor = pow(FixedChoices.inputHistoryDailyDecay, days)
        try db.execute(sql: "UPDATE \(Schema.inputHistory) SET useCount = useCount * ?", arguments: [factor])
        try db.execute(
            sql: "DELETE FROM \(Schema.inputHistory) WHERE useCount < ?",
            arguments: [FixedChoices.inputHistoryMinimumUse])
    }
}

extension AppDatabase {
    /// Remembers that the user typed `input` in the address bar and picked the page suggestion
    /// for `url`. Call it when a page row is tapped (not for searches). Goes through
    /// `historyRecorder`, so a history clear removes it with the visits.
    public func recordPickedSuggestion(input: String, url: URL, at date: Date = Date()) async {
        await historyRecorder.recordPick(input: input, url: url, at: date)
    }
}
