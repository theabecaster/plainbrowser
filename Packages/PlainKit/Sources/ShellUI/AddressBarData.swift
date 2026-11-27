import BrowserCore
import Foundation
import Storage
import Synchronization

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
    /// A page of a tab in `profile` finished loading. `kind` is `.typed` when the address bar
    /// asked for it (an address, a search or a picked suggestion), which weighs more in ranking.
    /// It goes into that profile's history, whichever profile is the window's now.
    func pageVisited(url: URL, title: String?, kind: VisitKind, profile: ProfileID)
    /// A visited page's title arrived or changed.
    func pageTitleChanged(url: URL, title: String, profile: ProfileID)
    /// The window's profile: suggestions, favorites and typed-input learning use its history.
    var profile: ProfileID { get set }
    /// A profile is being deleted: what is queued for its history is written, and it is never
    /// used again.
    func forgetProfile(_ id: ProfileID) async
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
    /// Settings > Appearance, once the saved settings are read; nil before (the windows keep
    /// the launch copy, `AppAppearance`).
    var appearance: Appearance? { get }
    /// `observer` runs on the main thread each time the settings in effect change (read at launch,
    /// or saved). Every window adds one: the data is the app's.
    func observeSettings(_ observer: @escaping () -> Void)
}

extension AddressBarData {
    public func forgetProfile(_ id: ProfileID) async {}
    public func prepareForTyping() {}
    public func firstFrameDidCommit() {}

