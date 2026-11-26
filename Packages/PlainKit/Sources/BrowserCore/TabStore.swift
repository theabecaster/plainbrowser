import Foundation
import Observation

/// The single owner of tabs (AGENTS.md, "One owner per piece of state"): which tabs are open, in
/// which window and order, what each pane shows, the recently closed stack and moves to and from
/// the archive. The engine's `Tab` objects and web views are keyed by the same ids, and the shell
/// keeps them in step with this store.
///
/// Every change is synchronous and in memory; persistence gets an ordered change through
/// `TabPersistence.enqueue` and writes off the main thread. Private tabs live in their own list
/// per window and are never handed to persistence.
///
/// Signposts (`tab.open`, `tab.close`, `tab.select`, `tab.archive`, ...) are emitted by the shell
/// around these calls: BrowserCore is Foundation-only.
@MainActor
@Observable
public final class TabStore {
    /// Windows in order. There is always at least one.
    public private(set) var windows: [TabWindow]
    /// Every open tab, regular and private, by id.
    public private(set) var tabs: [TabID: TabEntry]
    /// Oldest first; `reopenLastClosed` takes the last.
    public private(set) var recentlyClosed: [ClosedTabBatch]

    /// The engine's answer to "must this tab stay open?": playing media, in picture in picture or
    /// fullscreen, capturing camera or microphone, or downloading. Such tabs are never archived.
    @ObservationIgnored public var isTabInUse: ((TabID) -> Bool)?

    @ObservationIgnored private let persistence: (any TabPersistence)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var windowOfTab: [TabID: WindowID] = [:]

    /// A store holding `session` (from `AppDatabase.loadTabSession()`), or an empty window.
    public init(
        session: TabSession = .empty,
        persistence: (any TabPersistence)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.persistence = persistence
        self.now = now
        var entries: [TabID: TabEntry] = [:]
        entries.reserveCapacity(session.tabs.count)
        for entry in session.tabs where !entry.isPrivate {
            entries[entry.id] = entry
        }
        var placed: [TabID: WindowID] = [:]
        placed.reserveCapacity(entries.count)
        var windows: [TabWindow] = []
        for stored in session.windows where !windows.contains(where: { $0.id == stored.id }) {
            var ids: [TabID] = []
            ids.reserveCapacity(stored.tabIDs.count)
            for id in stored.tabIDs where entries[id] != nil && placed[id] == nil {
                placed[id] = stored.id
                ids.append(id)
            }
            let panes = stored.panes.prefix(FixedChoices.maxPanesPerWindow).map { id in
                id.flatMap { placed[$0] == stored.id ? $0 : nil }
            }
            windows.append(TabWindow(id: stored.id, tabIDs: ids, panes: panes, focusedPane: stored.focusedPane))
        }
        if windows.isEmpty { windows.append(TabWindow()) }
        // Tabs no window lists (an older database, or a damaged one) join the first window.
        let unplaced = session.tabs.filter { entries[$0.id] != nil && placed[$0.id] == nil }
        for entry in unplaced {
            placed[entry.id] = windows[0].id
            windows[0].tabIDs.append(entry.id)
        }
        for index in windows.indices {
            Self.normalizePinned(&windows[index].tabIDs, entries: entries)
            // A tab shown in two panes would need two web views; keep the first.
            var seen = Set<TabID>()
            for pane in windows[index].panes.indices {
                if let id = windows[index].panes[pane], !seen.insert(id).inserted {
                    windows[index].panes[pane] = nil
                }
            }
        }
        self.windows = windows
        tabs = entries
        windowOfTab = placed
        recentlyClosed = Array(session.recentlyClosed.suffix(FixedChoices.recentlyClosedLimit))
    }

    // MARK: Reading

    public func window(_ id: WindowID) -> TabWindow? {
        windows.first { $0.id == id }
    }

    /// The window a tab is in.
    public func windowID(of tab: TabID) -> WindowID? {
        windowOfTab[tab]
    }

    /// A window's tabs in order: its regular tabs, or its private ones.
    public func tabs(in window: WindowID, private isPrivate: Bool = false) -> [TabEntry] {
        guard let window = self.window(window) else { return [] }
        return (isPrivate ? window.privateTabIDs : window.tabIDs).compactMap { tabs[$0] }
    }

