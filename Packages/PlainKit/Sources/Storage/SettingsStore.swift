import BrowserCore
import Foundation
import GRDB

/// Persists `BrowserSettings`: search engine, tab layout and archive interval. Nothing else is a
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
    }

    private struct StoredCustomEngine: Codable {
        var name: String
        var template: String
    }

    public func settings() async throws -> BrowserSettings {
        try await writer.read { db in
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
            if let raw = values[SettingKey.tabLayout.rawValue], let layout = TabLayout(rawValue: raw) {
                settings.tabLayout = layout
            }
            if let raw = values[SettingKey.archiveAfter.rawValue], let archive = ArchiveAfter(rawValue: raw) {
                settings.archiveAfter = archive
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
        var pairs: [(SettingKey, String)] = [
            (.searchEngine, settings.searchEngine.id),
            (.tabLayout, settings.tabLayout.rawValue),
            (.archiveAfter, settings.archiveAfter.rawValue),
        ]
        if settings.searchEngine.isCustom {
            let stored = StoredCustomEngine(name: settings.searchEngine.name, template: settings.searchEngine.template)
            let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
            pairs.append((.customSearchEngine, json))
        }
        let values = pairs.map { ($0.0.rawValue, $0.1) }
        try await writer.write { db in
            let statement = try db.cachedStatement(
                sql: "INSERT INTO \(Schema.setting) (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
            )
            for (key, value) in values {
                try statement.execute(arguments: [key, value])
            }
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