    /// A visit the address bar did not ask for (a link, a redirect), in Personal.
    public func pageVisited(url: URL, title: String?) {
        pageVisited(url: url, title: title, kind: .link, profile: Profile.defaultID)
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
    public var appearance: Appearance? { hasSettings ? settings.appearance : nil }
    private var settingsObservers: [() -> Void] = []
    private var hasFirstFrame = false
    private var preconnectAfterFirstFrame = false
    public var searchEngine: SearchEngine { settings.searchEngine }
    /// The main database: settings, and Personal's history and favorites.
    private var database: AppDatabase?
    /// Every other profile's history database (`ProfileDataLocation`), opened on first use.
    private var profileDatabase: ((ProfileID) async -> AppDatabase?)?
    public var profile = Profile.defaultID
    /// The history writers visits went to, so `flush` writes them all.
    private var recorders: [ProfileID: HistoryRecorder] = [:]
    /// Bumped by `apply(_:)`, so the read in `attach` never undoes a newer save.
    private var settingsEdits = 0
    /// Made on the first keystroke, not at launch: it builds a URL session.
    private lazy var client = makeClient()
    private let makeClient: () -> SuggestionClient
    /// The newest queued history change, so `flush` includes it.
    private var lastRecord: Task<Void, Never>?
    /// The visit title changes belong to.
    private var lastVisit: (url: URL, at: Date, profile: ProfileID)?
    /// The engine rows in the last list delivered, held in place for the next keystroke when no
    /// cached answer fits it (`suggestions(for:update:)`).
    private var shownSearches: [String] = []
    /// The text `shownSearches` were delivered for, and when they were first held past it: rows
    /// are held only for the next keystroke's text (one typed or deleted after it), and for one
    /// `suggestionHoldWindow` in all, however many keystrokes come before an answer.
    private var shownQuery = ""
    private var heldSince: ContinuousClock.Instant?

    /// - Parameter makeClient: builds the engine suggestion client on first use (tests pass one
    ///   with a fake loader).
    public init(makeClient: @escaping () -> SuggestionClient = { SuggestionClient() }) {
        self.makeClient = makeClient
    }

    /// Starts using `database`: Personal's history and favorites, and the saved search engine.
    /// `profiles` opens each other profile's history database.
    public func attach(_ database: AppDatabase, profiles: ((ProfileID) async -> AppDatabase?)? = nil) async {
        self.database = database
        profileDatabase = profiles
        let edits = settingsEdits
        if let stored = try? await database.settings(), edits == settingsEdits {
            settings = stored
        }
        hasSettings = true
        settingsDidChange()
    }

    /// Puts `settings` in effect; Settings calls it after each save.
    public func apply(_ settings: BrowserSettings) {
        settingsEdits += 1
        self.settings = settings
        hasSettings = true
        settingsDidChange()
    }

    public func observeSettings(_ observer: @escaping () -> Void) {
        settingsObservers.append(observer)
    }

    private func settingsDidChange() {
        for observer in settingsObservers { observer() }
    }

    /// Writes buffered history. Call when the app moves to the background.
    public func flush() async {
        await lastRecord?.value
        await database?.historyRecorder.flush()
        for recorder in recorders.values { await recorder.flush() }
    }

    /// `profile`'s history database: the main one for Personal.
    private func database(for profile: ProfileID) async -> AppDatabase? {
        guard profile != Profile.defaultID else { return database }
        guard database != nil, let profileDatabase else { return nil }
        let opened = await profileDatabase(profile)
        if let opened { recorders[profile] = opened.historyRecorder }
        return opened
    }

    /// Delivers at most two lists per keystroke, and never one with fewer engine rows only to add
    /// them back a moment later (that reads as flicker):
    /// 1. At once: local pages with the engine rows already known for this text (the cached
    ///    answer for its longest prefix). Where that has fewer rows than the previous keystroke
    ///    showed, the previous rows fill the rest for `FixedChoices.suggestionHoldWindow` while
    ///    the answer is on its way.
    /// 2. The engine's answer, when it differs. If it has not come by the end of the hold, the
    ///    held rows go first, then the answer follows whenever it arrives.
    public func suggestions(for query: String, update: @escaping ([AddressBarSuggestion]) -> Void) async {
        let engine = searchEngine
        let isPrivate = isPrivate
        let client = client
        // The database and the cache are read together, so the first list already has both.
        async let cachedAnswer = client.cachedSuggestions(for: query, engine: engine, isPrivate: isPrivate)
        var history: [PageCandidate] = []
        var favorites: [PageCandidate] = []
        if let database = await database(for: profile), let candidates = try? await database.addressBarCandidates(for: query) {
            (history, favorites) = candidates
        }
        let cached = await cachedAnswer
        guard !Task.isCancelled else { return }

        let remote = SuggestionClient.allowsRemote(query, isPrivate: isPrivate)
        // Hold the previous rows only while typing on from (or back over) the text they were for,
        // and never longer than the hold window in all: they never come back after the field
        // was cleared, and never linger over several fast keystrokes on a slow network.
        let now = ContinuousClock.now
        // One keystroke on: a character typed or deleted. Clearing the field and typing again
        // changes more than one, so rows for the old text never come back.
        let typingOn = !shownQuery.isEmpty && abs(query.count - shownQuery.count) <= 1
            && (query.hasPrefix(shownQuery) || shownQuery.hasPrefix(query))
        let holdLeft = FixedChoices.suggestionHoldWindow - (heldSince.map { now - $0 } ?? .zero)
        let canHold = remote && typingOn && holdLeft > .zero
        let held = !canHold ? [] : Array(
            shownSearches.filter { old in !cached.contains { $0.caseInsensitiveCompare(old) == .orderedSame } }
                .prefix(max(0, shownSearches.count - cached.count))
        )
        let first = cached + held
        var shown = first
        func deliver(_ searches: [String], holding: Bool = false) {
            shown = searches
            shownSearches = searches
            shownQuery = query
            if !holding { heldSince = nil } else if heldSince == nil { heldSince = now }
            update(AddressBarSuggestions.merge(query: query, history: history, favorites: favorites, searches: searches))
        }
        deliver(first, holding: !held.isEmpty)
        guard remote else { return }

        let request = Task { try? await client.suggestions(for: query, engine: engine, isPrivate: isPrivate) }
        let answer: [String]? = await withTaskCancellationHandler {
            if !held.isEmpty, case .some(let early) = await Self.value(of: request, within: holdLeft) {
                return early
            }
            if !held.isEmpty, !Task.isCancelled {
                // The answer is late: the rows for the old text go now.
                deliver(cached)
            }
            return await request.value
        } onCancel: {
            request.cancel()
        }
        guard !Task.isCancelled else { return }
        let fresh = answer ?? []
        if fresh.isEmpty {
            // No answer (offline, timed out, nothing to suggest): rows for the old text go.
            if !held.isEmpty, shown == first { deliver(cached) }
        } else if fresh != shown {
            deliver(fresh)
        } else {
            // The answer confirms the rows on screen: they are no longer held.
            heldSince = nil
        }
    }

    /// `task`'s value if it finishes within `window`; otherwise `.none` at the window's end,
    /// without waiting for the task (which keeps running).
    private static func value<T: Sendable>(of task: Task<T, Never>, within window: Duration) async -> T? {
        let first = FirstValue<T?>()
        return await withCheckedContinuation { continuation in
            first.attach(continuation)
            Task { first.resolve(.some(await task.value)) }
            Task {
                try? await Task.sleep(for: window)
                first.resolve(.none)
            }
        }
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
        guard database != nil, Self.isRecordable(url),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let previous = lastRecord
        let profile = profile
        lastRecord = Task {
            await previous?.value
            await self.database(for: profile)?.recordPickedSuggestion(input: input, url: url)
        }
    }

    public func cancelSuggestions() {
        shownSearches = []
        shownQuery = ""
        heldSince = nil
        Task { [client] in await client.cancel() }
    }

    public func favorites() async -> [FavoritePage] {
        guard let database = await database(for: profile), let favorites = try? await database.favorites() else { return [] }
        return favorites.map { FavoritePage(url: $0.url, title: $0.title) }
    }

    public func isFavorite(_ url: URL) async -> Bool {
        guard let database = await database(for: profile) else { return false }
        return (try? await database.favorite(for: url)) != nil
    }

    public func setFavorite(_ isFavorite: Bool, url: URL, title: String?) async -> Bool {
        guard let database = await database(for: profile) else { return false }
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

    public func pageVisited(url: URL, title: String?, kind: VisitKind, profile: ProfileID) {
        guard database != nil, Self.isRecordable(url) else { return }
        let visit = HistoryVisit(url: url, title: title, visitedAt: Date(), kind: kind)
        lastVisit = (url, visit.visitedAt, profile)
        let previous = lastRecord
        lastRecord = Task {
            await previous?.value
            await self.database(for: profile)?.historyRecorder.record(visit)
        }
    }

    /// Names the last recorded visit only, and only when it is to `url` in the same profile: a
    /// title never lands on another visit, and does nothing once that visit has been cleared.
    public func pageTitleChanged(url: URL, title: String, profile: ProfileID) {
        guard database != nil, Self.isRecordable(url), !title.isEmpty,
              let lastVisit, lastVisit.url == url, lastVisit.profile == profile
        else { return }
        let previous = lastRecord
        lastRecord = Task {
            await previous?.value
            await self.database(for: profile)?.historyRecorder.recordTitle(title, for: url, visitedAt: lastVisit.at)
        }
    }

    /// A deleted profile's history database is about to go: visits still queued for it are
    /// written first, and it is never used again.
    public func forgetProfile(_ id: ProfileID) async {
        await lastRecord?.value
        await recorders.removeValue(forKey: id)?.flush()
    }

    /// Only web pages go into history: not `about:blank` or other internal pages.
    static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// The first of two racing values, handed to one waiting continuation exactly once.
private final class FirstValue<T: Sendable>: Sendable {
    private struct State {
        var value: T?
        var continuation: CheckedContinuation<T, Never>?
        var isDone = false
    }

    private let state = Mutex(State())

    func resolve(_ value: T) {
        let continuation: CheckedContinuation<T, Never>? = state.withLock { state in
            guard !state.isDone else { return nil }
            guard let continuation = state.continuation else {
                if state.value == nil { state.value = value }
                return nil
            }
            state.isDone = true
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: value)
    }

    func attach(_ continuation: CheckedContinuation<T, Never>) {
        let ready: T? = state.withLock { state in
            guard let value = state.value else {
                state.continuation = continuation
                return nil
            }
            state.isDone = true
            return value
        }
        if let ready { continuation.resume(returning: ready) }
    }
}
