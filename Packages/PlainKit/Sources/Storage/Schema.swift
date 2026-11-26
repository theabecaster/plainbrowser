import Foundation
import GRDB

/// Table names and migrations. Migrations are append-only: never edit one that has shipped,
/// add a new one instead.
enum Schema {
    static let historyVisit = "historyVisit"
    static let historyPlace = "historyPlace"
    static let historySearch = "historySearch"
    static let favorite = "favorite"
    static let tab = "tab"
    static let favicon = "favicon"
    static let setting = "setting"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1.history") { db in
            try db.create(table: historyVisit) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull()
                t.column("title", .text)
                t.column("visitedAt", .datetime).notNull().indexed()
            }
        }

        // One row per address with its visit count and frecency, plus the full-text index the
        // address bar searches. Visits stay in `historyVisit` for the History screen.
        migrator.registerMigration("v2.historyPlaces") { db in
            try db.create(index: "historyVisit_on_url", on: historyVisit, columns: ["url"])
            try db.create(table: historyPlace) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                // The URL without scheme and `www.`: what people type, and what the index holds.
                t.column("address", .text).notNull()
                t.column("title", .text)
                t.column("visitCount", .integer).notNull()
                t.column("lastVisitedAt", .datetime).notNull()
                t.column("frecency", .double).notNull().indexed()
            }
            try db.create(virtualTable: historySearch, using: FTS5()) { t in
                t.synchronize(withTable: historyPlace)
                // Diacritics removed so "cafe" finds "Café".
                t.tokenizer = .unicode61(diacritics: .remove)
                // Prefix indexes make the one- and two-letter queries of the first keystrokes fast.
                t.prefixes = [1, 2]
                t.column("title")
                t.column("address")
            }

            // Carry over visits recorded before this migration.
            let rows = try Row.fetchAll(db, sql: "SELECT url, title, visitedAt FROM \(historyVisit) ORDER BY visitedAt")
            for row in rows {
                guard let url = URL(string: row["url"]) else { continue }
                try HistoryPlace.recordVisit(url: url, title: row["title"], at: row["visitedAt"], in: db)
            }
        }

        migrator.registerMigration("v2.favorites") { db in
            try db.create(table: favorite) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("title", .text)
                t.column("position", .integer).notNull().indexed()
            }
        }

        migrator.registerMigration("v2.tabs") { db in
            try db.create(table: tab) { t in
                t.primaryKey("id", .text)
                t.column("url", .text)
                t.column("title", .text)
                t.column("position", .integer).notNull()
                t.column("lastActiveAt", .datetime).notNull()
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("archivedAt", .datetime)
            }
            try db.create(index: "tab_on_isArchived_position", on: tab, columns: ["isArchived", "position"])
        }

        migrator.registerMigration("v2.favicons") { db in
            try db.create(table: favicon) { t in
                t.primaryKey("host", .text)
                t.column("data", .blob).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }
        }

        migrator.registerMigration("v2.settings") { db in
            try db.create(table: setting) { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
    }
}
