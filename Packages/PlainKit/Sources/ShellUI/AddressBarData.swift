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
    /// A page finished loading. `kind` is `.typed` when the address bar asked for it (an address,
    /// a search or a picked suggestion), which weighs more in ranking.
    func pageVisited(url: URL, title: String?, kind: VisitKind)
    /// A visited page's title arrived or changed.
    func pageTitleChanged(url: URL, title: String)
    /// The address field took focus: typing is likely next. A chance to preconnect to the
    /// suggestion host (docs/plan.md, data rule 6). Called on the main thread on every focus,
    /// including at launch before the first frame, so it must return at once and start any work
    /// off the main thread.
    func prepareForTyping()
    /// A page suggestion was picked for the typed `input`, so it ranks first for that input next
    /// time. Not for searches or favorites tiles.
    func suggestionPicked(input: String, url: URL)
    /// The first frame is on screen: work held back from launch (`prepareForTyping`'s
    /// preconnect, which builds a URL session) may start.
    func firstFrameDidCommit()
    /// A private tab is on screen: no remote suggestions and no preconnect (docs/plan.md, data
    /// rule 6).
    var isPrivate: Bool { get set }
    /// Settings > Archive Tabs, once the saved settings are read; nil before, so nothing is
    /// archived on a default the user may have changed.
    var archiveAfter: ArchiveAfter? { get }
    /// Settings > Tab Layout, once the saved settings are read; nil before.
    var tabLayout: TabLayout? { get }
    /// Called on the main thread when the settings in effect change (read at launch, or saved).
    var onSettingsChange: (() -> Void)? { get set }
}

extension AddressBarData {
    public func prepareForTyping() {}
    public func firstFrameDidCommit() {}

    /// A visit the address bar did not ask for (a link, a redirect).
    public func pageVisited(url: URL, title: String?) {
        pageVisited(url: url, title: title, kind: .link)
    }
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
    /// The settings in effect: the search engine here, the archive interval for the shell.
    public private(set) var settings = BrowserSettings.defaults
    /// Private browsing: no remote suggestions, no preconnect. The shell sets it from the tab on
    /// screen.
    public var isPrivate = false
    /// True once the saved settings are read (or a save replaced them).
    private var hasSettings = false
    public var archiveAfter: ArchiveAfter? { hasSettings ? settings.archiveAfter : nil }
    public var tabLayout: TabLayout? { hasSettings ? settings.tabLayout : nil }
    public var onSettingsChange: (() -> Void)?
    private var hasFirstFrame = false
    private var preconnectAfterFirstFrame = false
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
        hasSettings = true
        onSettingsChange?()
    }

    /// Puts `settings` in effect; Settings calls it after each save.
    public func apply(_ settings: BrowserSettings) {
        settingsEdits += 1
        self.settings = settings
        hasSettings = true
        onSettingsChange?()
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
        // While the engine answers, the longest cached prefix's suggestions fill the list.
        let cached = await client.cachedSuggestions(for: query, engine: searchEngine, isPrivate: isPrivate)
        guard !Task.isCancelled else { return }
        if !cached.isEmpty {
            update(AddressBarSuggestions.merge(query: query, history: history, favorites: favorites, searches: cached))
        }

        guard let searches = try? await client.suggestions(for: query, engine: searchEngine, isPrivate: isPrivate),
              !searches.isEmpty, searches != cached, !Task.isCancelled
        else { return }
        update(AddressBarSuggestions.merge(query: query, history: history, favorites: favorites, searches: searches))
    }

    /// Warms the connection to the engine's suggestion host as the field takes focus. Returns at
    /// once: the client is an actor and the request runs at utility priority. The launch focus
    /// comes before the first frame, so that one waits for `firstFrameDidCommit()`: the client
    /// (and its URL session) is never made on the launch path.
    public func prepareForTyping() {
        guard hasFirstFrame else {
            preconnectAfterFirstFrame = true
            return
        }
        let engine = searchEngine
        let isPrivate = isPrivate
        Task { [client] in await client.preconnect(engine: engine, isPrivate: isPrivate) }
    }

    public func firstFrameDidCommit() {
        guard !hasFirstFrame else { return }
        hasFirstFrame = true
        if preconnectAfterFirstFrame {
            preconnectAfterFirstFrame = false
            prepareForTyping()
        }
    }

    public func suggestionPicked(input: String, url: URL) {
        guard let database, Self.isRecordable(url),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let previous = lastRecord
        lastRecord = Task {
            await previous?.value
            await database.recordPickedSuggestion(input: input, url: url)
        }
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

    public func pageVisited(url: URL, title: String?, kind: VisitKind) {
        guard let recorder, Self.isRecordable(url) else { return }
        let visit = HistoryVisit(url: url, title: title, visitedAt: Date(), kind: kind)
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