    /// The tab in the window's focused pane.
    public func selectedTabID(in window: WindowID) -> TabID? {
        self.window(window)?.selectedTabID
    }

    /// Tabs on screen in any pane of any window. They are never archived.
    public var visibleTabIDs: Set<TabID> {
        Set(windows.flatMap { $0.panes.compactMap { $0 } })
    }

    // MARK: Windows

    /// Adds an empty window (a new scene) and returns its id.
    @discardableResult
    public func addWindow() -> WindowID {
        let window = TabWindow()
        windows.append(window)
        saveSession()
        return window.id
    }

    /// Closes a window: its regular tabs become one recently closed batch, its private tabs are
    /// gone. The last window is emptied instead, so the store always has one.
    public func closeWindow(_ id: WindowID) {
        guard let index = windowIndex(id) else { return }
        let window = windows[index]
        recordClosed(window.tabIDs, from: window)
        for tab in window.tabIDs + window.privateTabIDs {
            tabs[tab] = nil
            windowOfTab[tab] = nil
        }
        clearOpeners(of: Set(window.tabIDs + window.privateTabIDs))
        if windows.count == 1 {
            windows[0] = TabWindow(id: id)
        } else {
            windows.remove(at: index)
        }
        saveSession()
    }

    // MARK: Tabs

    /// Opens a tab and returns its id.
    ///
    /// - A tab with an opener goes right after the opener and the tabs it already opened, and is
    ///   private when the opener is.
    /// - Other tabs go at the end of the window's list.
    /// - In the foreground it shows in `pane` (default: the focused pane).
    @discardableResult
    public func open(
        _ url: URL? = nil, title: String? = nil, in window: WindowID? = nil, opener: TabID? = nil,
        inBackground: Bool = false, isPrivate: Bool = false, pane: Int? = nil
    ) -> TabID {
        let openerEntry = opener.flatMap { tabs[$0] }
        let isPrivate = isPrivate || openerEntry?.isPrivate == true
        let windowID = window.flatMap { windowIndex($0) != nil ? $0 : nil }
            ?? opener.flatMap { windowOfTab[$0] }
            ?? windows[0].id
        let index = windowIndex(windowID)!
        let date = now()
        let entry = TabEntry(url: url, title: title, openerID: openerEntry?.id, isPrivate: isPrivate, createdAt: date)
        tabs[entry.id] = entry
        windowOfTab[entry.id] = windowID

        func insert(into list: inout [TabID]) {
            var position = list.count
            if FixedChoices.childTabsOpenNextToOpener, let opener = openerEntry?.id,
               let openerIndex = list.firstIndex(of: opener) {
                position = openerIndex + 1
                while position < list.count, tabs[list[position]]?.openerID == opener {
                    position += 1
                }
            }
            if !isPrivate { position = max(position, pinnedCount(list)) }
            list.insert(entry.id, at: position)
        }
        if isPrivate {
            insert(into: &windows[index].privateTabIDs)
        } else {
            insert(into: &windows[index].tabIDs)
        }
        if !inBackground {
            show(entry.id, inPane: pane, windowIndex: index)
        }
        if !isPrivate || !inBackground { saveSession() }
        return entry.id
    }

    /// Shows a tab in a pane of its window and focuses that pane. Without `pane`, a tab already on
    /// screen just gets focus, and any other tab shows in the focused pane. With `pane`, a tab
    /// already in the other pane trades places with what `pane` showed.
    public func select(_ id: TabID, pane: Int? = nil) {
        guard let windowID = windowOfTab[id], let index = windowIndex(windowID) else { return }
        show(id, inPane: pane, windowIndex: index)
        saveSession()
    }

    /// Closes a tab. A pane that showed it shows the tab's opener when that is still open and not
    /// in the other pane, else the next tab, else the previous one, else the start page.
    public func close(_ id: TabID) {
        close([id])
    }

    /// Closes tabs as one action: one recently closed batch, reopened together.
    public func close(_ ids: [TabID]) {
        guard !closeTabs(ids).isEmpty else { return }
        saveSession()
    }

