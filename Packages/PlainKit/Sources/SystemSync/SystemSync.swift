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
///
/// Operations run one at a time, in order, each to its end (an actor alone would interleave them
/// at every `await`), so a clear can never put back a favorite a later change removed.
public actor SystemSync {
    private let makeFile: @Sendable () -> SharedFavoritesFile?
    private let makeIndexed: @Sendable () -> SharedFavoritesFile?
    /// Found on first use, on the actor: looking up the App Group folder asks the system.
    private lazy var file: SharedFavoritesFile? = makeFile()
    /// What Spotlight holds, written only after it took the list, so a failed index is retried
    /// on the next change or launch instead of being taken for done.
    private lazy var indexedFile: SharedFavoritesFile? = makeIndexed()
    private let index: any SpotlightIndexing
    private let widgets: any WidgetReloading
    private let onChange: @Sendable () -> Void
    private let log = Logger(subsystem: "dev.abrahamgonzalez.plainbrowser", category: "system")
    /// What the shared file and Spotlight hold now; nil until first read.
    private var shared: [SharedFavorite]?
    private var indexed: [SharedFavorite]?
    /// The operation running or last queued; the next waits for it.
    private var last: Task<Void, Never>?

    /// - Parameters:
    ///   - file: the App Group file; nil where the group is not available (then only Spotlight).
    ///   - indexed: where the list Spotlight last took is remembered (next to `file`).
    ///   - onChange: after each change was written (the app updates its App Shortcuts' parameters).
    public init(
        file: @autoclosure @escaping @Sendable () -> SharedFavoritesFile?,
        indexed: @autoclosure @escaping @Sendable () -> SharedFavoritesFile? = nil,
        index: any SpotlightIndexing, widgets: any WidgetReloading, onChange: @escaping @Sendable () -> Void = {}
    ) {
        makeFile = file
        makeIndexed = indexed
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

    /// Writes `favorites` wherever they differ from what is there. On launch the files from last
    /// time are the reference, so an unchanged list costs two small reads.
    func apply(_ favorites: [SharedFavorite]) async {
        await serially { await self.write(favorites) }
    }

    /// Clear History and Data: everything Plain gave Spotlight and iOS goes. Favorites stay in
    /// Plain (the clear keeps them), so they are indexed again right after.
    public func browsingDataCleared() async {
        await serially { await self.clearIndex() }
    }

    private func serially(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = last
        let task = Task {
            await previous?.value
            await operation()
        }
        last = task
        await task.value
    }

    private func write(_ favorites: [SharedFavorite]) async {
        if shared == nil { shared = file?.read() }
        if indexed == nil { indexed = indexedFile?.read() }
        if shared != favorites {
            do {
                try file?.write(favorites)
            } catch {
                log.error("Shared favorites write failed: \(error.localizedDescription, privacy: .public)")
            }
            shared = favorites
            widgets.reloadWidgets()
            onChange()
        }
        if indexed != favorites { await reindex(favorites) }
    }

    private func clearIndex() async {
        do {
            try await index.deleteAll()
        } catch {
            log.error("Spotlight clear failed: \(error.localizedDescription, privacy: .public)")
        }
        await reindex(shared ?? file?.read() ?? [])
    }

    private func reindex(_ favorites: [SharedFavorite]) async {
        // A replace that fails halfway leaves Spotlight unknown: forget the old record first, so
        // no later list is ever taken as already indexed.
        indexed = nil
        try? indexedFile.map { try FileManager.default.removeItem(at: $0.url) }
        do {
            try await index.replace(favorites.map(SpotlightItem.init), inDomain: SpotlightItem.favoritesDomain)
            indexed = favorites
            try indexedFile?.write(favorites)
        } catch {
            log.error("Spotlight index failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
