#if canImport(UIKit)
import BrowserCore
import Foundation
import Observation
import os
import PerfSignposts
import Storage
import WebEngine

/// Keeps the engine's `Tab` objects in step with BrowserCore's `TabStore`, the one owner of the tab
/// list, its order, selection, private tabs, the recently closed stack and the archive
/// (docs/decisions.md, "Tab model and persistence"). Both use the same `TabID`. The pool owns the
/// web views; each engine `Tab` owns its page state; this type maps ids to engine tabs, makes them
/// on first use, and tells the store what their pages became.
///
/// Engine tabs are made lazily: a tab restored at launch, reopened or brought back from the
/// archive has none until it is shown, and then reads its state file off the main thread
/// (`WebViewPool.makeSavedTab`). Closing or archiving a tab keeps its state file and thumbnail, so
/// it comes back where it was; Storage deletes them once no row names the tab.
///
/// Signposts `tab.open`, `tab.close`, `tab.select`, `tab.archive` and the `tab.reopen`,
/// `tab.unarchive`, `tab.closeAll` events are emitted here, around the `TabStore` calls.
final class EngineTabs {
    let pool: WebViewPool
    private(set) var store = TabStore()
    private var engineTabs: [TabID: Tab] = [:]
    private var watches: [TabID: TabWatch] = [:]
    private let database: DatabaseProvider
    private let tabStates: TabStateStore?
    /// Called once per main run loop turn after the tab list or a tab's title, address or
    /// thumbnail changed (the gallery reloads).
    var onChange: (() -> Void)?
    private var changeScheduled = false
    /// The saved session is in the store (after `restoreSession()`).
    private(set) var isSessionLoaded = false

    init(pool: WebViewPool, database: @escaping DatabaseProvider, tabStates: TabStateStore?) {
        self.pool = pool
        self.database = database
        self.tabStates = tabStates
        wireStore()
    }

    private var window: WindowID { store.windows[0].id }

    // MARK: Reading

    /// The id of the tab the focused pane shows.
    var selectedID: TabID? {
        store.selectedTabID(in: window)
    }

    /// The tab the focused pane shows.
    var selected: Tab? {
        selectedID.map(tab)
    }

    /// The window's tabs in order: regular or private.
    func entries(private isPrivate: Bool) -> [TabEntry] {
        store.tabs(in: window, private: isPrivate)
    }

    func entry(_ id: TabID) -> TabEntry? {
        store.tabs[id]
    }

    /// The engine tab for `id` if one was made already; never makes one.
    func existingTab(_ id: TabID) -> Tab? {
        engineTabs[id]
    }

    /// The tabs before and after `id` in its own list (regular or private): the bar swipe's
    /// neighbours.
    func neighbours(of id: TabID) -> (previous: TabID?, next: TabID?) {
        guard let entry = store.tabs[id] else { return (nil, nil) }
        let list = entries(private: entry.isPrivate).map(\.id)
        guard let index = list.firstIndex(of: id) else { return (nil, nil) }
        return (index > 0 ? list[index - 1] : nil, index + 1 < list.count ? list[index + 1] : nil)
    }

    var canReopenClosedTab: Bool { !store.recentlyClosed.isEmpty }

    /// The engine tab for a store id, made on first use from what the store knows. A tab with an
    /// address reads its state file when it first gets a web view.
    func tab(_ id: TabID) -> Tab {
        if let tab = engineTabs[id] { return tab }
        let entry = store.tabs[id]
        let tab: Tab
        if let entry, entry.isPrivate {
            tab = pool.makeTab(id: id, isPrivate: true)
        } else if let url = entry?.url {
            tab = pool.makeSavedTab(id: id, url: url, title: entry?.title ?? "")
        } else {
            tab = pool.makeTab(id: id)
        }
        adopt(tab)
        return tab
    }

    // MARK: Changing