    /// Close All Tabs: every regular tab of the window except pinned ones (or every private tab),
    /// as one batch that Reopen Closed Tab brings back. Panes that showed them show the start page.
    public func closeAllTabs(in window: WindowID, private isPrivate: Bool = false) {
        guard let index = windowIndex(window) else { return }
        let ids = isPrivate
            ? windows[index].privateTabIDs
            : windows[index].tabIDs.filter { !(FixedChoices.closeAllKeepsPinnedTabs && tabs[$0]?.isPinned == true) }
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        let emptied = windows[index].panes.indices.filter { windows[index].panes[$0].map(gone.contains) == true }
        _ = closeTabs(ids)
        for pane in emptied { windows[index].panes[pane] = nil }
        saveSession()
    }

    /// Moves a tab within its list. Pinned tabs stay before unpinned ones.
    public func move(_ id: TabID, to destination: Int) {
        guard let windowID = windowOfTab[id], let index = windowIndex(windowID), let entry = tabs[id] else { return }
        func reorder(_ list: inout [TabID], pinnedBound: Bool) {
            guard let from = list.firstIndex(of: id) else { return }
            list.remove(at: from)
            var to = min(max(0, destination), list.count)
            if pinnedBound {
                let pinned = pinnedCount(list)
                to = entry.isPinned ? min(to, pinned) : max(to, pinned)
            }
            list.insert(id, at: to)
        }
        if entry.isPrivate {
            reorder(&windows[index].privateTabIDs, pinnedBound: false)
        } else {
            reorder(&windows[index].tabIDs, pinnedBound: true)
            saveSession()
        }
    }

    /// Pins or unpins a regular tab. Pinning moves it to the end of the pinned tabs; unpinning to
    /// the start of the others.
    public func setPinned(_ pinned: Bool, for id: TabID) {
        guard var entry = tabs[id], !entry.isPrivate, entry.isPinned != pinned,
              let windowID = windowOfTab[id], let index = windowIndex(windowID) else { return }
        windows[index].tabIDs.removeAll { $0 == id }
        let boundary = pinnedCount(windows[index].tabIDs)
        entry.isPinned = pinned
        tabs[id] = entry
        windows[index].tabIDs.insert(id, at: boundary)
        saveSession()
    }

    /// The page's address and title, from the engine's `Tab`, so they survive a relaunch and the
    /// archive can find them.
    public func updatePage(_ id: TabID, url: URL?, title: String?) {
        guard var entry = tabs[id], entry.url != url || entry.title != title else { return }
        entry.url = url
        entry.title = title
        tabs[id] = entry
        if !entry.isPrivate { saveSession() }
    }

    /// The tab's latest thumbnail file, from the engine.
    public func setThumbnail(_ thumbnail: TabThumbnail?, for id: TabID) {
        guard var entry = tabs[id], entry.thumbnail != thumbnail else { return }
        entry.thumbnail = thumbnail
        tabs[id] = entry
        if !entry.isPrivate { saveSession() }
    }

    // MARK: Panes

    /// Splits the window into two panes with `id` in the new one, focused. A tab that was in the
    /// first pane moves, and the first pane shows its neighbour. Does nothing when already split.
    public func split(_ window: WindowID, showing id: TabID?) {
        guard let index = windowIndex(window), windows[index].panes.count < FixedChoices.maxPanesPerWindow else { return }
        if let id, windowOfTab[id] != window { return }
        windows[index].panes.append(nil)
        if let id {
            show(id, inPane: windows[index].panes.count - 1, windowIndex: index, refillVacated: true)
        } else {
            windows[index].focusedPane = windows[index].panes.count - 1
        }
        saveSession()
    }

    /// Closes a pane; its tab stays open. The remaining pane is focused.
    public func closePane(_ pane: Int, in window: WindowID) {
        guard let index = windowIndex(window), windows[index].panes.count > 1,
              windows[index].panes.indices.contains(pane) else { return }
        if let id = windows[index].panes[pane] { touch(id) }
        windows[index].panes.remove(at: pane)
        windows[index].focusedPane = 0
        saveSession()
    }

    /// The pane touched last; shared bar buttons act on it.
    public func focusPane(_ pane: Int, in window: WindowID) {
        guard let index = windowIndex(window), windows[index].panes.indices.contains(pane),
              windows[index].focusedPane != pane else { return }
        windows[index].focusedPane = pane
        saveSession()
    }

