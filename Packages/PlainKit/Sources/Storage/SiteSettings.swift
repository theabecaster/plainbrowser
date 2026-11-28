import BrowserCore
import Foundation
import GRDB

/// Choices remembered per site, never configured (AGENTS.md, "Opinionated and simple"): the
/// answer to each permission prompt, the desktop or mobile choice from the page menu, and the
/// sites where content blocking is off, and each site's Dark Pages choice.
///
/// Values are plain strings: the engine's types (`SitePermission`, `ContentMode`) live above
/// Storage, and adapters in the shell map them. A site is whatever key the caller uses (an origin
/// for permissions, a host without `www.` for the others).
extension AppDatabase {
    // MARK: Permissions

    /// The remembered answer for `permission` on `site`, or nil when the user was never asked.
    public func sitePermission(_ permission: String, forSite site: String) async throws -> Bool? {
        try await writer.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT allowed FROM \(Schema.sitePermission) WHERE site = ? AND permission = ?",
                arguments: [site, permission]
            )
        }
    }

    /// Every remembered answer for `site`, permission to answer (Site Settings' rows).
    public func sitePermissions(forSite site: String) async throws -> [String: Bool] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT permission, allowed FROM \(Schema.sitePermission) WHERE site = ?", arguments: [site]
            )
            var answers: [String: Bool] = [:]
            for row in rows {
                let permission: String = row["permission"]
                let allowed: Bool = row["allowed"]
                answers[permission] = allowed
            }
            return answers
        }
    }

    public func setSitePermission(_ allowed: Bool, _ permission: String, forSite site: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO \(Schema.sitePermission) (site, permission, allowed) VALUES (?, ?, ?)
                ON CONFLICT(site, permission) DO UPDATE SET allowed = excluded.allowed
                """,
                arguments: [site, permission, allowed]
            )
        }
    }

    // MARK: Desktop or mobile site

    /// Every remembered choice, site to mode. Read once at launch: the engine asks on every
    /// navigation start, so the shell answers from memory.
    public func siteContentModes() async throws -> [String: String] {
        try await writer.read { db in
            var modes: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT site, mode FROM \(Schema.siteContentMode)") {
                modes[row["site"]] = row["mode"]
            }
            return modes
        }
    }

    /// Remembers `mode` for `site`; nil forgets it (the site follows the automatic choice again).
    public func setSiteContentMode(_ mode: String?, forSite site: String) async throws {
        try await writer.write { db in
            if let mode {
                try db.execute(
                    sql: """
                    INSERT INTO \(Schema.siteContentMode) (site, mode) VALUES (?, ?)
                    ON CONFLICT(site) DO UPDATE SET mode = excluded.mode
                    """,
                    arguments: [site, mode]
                )
            } else {
                try db.execute(sql: "DELETE FROM \(Schema.siteContentMode) WHERE site = ?", arguments: [site])
            }
        }
    }

    // MARK: Page zoom

    /// Every remembered page zoom, site to zoom (1 is 100%). Read once at launch: the engine applies
    /// it at every page commit, so the shell answers from memory.
    public func sitePageZooms() async throws -> [String: Double] {
        try await writer.read { db in
            var zooms: [String: Double] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT site, zoom FROM \(Schema.sitePageZoom)") {
                zooms[row["site"]] = row["zoom"]
            }
            return zooms
        }
    }

    /// Remembers `zoom` for `site`; nil forgets it (the site is back at 100%).
    public func setSitePageZoom(_ zoom: Double?, forSite site: String) async throws {
        try await writer.write { db in
            if let zoom {
                try db.execute(
                    sql: """
                    INSERT INTO \(Schema.sitePageZoom) (site, zoom) VALUES (?, ?)
                    ON CONFLICT(site) DO UPDATE SET zoom = excluded.zoom
                    """,
                    arguments: [site, zoom]
                )
            } else {
                try db.execute(sql: "DELETE FROM \(Schema.sitePageZoom) WHERE site = ?", arguments: [site])
            }
        }
    }

    // MARK: Blocking off per site

    public func blockingAllowList() async throws -> Set<String> {
        try await writer.read { db in
            try Set(String.fetchAll(db, sql: "SELECT site FROM \(Schema.blockingAllowList)"))
        }
    }

    /// Replaces the whole list in one transaction. The list is small (sites the user turned
    /// blocking off on), and the content blocker saves it whole after each change.
    public func saveBlockingAllowList(_ sites: Set<String>) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM \(Schema.blockingAllowList)")
            let insert = try db.cachedStatement(sql: "INSERT INTO \(Schema.blockingAllowList) (site) VALUES (?)")
            for site in sites {
                try insert.execute(arguments: [site])
            }
        }
    }

    // MARK: Dark pages per site

    /// The sites with a Dark Pages choice of their own: on, and off. Read once at launch: the
    /// engine builds each page's dark-pages script from them, so the shell answers from memory.
    public func darkPagesSiteChoices() async throws -> (on: Set<String>, off: Set<String>) {
        try await writer.read { db in
            let off = try Set(String.fetchAll(db, sql: "SELECT site FROM \(Schema.darkPagesOff)"))
            let on = try Set(String.fetchAll(db, sql: "SELECT site FROM \(Schema.darkPagesOn)")).subtracting(off)
            return (on, off)
        }
    }

    /// Sets `site`'s choice: on, off, or back to automatic (in neither table), in one transaction.
    public func setDarkPagesChoice(_ choice: DarkPagesSiteChoice, forSite site: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM \(Schema.darkPagesOff) WHERE site = ?", arguments: [site])
            try db.execute(sql: "DELETE FROM \(Schema.darkPagesOn) WHERE site = ?", arguments: [site])
            switch choice {
            case .automatic: break
            case .on: try db.execute(sql: "INSERT INTO \(Schema.darkPagesOn) (site) VALUES (?)", arguments: [site])
            case .off: try db.execute(sql: "INSERT INTO \(Schema.darkPagesOff) (site) VALUES (?)", arguments: [site])
            }
        }
    }

    // MARK: Cookie banners off per site

    /// The sites where the user turned cookie banner handling off. Read once at launch: every
    /// page's first message is answered from memory.
    public func cookieBannersOffSites() async throws -> Set<String> {
        try await writer.read { db in
            try Set(String.fetchAll(db, sql: "SELECT site FROM \(Schema.cookieBannersOff)"))
        }
    }

    /// Turns cookie banner handling off for `site` (true) or back on (false).
    public func setCookieBannersOff(_ off: Bool, forSite site: String) async throws {
        try await writer.write { db in
            if off {
                try db.execute(
                    sql: "INSERT INTO \(Schema.cookieBannersOff) (site) VALUES (?) ON CONFLICT(site) DO NOTHING",
                    arguments: [site]
                )
            } else {
                try db.execute(sql: "DELETE FROM \(Schema.cookieBannersOff) WHERE site = ?", arguments: [site])
            }
        }
    }
}
