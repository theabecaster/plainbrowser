import BrowserCore
import Foundation
import Storage

/// A page pinned above the keyboard.
public struct FavoritePage: Hashable, Sendable {
    public var url: URL
    public var title: String?

    public init(url: URL, title: String?) {
        self.url = url
        self.title = title
    }
}

/// What the address bar needs from history, favorites, settings and the search engine. The shell
/// talks only to this seam, so it never reaches into storage or the network itself.
public protocol AddressBarData: AnyObject {
    /// The engine Return searches with.
    var searchEngine: SearchEngine { get }
    /// Suggestions for `query`, delivered through `update`: local pages first (fast), then again
    /// with the engine's suggestions merged in. Stops quietly when the calling task is cancelled.
    func suggestions(for query: String, update: @escaping ([AddressBarSuggestion]) -> Void) async
    /// Stops any engine request still running (the address bar closed).
    func cancelSuggestions()
    /// Favorites, in the user's order.
    func favorites() async -> [FavoritePage]
    /// Whether `url` is a favorite.
    func isFavorite(_ url: URL) async -> Bool
    /// Adds `url` to the end of the favorites, or removes it. Returns false when it couldn't.
    func setFavorite(_ isFavorite: Bool, url: URL, title: String?) async -> Bool
    /// A page finished loading.
    func pageVisited(url: URL, title: String?)
    /// A visited page's title arrived or changed.
    func pageTitleChanged(url: URL, title: String)
}

/// The app's address-bar data: GRDB history and favorites (Storage), the user's engine
/// (settings), and the engine's suggestion endpoint (`SuggestionClient`).
///
/// It starts empty and works before the database is open: `attach` hands it the database once
/// it has been opened off the main thread, so launch never waits on disk.
///
/// It holds the live copy of the settings: a Settings save calls `apply(_:)`, so the next search
/// and the next suggestion request use the new engine.
public final class LiveAddressBarData: AddressBarData {
    /// The settings in effect. Tab layout and archive interval wait here for the tab features.
    public private(set) var settings = BrowserSettings.defaults
    public var searchEngine: SearchEngine { settings.searchEngine }
    private var database: AppDatabase?
    /// The database's one history writer.
    private var recorder: HistoryRecorder?
    /// Bumped by `apply(_:)`, so the read in `attach` never undoes a newer save.
    private var settingsEdits = 0
    /// Made on the first keystroke, not at launch: it builds a URL session.
    private lazy var client = makeClient()
    private let makeClient: () -> SuggestionClient
    /// The newest queued history change, so `flush` includes it.
    private var lastRecord: Task<Void, Never>?
    /// The visit title changes belong to.
    private var lastVisit: (url: URL, at: Date)?

    /// - Parameter makeClient: builds the engine suggestion client on first use (tests pass one
    ///   with a fake loader).
    public init(makeClient: @escaping () -> SuggestionClient = { SuggestionClient() }) {
        self.makeClient = makeClient
    }

    /// Starts using `database`: history, favorites and the saved search engine.
    public func attach(_ database: AppDatabase) async {
        self.database = database
        recorder = database.historyRecorder
        let edits = settingsEdits
        if let stored = try? await database.settings(), edits == settingsEdits {
            settings = stored
        }
    }

    /// Puts `settings` in effect; Settings calls it after each save.
    public func apply(_ settings: BrowserSettings) {
        settingsEdits += 1
        self.settings = settings
    }

    /// Writes buffered history. Call when the app moves to the background.
    public func flush() async {
        await lastRecord?.value
        await recorder?.flush()
    }

    public func suggestions(for query: String, update: @escaping ([AddressBarSuggestion]) -> Void) async {
        var history: [PageCandidate] = []
        var favorites: [PageCandidate] = []
        if let database, let candidates = try? await database.addressBarCandidates(for: query) {
            (history, favorites) = candidates
        }
        guard !Task.isCancelled else { return }
        update(AddressBarSuggestions.merge(query: query, history: history, favorites: favorites, searches: []))

        guard let searches = try? await client.suggestions(for: query, engine: searchEngine),
              !searches.isEmpty, !Task.isCancelled
        else { return }
        update(AddressBarSuggestions.merge(query: query, history: history, favorites: favorites, searches: searches))
    }

    public func cancelSuggestions() {
        Task { [client] in await client.cancel() }
    }

    public func favorites() async -> [FavoritePage] {
        guard let database, let favorites = try? await database.favorites() else { return [] }
        return favorites.map { FavoritePage(url: $0.url, title: $0.title) }
    }

    public func isFavorite(_ url: URL) async -> Bool {
        guard let database else { return false }
        return (try? await database.favorite(for: url)) != nil
    }

    public func setFavorite(_ isFavorite: Bool, url: URL, title: String?) async -> Bool {
        guard let database else { return false }
        do {
            if isFavorite {
                let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                try await database.addFavorite(url: url, title: title?.isEmpty == false ? title : nil)
            } else {
                try await database.removeFavorite(url: url)
            }
            return true
        } catch {
            return false
        }
    }

    public func pageVisited(url: URL, title: String?) {
        guard let recorder, Self.isRecordable(url) else { return }
        let visit = HistoryVisit(url: url, title: title, visitedAt: Date())
        lastVisit = (url, visit.visitedAt)
        let previous = lastRecord
        lastRecord = Task {
            await previous?.value
            await recorder.record(visit)
        }
    }

    /// Names the last recorded visit only, and only when it is to `url`: a title never lands on
    /// another visit, and does nothing once that visit has been cleared.
    public func pageTitleChanged(url: URL, title: String) {
        guard let recorder, Self.isRecordable(url), !title.isEmpty,
              let lastVisit, lastVisit.url == url
        else { return }
        let previous = lastRecord
        lastRecord = Task {
            await previous?.value
            await recorder.recordTitle(title, for: url, visitedAt: lastVisit.at)
        }
    }

    /// Only web pages go into history: not `about:blank` or other internal pages.
    static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