    /// Swaps what the two panes show; focus follows its tab.
    public func swapPanes(in window: WindowID) {
        guard let index = windowIndex(window), windows[index].panes.count == 2 else { return }
        windows[index].panes.swapAt(0, 1)
        windows[index].focusedPane = 1 - windows[index].focusedPane
        saveSession()
    }

    // MARK: Recently closed

    /// Reopens the last closed batch where it was: after the tab that preceded it when that is
    /// still open, else at its old index. Tabs that were on screen show again, else the first.
    /// Returns the reopened ids in order.
    @discardableResult
    public func reopenLastClosed() -> [TabID] {
        guard let batch = recentlyClosed.popLast() else { return [] }
        let date = now()
        var reopened: [TabID] = []
        var toSelect: [TabID] = []
        for closed in batch.tabs where tabs[closed.entry.id] == nil {
            let windowID = windowIndex(closed.windowID) != nil ? closed.windowID : windows[0].id
            let index = windowIndex(windowID)!
            var entry = closed.entry
            entry.lastActiveAt = date
            if let opener = entry.openerID, tabs[opener] == nil { entry.openerID = nil }
            var list = windows[index].tabIDs
            var position = closed.previousTabID.flatMap { list.firstIndex(of: $0).map { $0 + 1 } }
                ?? min(closed.index, list.count)
            let pinned = pinnedCount(list)
            position = entry.isPinned ? min(position, pinned) : max(position, pinned)
            list.insert(entry.id, at: position)
            windows[index].tabIDs = list
            tabs[entry.id] = entry
            windowOfTab[entry.id] = windowID
            reopened.append(entry.id)
            if closed.wasSelected { toSelect.append(entry.id) }
        }
        if toSelect.isEmpty, let first = reopened.first { toSelect = [first] }
        for id in toSelect {
            guard let windowID = windowOfTab[id], let index = windowIndex(windowID) else { continue }
            show(id, inPane: nil, windowIndex: index)
        }
        saveSession()
        return reopened
    }

    public func clearRecentlyClosed() {
        guard !recentlyClosed.isEmpty else { return }
        recentlyClosed = []
        saveSession()
    }

    // MARK: Archive

    /// Moves tabs not opened for `setting`'s interval to the archive (Arc-style): never pinned
    /// tabs, tabs on screen, private tabs or tabs the engine reports in use (`isTabInUse`).
    /// Returns the archived ids; the shell drops their engine tabs but keeps their state files,
    /// so a restored tab comes back where it was. Run it at launch and on each return to the
    /// foreground. The due check runs off the main thread; the store changes on it.
    @discardableResult
    public func archiveIdleTabs(after setting: ArchiveAfter) async -> [TabID] {
        guard setting.interval != nil else { return [] }
        let date = now()
        let visible = visibleTabIDs
        let candidates = windows.flatMap(\.tabIDs).compactMap { id -> IdleCandidate? in
            guard let entry = tabs[id], !entry.isPinned, !visible.contains(id) else { return nil }
            return IdleCandidate(id: id, lastActiveAt: entry.lastActiveAt)
        }
        guard !candidates.isEmpty else { return [] }
        let due = await Self.dueTabs(candidates, setting: setting, now: date)
        guard !due.isEmpty else { return [] }

        // The store may have changed during the hop: check every rule again.
        let visibleNow = visibleTabIDs
        var archived: [TabEntry] = []
        for id in due {
            guard let entry = tabs[id], !entry.isPrivate, !entry.isPinned, !visibleNow.contains(id),
                  setting.isDue(lastActive: entry.lastActiveAt, now: date), isTabInUse?(id) != true,
                  let windowID = windowOfTab[id], let index = windowIndex(windowID) else { continue }
            remove(id, windowIndex: index)
            archived.append(entry)
        }
        guard !archived.isEmpty else { return [] }
        clearOpeners(of: Set(archived.map(\.id)))
        persistence?.enqueue(.archive(archived, at: date))
        saveSession()
        return archived.map(\.id)
    }

