#if canImport(UIKit)
import Foundation
import os
import PerfSignposts
import Storage
import WebEngine

/// Owns the tabs (AGENTS.md: one owner per piece of state): their order, which one is selected,
/// and their rows in Storage. The pool owns their web views; each `Tab` owns its page state.
///
/// The shell shows one tab for now (M2 adds the gallery and switching). Popups still become their
/// own tabs here, so the seams M2 needs (`add`, `select`, `close`) are the ones in use today.
///
/// Rows are written when a tab is added (before the pool writes its first state file, as
/// `AppDatabase.removeOrphanedTabStates` requires), when one is selected or closed, and for every
/// tab on `saveAll()`. Each tab's history, scroll and sessionStorage are the pool's state files.
final class TabStore {
    let pool: WebViewPool
    private(set) var tabs: [Tab] = []
    private(set) var selected: Tab?
    private let database: DatabaseProvider
    private let tabStates: TabStateStore?
    /// Row writes, in the order they were made.
    private var lastWrite: Task<Void, Never>?
    /// When each tab was last selected (or added), for the rows.
    private var lastActive: [UUID: Date] = [:]

    init(pool: WebViewPool, database: @escaping DatabaseProvider, tabStates: TabStateStore?) {
        self.pool = pool
        self.database = database
        self.tabStates = tabStates
    }

    /// A new tab at the end, with no web view until it loads or is shown.
    @discardableResult
    func newTab() -> Tab {
        add(pool.makeTab())
    }

    /// Adds a tab the pool made (a popup) or restored.
    @discardableResult
    func add(_ tab: Tab, after opener: Tab? = nil) -> Tab {
        if let opener, let index = tabs.firstIndex(where: { $0 === opener }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        lastActive[tab.id] = Date()
        writeRows()
        return tab
    }

    func select(_ tab: Tab) {
        guard selected !== tab, tabs.contains(where: { $0 === tab }) else { return }
        selected = tab
        lastActive[tab.id] = Date()
        writeRows()
    }

    /// Closes `tab` and returns the tab to show next: its opener when it has one, else a
    /// neighbour. Nil when no tab is left.
    @discardableResult
    func close(_ tab: Tab) -> Tab? {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return selected }
        tabs.remove(at: index)
        lastActive[tab.id] = nil
        pool.close(tab)
        if selected === tab {
            selected = tabs.first { $0.id == tab.openerID } ?? (tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)])
        }
        let id = tab.id
        enqueueWrite { database in try? await database.deleteTabs(ids: [id]) }
        writeRows()
        return selected
    }

    func tab(id: UUID) -> Tab? {
        tabs.first { $0.id == id }
    }

    /// Writes every open tab's row with its current address and title. Runs on resign active, next
    /// to the pool's own state save.
    func saveAll() {
        writeRows()
    }

    /// Waits for every row write so far. For tests and suspension.
    func waitForWrites() async {
        await lastWrite?.value
    }

    // MARK: Restore

    /// The last session's selected tab, read and decoded off the main thread, or nil when there is
    /// none. It comes back without a web view; attaching it restores history, scroll and
    /// sessionStorage (`WebViewPool.makeTab(id:restoring:)`).
    ///
    /// Only that tab comes back for now: the shell shows one. The other rows stay for M2.
    func restoreLastTab() async -> Tab? {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.launchRestoreTab)
        defer { signposter.endInterval(Signposts.launchRestoreTab, interval) }
        guard let database = await database(), let tabStates,
              let record = try? await database.openTabs().max(by: { $0.lastActiveAt < $1.lastActiveAt })
        else { return nil }
        let state = await Self.state(of: record, in: tabStates)
        // The user may have opened a page while this was reading; that tab wins.
        guard selected == nil, state.url != nil || state.interactionState != nil else { return nil }
        let tab = pool.makeTab(id: record.id, restoring: state)
        tabs.append(tab)
        selected = tab
        lastActive[tab.id] = Date()
        writeRows()
        return tab
    }

    @concurrent
    private nonisolated static func state(of record: TabRecord, in store: TabStateStore) async -> TabRestorationState {
        if let data = try? await store.read(for: record.id), let state = try? TabRestorationState(encoded: data) {
            return state
        }
        // No state file (the app quit before the first save): the address alone.
        return TabRestorationState(
            url: record.url, title: record.title ?? "", interactionState: nil, sessionStorage: nil
        )
    }

    // MARK: Rows

    private func writeRows() {
        let now = Date()
        let rows = tabs.enumerated().map { index, tab in
            TabRecord(
                id: tab.id, url: tab.url, title: tab.title.isEmpty ? nil : tab.title, position: index,
                lastActiveAt: lastActive[tab.id] ?? now
            )
        }
        enqueueWrite { database in try? await database.saveTabs(rows) }
    }

    private func enqueueWrite(_ work: @escaping @Sendable (AppDatabase) async -> Void) {
        let previous = lastWrite
        let database = database
        lastWrite = Task {
            await previous?.value
            guard let database = await database() else { return }
            await work(database)
        }
    }
}
#endif
