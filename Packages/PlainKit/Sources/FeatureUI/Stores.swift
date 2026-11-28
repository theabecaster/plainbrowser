import BrowserCore
import Foundation
import Storage

// What the FeatureUI screens need from the rest of the app. The models take these through their
// initializers; the app passes `AppDatabase` (conformances below) or a small adapter.
//
// Every requirement is async and nonisolated, so the database work runs on Storage's queues and
// never on the main thread.

/// Reads and saves the three stored settings.
public nonisolated protocol SettingsStoring: Sendable {
    func settings() async throws -> BrowserSettings
    func saveSettings(_ settings: BrowserSettings) async throws
    /// The custom engine the user defined, even when another engine is selected.
    func savedCustomSearchEngine() async throws -> SearchEngine?
    /// Applies `change` over what is stored now, atomically where the store can, and returns the
    /// result: another window may have saved a different setting meanwhile.
    func updateSettings(_ change: @escaping @Sendable (inout BrowserSettings) -> Void) async throws -> BrowserSettings
}

extension SettingsStoring {
    public func updateSettings(_ change: @escaping @Sendable (inout BrowserSettings) -> Void) async throws -> BrowserSettings {
        var settings = try await settings()
        change(&settings)
        try await saveSettings(settings)
        return settings
    }
}

/// Clears history, cookies, caches and website data. The app wires it to the history recorder,
/// the database and `WKWebsiteDataStore`, which FeatureUI can't import.
public nonisolated protocol BrowsingDataClearing: Sendable {
    func clearHistoryAndData() async throws
}

/// The favorites list in the user's order.
public nonisolated protocol FavoritesStoring: Sendable {
    func favorites() async throws -> [Favorite]
    func renameFavorite(id: Int64, title: String) async throws
    func removeFavorite(id: Int64) async throws
    func moveFavorite(id: Int64, to index: Int) async throws
}

/// How much history a "Clear" action removes.
public enum HistoryClearRange: Hashable, Sendable, CaseIterable {
    case lastHour
    case today
    case all

    /// The earliest visit the range removes, or nil for all history.
    public func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3600)
        case .today: calendar.startOfDay(for: now)
        case .all: nil
        }
    }
}

/// History visits for the History screen.
public nonisolated protocol HistoryStoring: Sendable {
    /// The newest visits first. An empty `query` means every visit; otherwise only visits whose
    /// title or address match it, using the history full-text index.
    func visits(matching query: String, limit: Int) async throws -> [HistoryVisit]
    /// Removes every visit to `url`. Goes through `HistoryRecorder`, the one owner of history writes.
    func deleteHistory(for url: URL) async throws
    /// Removes visits made since `start`, or all history when `start` is nil.
    func clearHistory(since start: Date?) async throws
}

extension AppDatabase: SettingsStoring {}
extension AppDatabase: FavoritesStoring {}
// In an extension, not on the declaration: the declaration form trips a compiler bug. History
// deletes go through `AppDatabase.historyRecorder`, the one writer of history.
extension AppDatabase: HistoryStoring {}
