import Foundation
import GRDB

/// Choices remembered per site, never configured (AGENTS.md, "Opinionated and simple"): the
/// answer to each permission prompt, the desktop or mobile choice from the page menu, and the
/// sites where content blocking or dark pages are off.
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

    // MARK: Dark pages off per site

    /// The sites where the user turned dark pages off. Read once at launch: the engine builds each
    /// page's dark-pages script from this list, so the shell answers from memory.
    public func darkPagesOffSites() async throws -> Set<String> {
        try await writer.read { db in
            try Set(String.fetchAll(db, sql: "SELECT site FROM \(Schema.darkPagesOff)"))
        }
    }

    /// Turns dark pages off for `site` (true) or back to automatic (false).
    public func setDarkPagesOff(_ off: Bool, forSite site: String) async throws {
        try await writer.write { db in
            if off {
                try db.execute(
                    sql: "INSERT INTO \(Schema.darkPagesOff) (site) VALUES (?) ON CONFLICT(site) DO NOTHING",
                    arguments: [site]
                )
            } else {
                try db.execute(sql: "DELETE FROM \(Schema.darkPagesOff) WHERE site = ?", arguments: [site])
            }
        }
    }
}