    /// A new tab at the end of its list (or after `opener`), shown in the focused pane unless
    /// `inBackground`. It has no web view until it is shown or loads something.
    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool = false, opener: Tab? = nil, inBackground: Bool = false) -> Tab {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabOpen, id: signposter.makeSignpostID(), "\(inBackground ? "background" : "shown")")
        defer { signposter.endInterval(Signposts.tabOpen, interval) }
        let id = store.open(
            url, in: window, opener: opener?.id, inBackground: inBackground, isPrivate: isPrivate || opener?.isPrivate == true
        )
        return tab(id)
    }

    /// A tab the pool made for a popup: opened next to its opener and shown.
    func add(_ child: Tab, after opener: Tab) {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabOpen, id: signposter.makeSignpostID(), "popup")
        defer { signposter.endInterval(Signposts.tabOpen, interval) }
        adopt(child)
        store.open(child.url, in: window, opener: opener.id, isPrivate: child.isPrivate, id: child.id)
    }

    func select(_ tab: Tab) {
        guard store.selectedTabID(in: window) != tab.id else { return }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabSelect, id: signposter.makeSignpostID())
        defer { signposter.endInterval(Signposts.tabSelect, interval) }
        store.select(tab.id)
    }

    /// Closes a tab. Its state file and thumbnail stay for Reopen Closed Tab (a private tab keeps
    /// nothing). The pane then shows the store's choice (`selectedID`).
    func close(_ id: TabID) {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabClose, id: signposter.makeSignpostID())
        defer { signposter.endInterval(Signposts.tabClose, interval) }
        let wasPrivate = store.tabs[id]?.isPrivate == true
        store.close(id)
        drop(id)
        if wasPrivate { endPrivateSessionIfEmpty() }
    }

    /// Close All Tabs: every regular tab except pinned ones, or every private tab, as one batch that
    /// Reopen Closed Tab brings back (private tabs never come back).
    func closeAll(private isPrivate: Bool) {
        Signposts.signposter.emitEvent(Signposts.tabCloseAll, "\(isPrivate ? "private" : "regular")")
        let before = Set(entries(private: isPrivate).map(\.id))
        store.closeAllTabs(in: window, private: isPrivate)
        let after = Set(entries(private: isPrivate).map(\.id))
        for id in before.subtracting(after) { drop(id) }
        if isPrivate { endPrivateSessionIfEmpty() }
    }

    /// Reopens the last closed batch; the store shows it. Returns its ids.
    @discardableResult
    func reopenLastClosed() -> [TabID] {
        Signposts.signposter.emitEvent(Signposts.tabReopen)
        return store.reopenLastClosed()
    }

    /// Moves `id` to `index` in its list.
    func move(_ id: TabID, to index: Int) {
        store.move(id, to: index)
    }

    /// Brings an archived tab back at the end of the list and shows it.
    @discardableResult
    func restoreArchived(_ archived: ArchivedTab) -> Tab {
        Signposts.signposter.emitEvent(Signposts.tabUnarchive)
        return tab(store.restoreArchived(archived.entry, in: window))
    }

    func deleteArchived(_ ids: [TabID]) {
        store.deleteArchived(ids)
    }

    /// Moves tabs not opened for `setting`'s interval to the archive (launch and each return to
    /// the foreground). WebKit is asked first whether hidden tabs play media, so a tab playing
    /// sound stays. Archived tabs keep their state file.
    func archiveIdleTabs(after setting: ArchiveAfter) async {
        guard isSessionLoaded, setting.interval != nil else { return }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabArchive, id: signposter.makeSignpostID())
        let visible = store.visibleTabIDs
        for (id, tab) in engineTabs where !visible.contains(id) && tab.tier != .discarded {
            await tab.refreshMediaState()
        }
        let archived = await store.archiveIdleTabs(after: setting)
        for id in archived { drop(id) }
        signposter.endInterval(Signposts.tabArchive, interval, "\(archived.count)")
    }

    /// Writes what is waiting. Call when the app moves to the background.
    func flush() async {
        await store.flush()
    }

    // MARK: Restore

    /// Loads the saved session off the main thread and gives the store its persistence. Every
    /// saved tab is back in the list; none has a web view yet. Returns the selected tab (it reads
    /// its state file when shown), unless the user opened a page meanwhile.
    func restoreSession() async -> Tab? {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.launchRestoreTab)
        defer { signposter.endInterval(Signposts.launchRestoreTab, interval) }
        guard let database = await database() else { return nil }
        let saved = (try? await database.loadTabSession()) ?? .empty
        let mine = store
        let openedMeanwhile = !mine.tabs.isEmpty
        var session = saved
        if openedMeanwhile {
            // The user's tabs join the saved window and stay on screen.
            let current = mine.session
            session.tabs += current.tabs
            if session.windows.isEmpty {
                session.windows = current.windows
            } else if let window = current.windows.first {
                session.windows[0].tabIDs += window.tabIDs
                session.windows[0].panes = window.panes
                session.windows[0].focusedPane = window.focusedPane
            }
        }
        store = TabStore(session: session, persistence: database.tabSession)
        wireStore()
        // Private tabs opened before the session loaded stay (the store never saves them).
        for entry in mine.tabs(in: mine.windows[0].id, private: true) {
            store.open(entry.url, title: entry.title, in: window, isPrivate: true, id: entry.id)
        }
        if let id = mine.selectedTabID(in: mine.windows[0].id), mine.tabs[id]?.isPrivate == true {
            store.select(id)
        }
        isSessionLoaded = true
        scheduleChange()
        guard !openedMeanwhile, let id = selectedID, store.tabs[id]?.url != nil else { return nil }
        return tab(id)
    }

    /// Deletes files no tab row names any more: state files left by a crash between two writes,
    /// and thumbnails of tabs gone for good. Off the main thread, after launch.
    func pruneFiles() async {
        guard let database = await database() else { return }
        let started = Date()
        try? await database.removeOrphanedTabStates()
        guard var keep = try? await database.referencedTabIDs() else { return }
        keep.formUnion(store.tabs.keys)
        await pool.thumbnails.prune(keeping: keep, writtenBefore: started)
    }

    // MARK: Private

    private func wireStore() {
        store.isTabInUse = { [weak self] id in self?.engineTabs[id]?.isBusy ?? false }
    }

    /// Starts following an engine tab's address, title and thumbnail into the store.
    private func adopt(_ tab: Tab) {
        engineTabs[tab.id] = tab
        watches[tab.id] = TabWatch(tab) { [weak self] tab in self?.pageChanged(tab) }
    }

    /// The store keeps each tab's address and title for relaunch and archive search, and its
    /// thumbnail's revision.
    private func pageChanged(_ tab: Tab) {
        guard store.tabs[tab.id] != nil else { return }
        store.updatePage(tab.id, url: tab.url, title: tab.title.isEmpty ? nil : tab.title)
        // A private tab's entry is never written, so its revision only reaches the gallery.
        if tab.thumbnailRevision > 0 {
            store.setThumbnail(TabThumbnail(fileName: tab.id.uuidString + ".jpg", revision: tab.thumbnailRevision), for: tab.id)
        }
        scheduleChange()
    }

    /// Forgets the engine tab of a tab that left the store; its state file and thumbnail stay.
    private func drop(_ id: TabID) {
        watches.removeValue(forKey: id)?.cancel()
        if let tab = engineTabs.removeValue(forKey: id) {
            pool.close(tab, keepingSavedState: true)
        }
        scheduleChange()
    }

    private func endPrivateSessionIfEmpty() {
        if entries(private: true).isEmpty { pool.endPrivateSession() }
    }

    private func scheduleChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            changeScheduled = false
            onChange?()
        }
    }
}

/// Calls `changed` when an engine tab's address, title or thumbnail changes, at most once per main
/// run loop turn. One per engine tab, for tabs on screen and off.
private final class TabWatch {
    private weak var tab: Tab?
    private let changed: (Tab) -> Void
    private var isCancelled = false
    private var last: (URL?, String, Int)?

    init(_ tab: Tab, changed: @escaping (Tab) -> Void) {
        self.tab = tab
        self.changed = changed
        track()
    }

    func cancel() {
        isCancelled = true
    }

    private func track() {
        guard !isCancelled, let tab else { return }
        let value = withObservationTracking {
            (tab.url, tab.title, tab.thumbnailRevision)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        if let last, last == value { return }
        let first = last == nil
        last = value
        // Nothing to report for a tab just made: the store already has what it was made from.
        if !first { changed(tab) }
    }
}
#endif
