import BrowserCore
import Foundation
import GRDB

/// Persists `BrowserSettings`: search engine, tab layout, archive interval, appearance and Dark Pages. Nothing else is a
/// setting (docs/plan.md, section 4b), so there is no generic key-value API.
///
/// Built-in engines are stored by id, so a template fix in the catalog reaches existing users. A
/// custom engine is stored in full and kept even after switching away from it, so the picker can
/// offer it again. Unknown or damaged values fall back to the defaults.
extension AppDatabase {
    enum SettingKey: String {
        case searchEngine
        case customSearchEngine
        case tabLayout
        case archiveAfter
        case appearance
        case darkPages
    }

    private struct StoredCustomEngine: Codable {
        var name: String
        var template: String
    }

    public func settings() async throws -> BrowserSettings {
        try await writer.read { db in try Self.readSettings(db) }
    }

    /// Changes stored settings in one write transaction: what another window saved a moment ago
    /// is read and kept, and only `change` is applied over it. Returns what is stored now.
    public func updateSettings(_ change: @escaping @Sendable (inout BrowserSettings) -> Void) async throws -> BrowserSettings {
        try await writer.write { db in
            var settings = try Self.readSettings(db)
            change(&settings)
            try Self.writeSettings(settings, db)
            return settings
        }
    }

    private static func readSettings(_ db: Database) throws -> BrowserSettings {
        do {
            let values = try Dictionary(
                uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT key, value FROM \(Schema.setting)")
                    .map { (row: Row) -> (String, String) in (row["key"], row["value"]) }
            )
            var settings = BrowserSettings.defaults
            switch values[SettingKey.searchEngine.rawValue] {
            case SearchEngine.customID?:
                if let custom = Self.decodeCustomEngine(values[SettingKey.customSearchEngine.rawValue]) {
                    settings.searchEngine = custom
                }
            case let id?:
                if let engine = SearchEngine.builtIn(id: id) { settings.searchEngine = engine }
            case nil:
                break
            }
            if let raw = values[SettingKey.tabLayout.rawValue], let layout = TabLayout(stored: raw) {
                settings.tabLayout = layout
            }
            if let raw = values[SettingKey.archiveAfter.rawValue], let archive = ArchiveAfter(rawValue: raw) {
                settings.archiveAfter = archive
            }
            if let raw = values[SettingKey.appearance.rawValue], let appearance = Appearance(rawValue: raw) {
                settings.appearance = appearance
            }
            // Absent until the first save after this setting existed: the default (off), for
            // upgraders too (docs/research/dark-pages-optin.md, Migration).
            if let raw = values[SettingKey.darkPages.rawValue] {
                settings.darkPages = raw == "1"
            }
            return settings
        }
    }

    /// The custom engine the user defined, even when another engine is selected.
    public func savedCustomSearchEngine() async throws -> SearchEngine? {
        try await writer.read { db in
            let raw = try String.fetchOne(
                db, sql: "SELECT value FROM \(Schema.setting) WHERE key = ?",
                arguments: [SettingKey.customSearchEngine.rawValue]
            )
            return Self.decodeCustomEngine(raw)
        }
    }

    public func saveSettings(_ settings: BrowserSettings) async throws {
        try await writer.write { db in try Self.writeSettings(settings, db) }
    }

    private static func writeSettings(_ settings: BrowserSettings, _ db: Database) throws {
        var pairs: [(SettingKey, String)] = [
            (.searchEngine, settings.searchEngine.id),
            (.tabLayout, settings.tabLayout.rawValue),
            (.archiveAfter, settings.archiveAfter.rawValue),
            (.appearance, settings.appearance.rawValue),
            (.darkPages, settings.darkPages ? "1" : "0"),
        ]
        if settings.searchEngine.isCustom {
            let stored = StoredCustomEngine(name: settings.searchEngine.name, template: settings.searchEngine.template)
            let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
            pairs.append((.customSearchEngine, json))
        }
        let values = pairs.map { ($0.0.rawValue, $0.1) }
        let statement = try db.cachedStatement(
            sql: "INSERT INTO \(Schema.setting) (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        )
        for (key, value) in values {
            try statement.execute(arguments: [key, value])
        }
    }

    /// Decodes and re-validates a stored custom engine; nil when missing or no longer valid.
    private static func decodeCustomEngine(_ raw: String?) -> SearchEngine? {
        guard let raw, let stored = try? JSONDecoder().decode(StoredCustomEngine.self, from: Data(raw.utf8)) else {
            return nil
        }
        return try? SearchEngine.custom(name: stored.name, template: stored.template)
    }
}
