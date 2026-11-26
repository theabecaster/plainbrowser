#if canImport(UIKit)
import BrowserCore
import Foundation
import os
import PerfSignposts
import Storage
import WebEngine

/// Keeps the engine's `Tab` objects in step with BrowserCore's `TabStore`, the one owner of the tab
/// list, its order, selection and persistence (docs/decisions.md, "Tab model and persistence").
/// Both use the same `TabID`. The pool owns the web views; each engine `Tab` owns its page state;
/// this type only maps ids to engine tabs and tells the store what the pages became.
///
/// The shell shows one tab for now (M2 adds the gallery and switching), in the first window's
/// focused pane. Popups still become their own tabs, opened next to their opener.
///
/// Before the database opens, the store is in memory. After the first frame,
/// `restoreLastTab()` loads the saved session and hands the store to Storage's `TabSessionWriter`;
/// tabs the user opened meanwhile join it.
final class EngineTabs {
    let pool: WebViewPool
    private(set) var store = TabStore()
    private var engineTabs: [TabID: Tab] = [:]
    private let database: DatabaseProvider
    private let tabStates: TabStateStore?

    init(pool: WebViewPool, database: @escaping DatabaseProvider, tabStates: TabStateStore?) {
        self.pool = pool
        self.database = database
        self.tabStates = tabStates
    }

    private var window: WindowID { store.windows[0].id }

    /// The tab the focused pane shows.
    var selected: Tab? {
        store.selectedTabID(in: window).map(engineTab)
    }

    /// A new tab at the end, shown in the focused pane, with no web view until it loads.
    @discardableResult
    func newTab() -> Tab {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabOpen, id: signposter.makeSignpostID())
        defer { signposter.endInterval(Signposts.tabOpen, interval) }
        return engineTab(store.open(in: window))
    }

    /// A tab the pool made for a popup: opened next to its opener and shown.
    func add(_ child: Tab, after opener: Tab) {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabOpen, id: signposter.makeSignpostID(), "popup")
        defer { signposter.endInterval(Signposts.tabOpen, interval) }
        engineTabs[child.id] = child
        store.open(child.url, in: window, opener: opener.id, id: child.id)
    }

    func select(_ tab: Tab) {
        guard store.selectedTabID(in: window) != tab.id else { return }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabSelect, id: signposter.makeSignpostID())
        defer { signposter.endInterval(Signposts.tabSelect, interval) }
        store.select(tab.id)
    }

    /// Closes `tab` and returns the tab the pane shows next (its opener for a popup), or nil when
    /// the pane shows the start page.
    @discardableResult
    func close(_ tab: Tab) -> Tab? {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabClose, id: signposter.makeSignpostID())
        defer { signposter.endInterval(Signposts.tabClose, interval) }
        store.close(tab.id)
        engineTabs[tab.id] = nil
        pool.close(tab)
        return selected
    }

    /// The page's address or title changed: the store keeps them for relaunch and archive search.
    func pageChanged(_ tab: Tab) {
        store.updatePage(tab.id, url: tab.url, title: tab.title.isEmpty ? nil : tab.title)
    }

    /// Writes what is waiting. Call when the app moves to the background.
    func flush() async {
        await store.flush()
    }

    /// The engine tab for a store id, made on first use from what the store knows (its state file
    /// restores history when one is read first; see `restoreLastTab`).
    private func engineTab(_ id: TabID) -> Tab {
        if let tab = engineTabs[id] { return tab }
        let entry = store.tabs[id]
        let state = entry?.url.map {
            TabRestorationState(url: $0, title: entry?.title ?? "", interactionState: nil, sessionStorage: nil)
        }
        let tab = pool.makeTab(id: id, restoring: state)
        engineTabs[id] = tab
        return tab
    }

    // MARK: Restore

    /// Loads the saved session off the main thread and gives the store its persistence. Returns the
    /// selected tab, with its history, scroll and sessionStorage read from its state file, when
    /// the user has not opened a page meanwhile; else nil.
    func restoreLastTab() async -> Tab? {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.launchRestoreTab)
        defer { signposter.endInterval(Signposts.launchRestoreTab, interval) }
        guard let database = await database() else { return nil }
        let saved = (try? await database.loadTabSession()) ?? .empty
        let openedMeanwhile = !store.tabs.isEmpty
        var session = saved
        if openedMeanwhile {
            // The user's tabs join the saved window and stay on screen.
            let mine = store.session
            session.tabs += mine.tabs
            if session.windows.isEmpty {
                session.windows = mine.windows
            } else if let current = mine.windows.first {
                session.windows[0].tabIDs += current.tabIDs
                session.windows[0].panes = current.panes
                session.windows[0].focusedPane = current.focusedPane
            }
        }
        store = TabStore(session: session, persistence: database.tabSession)
        guard !openedMeanwhile else { return nil }
        // Files of tabs that never got a row (a crash between the two writes). Only when nothing
        // was opened before the session loaded: such a tab's file may predate its row.
        Task { try? await database.removeOrphanedTabStates() }
        guard let id = store.selectedTabID(in: window), let entry = store.tabs[id], let tabStates else { return nil }
        let state = await Self.state(of: entry, in: tabStates)
        guard engineTabs[id] == nil, store.selectedTabID(in: window) == id,
              state.url != nil || state.interactionState != nil
        else { return nil }
        let tab = pool.makeTab(id: id, restoring: state)
        engineTabs[id] = tab
        return tab
    }

    @concurrent
    private nonisolated static func state(of entry: TabEntry, in store: TabStateStore) async -> TabRestorationState {
        if let data = try? await store.read(for: entry.id), let state = try? TabRestorationState(encoded: data) {
            return state
        }
        // No state file (the app quit before the first save): the address alone.
        return TabRestorationState(url: entry.url, title: entry.title ?? "", interactionState: nil, sessionStorage: nil)
    }
}
#endif
