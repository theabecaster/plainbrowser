import Foundation
import os
import PlainShared
import Storage
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Asks WidgetKit to redraw Plain's widgets (the seam tests replace).
public protocol WidgetReloading: Sendable {
    func reloadWidgets()
}

#if canImport(WidgetKit)
public struct WidgetCenterReloader: WidgetReloading {
    public init() {}
    public func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif

/// Keeps the system's copies of the favorites in step with the database: the App Group file the
/// widgets and App Intents read, the Spotlight index, and the widgets' timelines. It follows the
/// favorites table (`AppDatabase.favoritesChanges`), so no writer has to remember to call it.
///
/// Only favorites leave the app: history stays out of Spotlight (`FixedChoices.spotlightIndexesHistory`)
/// and private tabs never reach any of this. Everything runs off the main thread, at background
/// priority, after launch.
public actor SystemSync {
    private let makeFile: @Sendable () -> SharedFavoritesFile?
    /// Found on first use, on the actor: looking up the App Group folder asks the system.
    private lazy var file: SharedFavoritesFile? = makeFile()
    private let index: any SpotlightIndexing
    private let widgets: any WidgetReloading
    private let onChange: @Sendable () -> Void
    private let log = Logger(subsystem: "dev.abrahamgonzalez.plainbrowser", category: "system")
    /// What the system copies hold now; nil until the first value was applied.
    private var current: [SharedFavorite]?

    /// - Parameters:
    ///   - file: the App Group file; nil where the group is not available (then only Spotlight).
    ///   - onChange: after each change was written (the app updates its App Shortcuts' parameters).
    public init(
        file: @autoclosure @escaping @Sendable () -> SharedFavoritesFile?, index: any SpotlightIndexing,
        widgets: any WidgetReloading, onChange: @escaping @Sendable () -> Void = {}
    ) {
        makeFile = file
        self.index = index
        self.widgets = widgets
        self.onChange = onChange
    }

    /// Follows the favorites until the calling task is cancelled.
    public func follow(_ database: AppDatabase) async {
        for await favorites in database.favoritesChanges() {
            await apply(favorites.map { SharedFavorite(url: $0.url, title: $0.title) })
        }
    }

    /// Writes `favorites` everywhere when they differ from what the system has. On launch the
    /// file from last time is the reference, so an unchanged list costs one small read.
    func apply(_ favorites: [SharedFavorite]) async {
        if current == nil, let file { current = file.read() }
        if current == favorites { return }
        do {
            try await index.replace(favorites.map(SpotlightItem.init), inDomain: SpotlightItem.favoritesDomain)
        } catch {
            log.error("Spotlight index failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try file?.write(favorites)
        } catch {
            log.error("Shared favorites write failed: \(error.localizedDescription, privacy: .public)")
        }
        current = favorites
        widgets.reloadWidgets()
        onChange()
    }

    /// Clear History and Data: everything Plain gave Spotlight and iOS goes. Favorites stay in
    /// Plain (the clear keeps them), so they are indexed again right after.
    public func browsingDataCleared() async {
        do {
            try await index.deleteAll()
            let favorites = current ?? file?.read() ?? []
            try await index.replace(favorites.map(SpotlightItem.init), inDomain: SpotlightItem.favoritesDomain)
        } catch {
            log.error("Spotlight clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
