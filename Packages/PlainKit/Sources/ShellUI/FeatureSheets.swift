import BrowserCore
import FeatureUI
import Foundation
import Storage
#if os(iOS)
import SwiftUI
import UIKit
import WebKit
#endif

/// The low-frequency screens the shell presents as sheets: Settings, History and the favorites
/// editor (FeatureUI, SwiftUI). It builds each screen's model over the database and wraps the
/// view in a hosting controller; the browser presents it.
///
/// Like `LiveAddressBarData`, it works before the database opens: until `attach`, it has no
/// screens to offer and the menu items that open them do nothing.
public final class FeatureSheets {
    private var database: AppDatabase?
    /// Called on the main actor after each saved settings change, so it takes effect at once.
    private let settingsSaved: @MainActor @Sendable (BrowserSettings) -> Void

    public init(settingsSaved: @escaping @MainActor @Sendable (BrowserSettings) -> Void) {
        self.settingsSaved = settingsSaved
    }

    public func attach(_ database: AppDatabase) {
        self.database = database
    }

    var isReady: Bool { database != nil }

    #if os(iOS)
    /// Settings, with a single Done button.
    func settings(onDone: @escaping () -> Void) -> UIViewController? {
        guard let database else { return nil }
        let store = LiveSettingsStore(database: database, saved: settingsSaved)
        let model = SettingsModel(store: store, clearer: LiveBrowsingDataClearer(database: database))
        return Self.sheet(SettingsView(model: model, onDone: onDone), identifier: "settingsSheet")
    }

    /// History. `onOpen` gets the page the user tapped.
    func history(onOpen: @escaping (URL) -> Void, onDone: @escaping () -> Void) -> UIViewController? {
        guard let database else { return nil }
        let model = HistoryModel(store: database)
        return Self.sheet(HistoryView(model: model, onOpen: onOpen, onDone: onDone), identifier: "historySheet")
    }

    /// The favorites editor.
    func favoritesEditor(onDone: @escaping () -> Void) -> UIViewController? {
        guard let database else { return nil }
        let model = FavoritesModel(store: database)
        return Self.sheet(FavoritesEditor(model: model, onDone: onDone), identifier: "favoritesSheet")
    }

    /// A page sheet that opens at full height: every screen is a list that wants the room.
    private static func sheet(_ view: some View, identifier: String) -> UIViewController {
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        host.view.accessibilityIdentifier = identifier
        host.sheetPresentationController?.prefersGrabberVisible = false
        return host
    }
    #endif
}

/// Settings storage that reports each successful save, so the browser applies it at once.
nonisolated struct LiveSettingsStore: SettingsStoring {
    let database: AppDatabase
    let saved: @MainActor @Sendable (BrowserSettings) -> Void

    func settings() async throws -> BrowserSettings {
        try await database.settings()
    }

    func saveSettings(_ settings: BrowserSettings) async throws {
        try await database.saveSettings(settings)
        await saved(settings)
    }

    func savedCustomSearchEngine() async throws -> SearchEngine? {
        try await database.savedCustomSearchEngine()
    }
}

#if os(iOS)
/// Settings > Clear History and Data: history (through the one history writer), cached site
/// icons, then every cookie, cache and storage entry in the website data store the web views
/// share. Open tabs and favorites stay.
nonisolated struct LiveBrowsingDataClearer: BrowsingDataClearing {
    let database: AppDatabase

    func clearHistoryAndData() async throws {
        try await database.clearHistory(since: nil)
        try await database.clearFavicons()
        await Self.removeWebsiteData()
    }

    @MainActor
    private static func removeWebsiteData() async {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        )
    }
}
#endif
