import Foundation
import GRDB

/// A cached site icon, keyed by host.
public struct Favicon: Hashable, Sendable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = Schema.favicon

    /// Lowercased host, for example `www.apple.com`.
    public var host: String
    /// Encoded image bytes as fetched. Decoding happens off-main in the UI layer.
    public var data: Data
    public var updatedAt: Date

    public init(host: String, data: Data, updatedAt: Date) {
        self.host = host.lowercased()
        self.data = data
        self.updatedAt = updatedAt
    }
}

extension AppDatabase {
    public func favicon(forHost host: String) async throws -> Favicon? {
        let key = host.lowercased()
        return try await writer.read { db in
            try Favicon.fetchOne(db, key: key)
        }
    }

    public func saveFavicon(_ favicon: Favicon) async throws {
        try await writer.write { db in
            try favicon.upsert(db)
        }
    }

    /// Drops icons not refreshed since `date`.
    public func removeFavicons(updatedBefore date: Date) async throws {
        try await writer.write { db in
            _ = try Favicon.filter(Column("updatedAt") < date).deleteAll(db)
        }
    }

    /// Removes every icon, then compacts the database soon after (once, together with a history
    /// clear made at the same time).
    public func clearFavicons() async throws {
        try await writer.write { db in
            _ = try Favicon.deleteAll(db)
        }
        await maintenance.scheduleCompaction()
    }
}
