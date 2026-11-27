import BrowserCore
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
    static let inputHistory = "inputHistory"
    static let tabWindow = "tabWindow"
    static let closedTab = "closedTab"
    static let tabSearch = "tabSearch"
    static let sitePermission = "sitePermission"
    static let siteContentMode = "siteContentMode"
    static let blockingAllowList = "blockingAllowList"
    static let sitePageZoom = "sitePageZoom"
    static let darkPagesOff = "darkPagesOff"

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

        // How each visit was reached (`VisitKind`): typed visits weigh more in frecency. Visits
        // recorded before this were not told apart and stay links, so stored frecency is unchanged.
        migrator.registerMigration("v3.visitKind") { db in
            try db.alter(table: historyVisit) { t in
                t.add(column: "kind", .integer).notNull().defaults(to: VisitKind.link.rawValue)
            }
        }

        // Adaptive history, like Firefox's `moz_inputhistory`: the page picked from the address
        // bar for a typed input, with a use count that grows with each pick and decays daily.
        migrator.registerMigration("v3.inputHistory") { db in
            try db.create(table: inputHistory) { t in
                // Normalized as `HistoryQuery` shapes typed text: lowercased, no scheme or `www.`.
                t.column("input", .text).notNull()
                t.column("url", .text).notNull().indexed()
                t.column("useCount", .double).notNull()
                t.column("lastUsedAt", .datetime).notNull()
                t.primaryKey(["input", "url"])
            }
        }

        // Root pages (`github.com`, no path or query) by address, for the address bar's
        // site-level top hit. Partial, so it holds only the few root pages, not every page.
        migrator.registerMigration("v3.siteIndex") { db in
            try db.execute(sql: """
                CREATE INDEX historyPlace_sites ON \(historyPlace)(address)
                WHERE instr(address, '/') = 0 AND instr(address, '?') = 0
                """)
        }

        // The tab model (`TabStore`): windows with their pane selection, each tab's window,
        // opener, pin and thumbnail, the recently closed stack, and full-text search over the
        // archive.
        migrator.registerMigration("v4.tabSession") { db in
            try db.alter(table: tab) { t in
                t.add(column: "windowID", .text)
                t.add(column: "openerID", .text)
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
                t.add(column: "createdAt", .datetime)
                t.add(column: "thumbnailFile", .text)
                t.add(column: "thumbnailRevision", .integer)
            }
            try db.create(index: "tab_on_isArchived_archivedAt", on: tab, columns: ["isArchived", "archivedAt"])
            try db.create(table: tabWindow) { t in
                t.primaryKey("id", .text)
                t.column("position", .integer).notNull()
                // The tab id each pane shows, comma separated; an empty item is the start page.
                t.column("panes", .text).notNull()
                t.column("focusedPane", .integer).notNull()
            }
            try db.create(table: closedTab) { t in
                t.autoIncrementedPrimaryKey("rowID")
                // Batches are only appended and removed whole, so `rowID` order is stack order.
                t.column("batchID", .text).notNull().indexed()
                // The tab's position in its batch.
                t.column("tabPosition", .integer).notNull()
                t.column("closedAt", .datetime).notNull()
                t.column("id", .text).notNull()
                t.column("windowID", .text).notNull()
                t.column("windowIndex", .integer).notNull()
                t.column("previousTabID", .text)
                // The pane it was shown in, if any, and whether that pane had focus.
                t.column("pane", .integer)
                t.column("wasFocused", .boolean).notNull()
                t.column("url", .text)
                t.column("title", .text)
                t.column("openerID", .text)
                t.column("isPinned", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastActiveAt", .datetime).notNull()
                t.column("thumbnailFile", .text)
                t.column("thumbnailRevision", .integer)
            }
            try db.create(virtualTable: tabSearch, using: FTS5()) { t in
                t.synchronize(withTable: tab)
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2]
                t.column("title")
                t.column("url")
            }
        }

        // Per-site choices remembered automatically (docs/plan.md, section 4b): permission
        // answers, desktop or mobile site, and the sites where blocking is off.
        migrator.registerMigration("v5.siteSettings") { db in
            try db.create(table: sitePermission) { t in
                t.column("site", .text).notNull()
                t.column("permission", .text).notNull()
                t.column("allowed", .boolean).notNull()
                t.primaryKey(["site", "permission"])
            }
            try db.create(table: siteContentMode) { t in
                t.primaryKey("site", .text)
                t.column("mode", .text).notNull()
            }
            try db.create(table: blockingAllowList) { t in
                t.primaryKey("site", .text)
            }
        }

        // Page zoom remembered per site (docs/plan.md, section 4b), set from the page menu.
        migrator.registerMigration("v6.sitePageZoom") { db in
            try db.create(table: sitePageZoom) { t in
                t.primaryKey("site", .text)
                t.column("zoom", .double).notNull()
            }
        }

        // The sites where the user turned off dark pages from the page menu.
        migrator.registerMigration("v7.darkPagesOff") { db in
            try db.create(table: darkPagesOff) { t in
                t.primaryKey("site", .text)
            }
        }
    }
}
