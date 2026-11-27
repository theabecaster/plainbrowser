import BrowserCore
import FeatureUI
import Foundation
import Storage
#if os(iOS)
import SwiftUI
import UIKit
import WebEngine
import WebKit
#endif

/// The low-frequency screens the shell presents as sheets: Settings, History and the favorites
/// editor (FeatureUI, SwiftUI). It builds each screen's model over the database and wraps the
/// view in a hosting controller; the browser presents it.
///
/// Like `LiveAddressBarData`, it works before the database opens: until `attach`, it has no
/// screens to offer and the menu items that open them are disabled.
public final class FeatureSheets {
    private let addressBar: LiveAddressBarData
    private var database: AppDatabase?
    /// Kept across presentations, so a save still queued from the last visit is written (and
    /// read back) before anything the next visit does.
    private var settingsModel: SettingsModel?
    private var favoritesModel: FavoritesModel?

    /// - Parameter addressBar: gets each saved setting at once, and orders history reads and
    ///   deletes after the visits it has queued.
    public init(addressBar: LiveAddressBarData) {
        self.addressBar = addressBar
    }

    public func attach(_ database: AppDatabase) {
        self.database = database
    }

    /// Runs after Clear History and Data has cleared Plain's own data: the app empties what the
    /// system holds for it (Spotlight). Set once, when the system sync starts.
    public var didClearBrowsingData: @Sendable () async -> Void = {}

    private func runClearHook() async {
        await didClearBrowsingData()
    }

    var isReady: Bool { database != nil }

    /// Writes every visit the shell has queued; history reads and deletes wait for it, so a
    /// page just visited shows and a cleared visit can't land late.
    private var settleHistory: @MainActor @Sendable () async -> Void {
        { [addressBar] in await addressBar.flush() }
    }

    func makeSettingsModel() -> SettingsModel? {
        if let settingsModel { return settingsModel }
        guard let database else { return nil }
        let store = LiveSettingsStore(database: database) { [addressBar] in addressBar.apply($0) }
        // Read when the clear runs: the model is kept, and the hook may be set after it was made.
        let clearer = LiveBrowsingDataClearer(database: database, settle: settleHistory) { [weak self] in
            await self?.runClearHook()
        }
        let model = SettingsModel(store: store, clearer: clearer)
        settingsModel = model
        return model
    }

    func makeHistoryStore() -> ShellHistoryStore? {
        database.map { ShellHistoryStore(database: $0, settle: settleHistory) }
    }

    #if os(iOS)
    /// Settings, with a single Done button.
    /// - Parameter isTabLayoutAvailable: a tab list fits here; otherwise the Tab Layout row is
    ///   disabled and its footer says why.
    func settings(isTabLayoutAvailable: Bool = true, onDone: @escaping () -> Void) -> UIViewController? {
        guard let model = makeSettingsModel() else { return nil }
        model.isTabLayoutAvailable = isTabLayoutAvailable
        return Self.sheet(SettingsView(model: model, onDone: onDone), identifier: "settingsSheet")
    }

    /// History. `onOpen` gets the page the user tapped.
    func history(onOpen: @escaping (URL) -> Void, onDone: @escaping () -> Void) -> UIViewController? {
        guard let store = makeHistoryStore() else { return nil }
        let model = HistoryModel(store: store)
        return Self.sheet(HistoryView(model: model, onOpen: onOpen, onDone: onDone), identifier: "historySheet")
    }

    /// The reading list. `onOpen` gets the page the user tapped (already marked read).
    func readingList(onOpen: @escaping (URL) -> Void, onDone: @escaping () -> Void) -> UIViewController? {
        guard let database else { return nil }
        let model = ReadingListModel(store: database)
        return Self.sheet(ReadingListView(model: model, onOpen: onOpen, onDone: onDone), identifier: "readingListSheet")
    }

    /// The favorites editor.
    func favoritesEditor(onDone: @escaping () -> Void) -> UIViewController? {
        guard let database else { return nil }
        let model = favoritesModel ?? FavoritesModel(store: database)
        favoritesModel = model
        return Self.sheet(FavoritesEditor(model: model, onDone: onDone), identifier: "favoritesSheet")
    }

    /// Archived tabs. Restores and deletes go to the shell, which hands them to `TabStore`.
    func archive(
        footer: String, onRestore: @escaping (ArchivedTab) -> Void, onDelete: @escaping ([TabID]) -> Void,
        onDone: @escaping () -> Void
    ) -> UIViewController? {
        guard let database else { return nil }
        let model = ArchiveModel(store: database, onRestore: onRestore, onDelete: onDelete)
        return Self.sheet(ArchiveView(model: model, footer: footer, onDone: onDone), identifier: "archiveSheet")
    }

    /// Downloads in progress and finished ones, from the engine's coordinator.
    func downloads<Source: DownloadListSource>(source: Source, onDone: @escaping () -> Void) -> UIViewController {
        Self.sheet(DownloadsView(source: source, onDone: onDone), identifier: "downloadsSheet")
    }

    /// A page sheet: every screen is a list that wants the room.
    private static func sheet(_ view: some View, identifier: String) -> UIViewController {
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        host.view.accessibilityIdentifier = identifier
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

/// History for the History screen: `AppDatabase`'s, after the visits the shell has queued are
/// written. Without that, a page visited a moment ago would be missing, and a visit still on its
/// way to the recorder could land after a delete and bring the page back.
nonisolated struct ShellHistoryStore: HistoryStoring {
    let database: AppDatabase
    let settle: @MainActor @Sendable () async -> Void

    func visits(matching query: String, limit: Int) async throws -> [HistoryVisit] {
        await settle()
        return try await database.visits(matching: query, limit: limit)
    }

    func deleteHistory(for url: URL) async throws {
        await settle()
        try await database.deleteHistory(for: url)
    }

    func clearHistory(since start: Date?) async throws {
        await settle()
        try await database.clearHistory(since: start)
    }
}

/// Settings > Clear History and Data: history (after the visits the shell has queued, through
/// the one history writer), cached site icons, then every cookie, cache and storage entry in the
/// website data store the web views share, then what the system holds for Plain (`cleared`).
/// Open tabs, favorites and the reading list stay.
nonisolated struct LiveBrowsingDataClearer: BrowsingDataClearing {
    let database: AppDatabase
    let settle: @MainActor @Sendable () async -> Void
    var cleared: @Sendable () async -> Void = {}

    func clearHistoryAndData() async throws {
        await settle()
        try await database.clearHistory(since: nil)
        try await database.clearFavicons()
        #if os(iOS)
        await Self.removeWebsiteData()
        #endif
        await cleared()
    }

    #if os(iOS)
    /// The store the tabs share (`AppWebsiteData.store`): in an isolated test run that is a
    /// throwaway store, so clearing never reaches the owner's cookies and logins.
    @MainActor
    private static func removeWebsiteData() async {
        await AppWebsiteData.store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        )
    }
    #endif
}
