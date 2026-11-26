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
public final class LiveAddressBarData: AddressBarData {
    public private(set) var searchEngine = FixedChoices.defaultSearchEngine
    private var database: AppDatabase?
    private var recorder: HistoryRecorder?
    /// Made on the first keystroke, not at launch: it builds a URL session.
    private lazy var client = SuggestionClient()

    public init() {}

    /// Starts using `database`: history, favorites and the saved search engine.
    public func attach(_ database: AppDatabase) async {
        self.database = database
        recorder = HistoryRecorder(database: database)
        if let settings = try? await database.settings() {
            searchEngine = settings.searchEngine
        }
    }

    /// Writes buffered history. Call when the app moves to the background.
    public func flush() async {
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

    public func pageVisited(url: URL, title: String?) {
        guard let recorder, Self.isRecordable(url) else { return }
        let visit = HistoryVisit(url: url, title: title, visitedAt: Date())
        Task { await recorder.record(visit) }
    }

    public func pageTitleChanged(url: URL, title: String) {
        guard let recorder, Self.isRecordable(url), !title.isEmpty else { return }
        Task { await recorder.recordTitle(title, for: url) }
    }

    /// Only web pages go into history: not `about:blank` or other internal pages.
    static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