    /// Brings an archived tab (from `AppDatabase.archivedTabs` or its search) back as an open tab
    /// at the end of the window's list, shown unless `inBackground`.
    @discardableResult
    public func restoreArchived(_ archived: TabEntry, in window: WindowID? = nil, inBackground: Bool = false) -> TabID {
        if tabs[archived.id] != nil {
            if !inBackground { select(archived.id) }
            return archived.id
        }
        let windowID = window.flatMap { windowIndex($0) != nil ? $0 : nil } ?? windows[0].id
        let index = windowIndex(windowID)!
        let entry = TabEntry(
            id: archived.id, url: archived.url, title: archived.title, createdAt: archived.createdAt,
            lastActiveAt: now(), thumbnail: archived.thumbnail
        )
        tabs[entry.id] = entry
        windowOfTab[entry.id] = windowID
        windows[index].tabIDs.append(entry.id)
        if !inBackground { show(entry.id, inPane: nil, windowIndex: index) }
        saveSession()
        return entry.id
    }

    /// Deletes archived tabs for good.
    public func deleteArchived(_ ids: [TabID]) {
        guard !ids.isEmpty else { return }
        persistence?.enqueue(.deleteArchived(ids))
    }

    /// Deletes the whole archive (Clear History and Data).
    public func clearArchive() {
        persistence?.enqueue(.deleteArchived(nil))
    }

    // MARK: Persistence

    /// Writes every change so far. Call it when the app moves to the background.
    public func flush() async {
        await persistence?.flush()
    }

    /// What persistence stores: windows, regular tabs and the recently closed stack.
    public var session: TabSession {
        TabSession(
            windows: windows.map { window in
                WindowSession(
                    id: window.id, tabIDs: window.tabIDs,
                    panes: window.panes.map { id in id.flatMap { tabs[$0]?.isPrivate == false ? $0 : nil } },
                    focusedPane: window.focusedPane
                )
            },
            tabs: windows.flatMap(\.tabIDs).compactMap { tabs[$0] },
            recentlyClosed: recentlyClosed
        )
    }

    // MARK: Private

    private struct IdleCandidate: Sendable {
        let id: TabID
        let lastActiveAt: Date
    }

    @concurrent
    private nonisolated static func dueTabs(_ candidates: [IdleCandidate], setting: ArchiveAfter, now: Date) async -> [TabID] {
        candidates.filter { setting.isDue(lastActive: $0.lastActiveAt, now: now) }.map(\.id)
    }

    private func saveSession() {
        persistence?.enqueue(.session(session))
    }

    private func windowIndex(_ id: WindowID) -> Int? {
        windows.firstIndex { $0.id == id }
    }

    private func pinnedCount(_ list: [TabID]) -> Int {
        list.prefix { tabs[$0]?.isPinned == true }.count
    }

    private static func normalizePinned(_ list: inout [TabID], entries: [TabID: TabEntry]) {
        let pinned = list.filter { entries[$0]?.isPinned == true }
        guard !pinned.isEmpty else { return }
        list = pinned + list.filter { entries[$0]?.isPinned != true }
    }

    /// Stamps a tab as seen now (it is leaving the screen or arriving on it).
    private func touch(_ id: TabID) {
        guard var entry = tabs[id] else { return }
        entry.lastActiveAt = now()
        tabs[id] = entry
    }

    /// Puts `id` in a pane of window `index` and focuses it. When the tab is already in the other
    /// pane, the two panes trade tabs, unless `refillVacated`, which fills the vacated pane with a
    /// neighbour instead (a split moving the tab over).
    private func show(_ id: TabID, inPane pane: Int?, windowIndex index: Int, refillVacated: Bool = false) {
        var window = windows[index]
        // Without a pane, a tab already on screen keeps its pane, which gets focus.
        let target = pane.flatMap { window.panes.indices.contains($0) ? $0 : nil }
            ?? window.panes.firstIndex(of: id) ?? window.focusedPane
        if let current = window.panes.firstIndex(of: id) {
            if current != target {
                if refillVacated {
                    window.panes[current] = nil
                    window.panes[target] = id
                    windows[index] = window
                    windows[index].panes[current] = replacement(nearIndex: window.tabIDs.firstIndex(of: id), in: window, closing: nil)
                    windows[index].focusedPane = target
                    touch(id)
                    return
                }
                window.panes.swapAt(current, target)
            }
            window.focusedPane = target
            windows[index] = window
            touch(id)
            return
        }
        if let old = window.panes[target] { touch(old) }
        window.panes[target] = id
        window.focusedPane = target
        windows[index] = window
        touch(id)
    }

    /// Removes a tab from window `index` and from every pane, filling those panes per `close`.
    private func remove(_ id: TabID, windowIndex index: Int) {
        guard let entry = tabs[id] else { return }
        var window = windows[index]
        let list = entry.isPrivate ? window.privateTabIDs : window.tabIDs
        let position = list.firstIndex(of: id)
        if entry.isPrivate {
            window.privateTabIDs.removeAll { $0 == id }
        } else {
            window.tabIDs.removeAll { $0 == id }
        }
        for pane in window.panes.indices where window.panes[pane] == id {
            window.panes[pane] = nil
            window.panes[pane] = replacement(nearIndex: position, in: window, closing: entry)
        }
        windows[index] = window
        tabs[id] = nil
        windowOfTab[id] = nil
    }

    /// The tab a pane shows after its tab goes away: the closing tab's opener, else the tab now at
    /// its index, else earlier ones; never one already in another pane.
    private func replacement(nearIndex position: Int?, in window: TabWindow, closing: TabEntry?) -> TabID? {
        let shown = Set(window.panes.compactMap { $0 })
        let list = closing?.isPrivate == true ? window.privateTabIDs : window.tabIDs
        if FixedChoices.closingChildSelectsOpener, let opener = closing?.openerID,
           list.contains(opener), !shown.contains(opener) {
            return opener
        }
        guard let position else { return nil }
        let start = min(position, list.count)
        if let next = list[start...].first(where: { !shown.contains($0) }) { return next }
        return list[..<start].last { !shown.contains($0) }
    }

    /// Tabs opened by a closed tab no longer have an opener to return to.
    private func clearOpeners(of closed: Set<TabID>) {
        for (id, entry) in tabs where entry.openerID.map(closed.contains) == true {
            tabs[id]?.openerID = nil
        }
    }

    /// Removes tabs and records the regular ones as one batch, each with its place in the window
    /// as it was before any of them closed, so reopening rebuilds the same order.
    @discardableResult
    private func closeTabs(_ ids: [TabID]) -> Set<TabID> {
        var batch: [ClosedTab] = []
        var targets: [(id: TabID, window: WindowID)] = []
        for id in ids where !targets.contains(where: { $0.id == id }) {
            guard let windowID = windowOfTab[id], let window = window(windowID), let entry = tabs[id] else { continue }
            targets.append((id, windowID))
            if !entry.isPrivate, let position = window.tabIDs.firstIndex(of: id) {
                batch.append(ClosedTab(
                    entry: entry, windowID: windowID, index: position,
                    previousTabID: position > 0 ? window.tabIDs[position - 1] : nil,
                    wasSelected: window.panes.contains(id)
                ))
            }
        }
        guard !targets.isEmpty else { return [] }
        for target in targets {
            guard let index = windowIndex(target.window) else { continue }
            remove(target.id, windowIndex: index)
        }
        let closed = Set(targets.map(\.id))
        clearOpeners(of: closed)
        // Window order, so each tab's predecessor is back before it.
        let order = Dictionary(uniqueKeysWithValues: windows.enumerated().map { ($1.id, $0) })
        batch.sort { (order[$0.windowID] ?? 0, $0.index) < (order[$1.windowID] ?? 0, $1.index) }
        pushClosed(batch)
        return closed
    }

    private func recordClosed(_ ids: [TabID], from window: TabWindow) {
        let batch = ids.enumerated().compactMap { position, id -> ClosedTab? in
            guard let entry = tabs[id] else { return nil }
            return ClosedTab(
                entry: entry, windowID: window.id, index: position,
                previousTabID: position > 0 ? ids[position - 1] : nil,
                wasSelected: window.panes.contains(id)
            )
        }
        pushClosed(batch)
    }

    private func pushClosed(_ tabs: [ClosedTab]) {
        guard !tabs.isEmpty else { return }
        recentlyClosed.append(ClosedTabBatch(closedAt: now(), tabs: tabs))
        if recentlyClosed.count > FixedChoices.recentlyClosedLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - FixedChoices.recentlyClosedLimit)
        }
    }
}
