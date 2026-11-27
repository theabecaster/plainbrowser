@testable import BrowserCore
import Foundation
import Synchronization
import Testing

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

/// Records what `TabStore` hands to persistence.
final class RecordingPersistence: TabPersistence {
    private let changes = Mutex<[TabChange]>([])
    var recorded: [TabChange] { changes.withLock { $0 } }
    var lastSession: TabSession? {
        recorded.reversed().lazy.compactMap { if case .session(let s) = $0 { s } else { nil } }.first
    }
    func enqueue(_ change: TabChange) { changes.withLock { $0.append(change) } }
    func flush() async {}
}

@MainActor
@Suite struct TabStoreTests {
    let clock = TestClock()
    let persistence = RecordingPersistence()

    func makeStore(_ session: TabSession = .empty) -> TabStore {
        let clock = clock
        return TabStore(session: session, persistence: persistence, now: { clock.now })
    }

    func url(_ name: String) -> URL { URL(string: "https://\(name).example/")! }

    // MARK: Open and select

    @Test func openAppendsAndSelectsUnlessInBackground() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a"))
        let b = store.open(url("b"))
        let c = store.open(url("c"), inBackground: true)
        #expect(store.windows[0].tabIDs == [a, b, c])
        #expect(store.selectedTabID(in: window) == b)
        store.select(c)
        #expect(store.selectedTabID(in: window) == c)
        #expect(persistence.lastSession?.windows[0].panes == [c])
    }

    @Test func aTabTheEngineMadeKeepsItsID() {
        let store = makeStore()
        let opener = store.open(url("a"))
        let popup = UUID()
        #expect(store.open(url("b"), opener: opener, id: popup) == popup)
        #expect(store.tabs[popup]?.openerID == opener)
        #expect(store.windows[0].tabIDs == [opener, popup])
    }

    @Test func selectingStampsBothTabsAsSeen() {
        let store = makeStore()
        let a = store.open(url("a"))
        clock.advance(100)
        let b = store.open(url("b"))
        #expect(store.tabs[a]?.lastActiveAt == clock.now, "the tab leaving the screen was seen until now")
        clock.advance(100)
        store.select(a)
        #expect(store.tabs[a]?.lastActiveAt == clock.now)
        #expect(store.tabs[b]?.lastActiveAt == clock.now)
    }

    @Test func childTabsOpenAfterOpenerAndItsEarlierChildren() {
        let store = makeStore()
        let a = store.open(url("a"))
        let z = store.open(url("z"), inBackground: true)
        let child1 = store.open(url("c1"), opener: a, inBackground: true)
        let child2 = store.open(url("c2"), opener: a, inBackground: true)
        #expect(store.windows[0].tabIDs == [a, child1, child2, z])
        #expect(store.tabs[child2]?.openerID == a)
    }

    @Test func privateOpenerMakesAPrivateChild() {
        let store = makeStore()
        let p = store.open(url("p"), isPrivate: true)
        let child = store.open(url("c"), opener: p)
        #expect(store.tabs[child]?.isPrivate == true)
        #expect(store.windows[0].privateTabIDs == [p, child])
        #expect(store.windows[0].tabIDs.isEmpty)
    }

    // MARK: Close

    @Test func closingAChildReturnsToItsOpener() {
        let store = makeStore()
        let a = store.open(url("a"))
        _ = store.open(url("b"), inBackground: true)
        let child = store.open(url("c"), opener: a)
        store.close(child)
        #expect(store.selectedTabID(in: store.windows[0].id) == a)
    }

    @Test func closingSelectsNextThenPreviousThenStartPage() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a")), b = store.open(url("b")), c = store.open(url("c"))
        store.select(b)
        store.close(b)
        #expect(store.selectedTabID(in: window) == c)
        store.close(c)
        #expect(store.selectedTabID(in: window) == a)
        store.close(a)
        #expect(store.selectedTabID(in: window) == nil)
        #expect(store.tabs.isEmpty)
    }

    @Test func closingNeverPicksATabShownInTheOtherPane() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a")), b = store.open(url("b")), c = store.open(url("c"))
        store.select(a)
        store.split(window, showing: b)
        #expect(store.windows[0].panes == [a, b])
        store.select(a)
        store.close(a)
        #expect(store.windows[0].panes == [c, b])
    }

    @Test func closedChildrenLoseTheirOpener() {
        let store = makeStore()
        let a = store.open(url("a"))
        let child = store.open(url("c"), opener: a, inBackground: true)
        store.close(a)
        #expect(store.tabs[child]?.openerID == nil)
    }

    // MARK: Recently closed

    @Test func discardLeavesNothingToReopen() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a"))
        let empty = store.open()
        store.select(a)
        store.discard(empty)
        #expect(store.windows[0].tabIDs == [a])
        #expect(store.recentlyClosed.isEmpty)
        #expect(store.selectedTabID(in: window) == a)
        #expect(persistence.lastSession?.tabs.map(\.id) == [a])
        // Left on the start page: nothing takes the pane.
        let other = store.open()
        store.discard(other, refillingPane: false)
        #expect(store.selectedTabID(in: window) == nil)
        #expect(store.windows[0].tabIDs == [a])
    }

    @Test func reopenClosedBringsBackExactlyThatBatch() {
        let store = makeStore()
        let a = store.open(url("a")), b = store.open(url("b")), c = store.open(url("c"))
        store.close(a)
        let first = store.recentlyClosed.last!.id
        store.close(b)
        #expect(store.reopenClosed(first) == [a])
        #expect(store.recentlyClosed.count == 1)
        #expect(store.reopenClosed(first).isEmpty, "a batch comes back once")
        #expect(store.windows[0].tabIDs == [a, c])
    }

    @Test func reopenRestoresPositionAndSelection() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a")), b = store.open(url("b")), c = store.open(url("c"))
        store.select(b)
        store.close(b)
        #expect(store.windows[0].tabIDs == [a, c])
        #expect(store.reopenLastClosed() == [b])
        #expect(store.windows[0].tabIDs == [a, b, c])
        #expect(store.selectedTabID(in: window) == b)
        #expect(store.recentlyClosed.isEmpty)
    }

    @Test func reopenFallsBackToTheOldIndexWhenThePreviousTabIsGone() async {
        let store = makeStore()
        let a = store.open(url("a")), b = store.open(url("b")), c = store.open(url("c")), d = store.open(url("d"))
        clock.advance(2 * 86_400)
        store.select(a)
        store.close(c)
        #expect(await store.archiveIdleTabs(after: .oneDay) == [b], "c's predecessor leaves")
        #expect(store.reopenLastClosed() == [c])
        #expect(store.windows[0].tabIDs == [a, d, c])
    }

    @Test func reopeningAClosedSplitBringsBothPanesBack() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a")), b = store.open(url("b"))
        store.open(url("c"))
        store.select(a)
        store.split(window, showing: b)
        store.focusPane(0, in: window)
        store.close([a, b])
        #expect(Set(store.reopenLastClosed()) == [a, b])
        #expect(store.windows[0].panes == [a, b])
        #expect(store.windows[0].focusedPane == 0)
    }

    @Test func aReopenedBatchKeepsOpenersInsideIt() {
        let store = makeStore()
        let a = store.open(url("a"))
        let child = store.open(url("c"), opener: a, inBackground: true)
        store.move(child, to: 0)
        store.close([child, a])
        store.reopenLastClosed()
        #expect(store.windows[0].tabIDs == [child, a])
        #expect(store.tabs[child]?.openerID == a)
    }

    @Test func recentlyClosedIsCapped() {
        let store = makeStore()
        for index in 0 ..< FixedChoices.recentlyClosedLimit + 5 {
            store.close(store.open(url("t\(index)")))
        }
        #expect(store.recentlyClosed.count == FixedChoices.recentlyClosedLimit)
        #expect(store.recentlyClosed.last?.tabs.first?.entry.url == url("t\(FixedChoices.recentlyClosedLimit + 4)"))
    }

    @Test func privateTabsNeverEnterRecentlyClosed() {
        let store = makeStore()
        store.close(store.open(url("p"), isPrivate: true))
        #expect(store.recentlyClosed.isEmpty)
    }

    // MARK: Close All Tabs

    @Test func closeAllKeepsPinnedTabsAndReopensAsOneBatch() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a")), b = store.open(url("b")), c = store.open(url("c"))
        store.setPinned(true, for: c)
        #expect(store.windows[0].tabIDs == [c, a, b])
        store.select(b)
        store.closeAllTabs(in: window)
        #expect(store.windows[0].tabIDs == [c])
        #expect(store.selectedTabID(in: window) == nil, "Close All shows the start page")
        #expect(store.recentlyClosed.count == 1)
        #expect(Set(store.reopenLastClosed()) == [a, b])
        #expect(store.windows[0].tabIDs == [c, a, b])
        #expect(store.selectedTabID(in: window) == b)
    }

    @Test func closeAllPrivateLeavesRegularTabs() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a"))
        store.open(url("p1"), isPrivate: true)
        store.open(url("p2"), isPrivate: true)
        store.closeAllTabs(in: window, private: true)
        #expect(store.windows[0].privateTabIDs.isEmpty)
        #expect(store.windows[0].tabIDs == [a])
        #expect(store.recentlyClosed.isEmpty)
    }

    // MARK: Order and pins

    @Test func moveKeepsPinnedTabsFirst() {
        let store = makeStore()
        let a = store.open(url("a")), b = store.open(url("b")), c = store.open(url("c"))
        store.setPinned(true, for: a)
        store.move(c, to: 0)
        #expect(store.windows[0].tabIDs == [a, c, b], "an unpinned tab can't pass a pinned one")
        store.move(a, to: 2)
        #expect(store.windows[0].tabIDs == [a, c, b], "a pinned tab can't leave the pinned group")
        store.move(b, to: 1)
        #expect(store.windows[0].tabIDs == [a, b, c])
        store.setPinned(false, for: a)
        #expect(store.windows[0].tabIDs == [a, b, c])
        store.setPinned(true, for: c)
        #expect(store.windows[0].tabIDs == [c, a, b])
    }

    // MARK: Panes

    @Test func splitMovesAShownTabAndRefillsTheFirstPane() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a")), b = store.open(url("b"))
        store.split(window, showing: b)
        #expect(store.windows[0].panes == [a, b])
        #expect(store.windows[0].focusedPane == 1)
        store.split(window, showing: a)
        #expect(store.windows[0].panes.count == 2, "at most two panes")
    }

    @Test func splittingAShownPrivateTabRefillsFromPrivateTabs() {
        let store = makeStore()
        let window = store.windows[0].id
        store.open(url("regular"), inBackground: true)
        let p1 = store.open(url("p1"), isPrivate: true)
        let p2 = store.open(url("p2"), isPrivate: true)
        store.split(window, showing: p2)
        #expect(store.windows[0].panes == [p1, p2])
    }

    @Test func selectingATabInTheOtherPaneSwapsPanes() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a")), b = store.open(url("b"))
        store.split(window, showing: b)
        store.focusPane(0, in: window)
        #expect(store.selectedTabID(in: window) == a)
        store.select(b, pane: 0)
        #expect(store.windows[0].panes == [b, a])
        store.select(b)
        #expect(store.windows[0].focusedPane == 0)
        store.swapPanes(in: window)
        #expect(store.windows[0].panes == [a, b])
        #expect(store.windows[0].focusedPane == 1)
        store.closePane(0, in: window)
        #expect(store.windows[0].panes == [b])
        #expect(store.tabs[a] != nil, "closing a pane keeps its tab")
    }

    @Test func persistedPanesNeverNamePrivateTabs() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a"))
        let p = store.open(url("p"), isPrivate: true)
        store.split(window, showing: nil)
        store.select(a)
        #expect(store.windows[0].panes == [p, a])
        let session = store.session
        #expect(session.windows[0].panes == [nil, a])
        #expect(session.tabs.map(\.id) == [a])
    }

    // MARK: Archive

    @Test func archiveMovesOnlyIdleTabsThatAreFreeToGo() async {
        let store = makeStore()
        let window = store.windows[0].id
        let idle = store.open(url("idle"), inBackground: true)
        let pinned = store.open(url("pinned"), inBackground: true)
        store.setPinned(true, for: pinned)
        let busy = store.open(url("media"), inBackground: true)
        let privateTab = store.open(url("private"), inBackground: true, isPrivate: true)
        let shown = store.open(url("shown"))
        clock.advance(ArchiveAfter.oneDay.interval! + 1)
        let fresh = store.open(url("fresh"), inBackground: true)
        store.isTabInUse = { $0 == busy }

        #expect(await store.archiveIdleTabs(after: .never).isEmpty)
        let archived = await store.archiveIdleTabs(after: .oneDay)
        #expect(archived == [idle])
        #expect(store.tabs[idle] == nil)
        #expect(Set(store.windows[0].tabIDs) == [pinned, busy, shown, fresh])
        #expect(store.windows[0].privateTabIDs == [privateTab])
        #expect(store.selectedTabID(in: window) == shown)
        guard case .archive(let entries, let date) = persistence.recorded.first(where: {
            if case .archive = $0 { true } else { false }
        }) else {
            Issue.record("no archive change")
            return
        }
        #expect(entries.map(\.id) == [idle])
        #expect(date == clock.now)
    }

    @Test func archiveIntervalsFollowTheSetting() async {
        let store = makeStore()
        let tab = store.open(url("a"), inBackground: true)
        clock.advance(13 * 3600)
        #expect(await store.archiveIdleTabs(after: .oneDay).isEmpty)
        #expect(await store.archiveIdleTabs(after: .oneWeek).isEmpty)
        #expect(await store.archiveIdleTabs(after: .twelveHours) == [tab])
    }

    @Test func restoringAnArchivedTabOpensAndShowsIt() async {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a"))
        let entry = TabEntry(url: url("old"), title: "Old", createdAt: clock.now.addingTimeInterval(-9_999))
        clock.advance(60)
        let restored = store.restoreArchived(entry)
        #expect(restored == entry.id)
        #expect(store.windows[0].tabIDs == [a, entry.id])
        #expect(store.selectedTabID(in: window) == entry.id)
        #expect(store.tabs[entry.id]?.lastActiveAt == clock.now, "restoring counts as opening")
        #expect(store.tabs[entry.id]?.title == "Old")
    }

    @Test func deletingArchivedTabsGoesToPersistence() {
        let store = makeStore()
        let id = TabID()
        store.deleteArchived([id])
        store.clearArchive()
        #expect(persistence.recorded == [.deleteArchived([id]), .deleteArchived(nil)])
    }

    // MARK: Pages, thumbnails, persistence

    @Test func pageAndThumbnailUpdatesArePersistedOnlyWhenChanged() {
        let store = makeStore()
        let a = store.open(url("a"))
        let before = persistence.recorded.count
        store.updatePage(a, url: url("a"), title: nil)
        #expect(persistence.recorded.count == before)
        store.updatePage(a, url: url("a2"), title: "A2")
        store.setThumbnail(TabThumbnail(fileName: "\(a.uuidString).jpg", revision: 1), for: a)
        #expect(persistence.recorded.count == before + 2)
        #expect(persistence.lastSession?.tabs.first?.title == "A2")
        #expect(persistence.lastSession?.tabs.first?.thumbnail?.revision == 1)
    }

    @Test func privateTabChangesNeverReachPersistence() {
        let store = makeStore()
        let p = store.open(url("p"), inBackground: true, isPrivate: true)
        store.updatePage(p, url: url("secret"), title: "Secret")
        store.move(p, to: 0)
        #expect(persistence.recorded.allSatisfy { change in
            guard case .session(let session) = change else { return true }
            return session.tabs.isEmpty
        })
        #expect(persistence.recorded.isEmpty)
    }

    // MARK: Restoring a session

    @Test func initNormalizesAStoredSession() {
        let window = WindowID()
        let a = TabEntry(createdAt: clock.now), b = TabEntry(isPinned: true, createdAt: clock.now)
        let stray = TabEntry(createdAt: clock.now)
        let session = TabSession(
            windows: [WindowSession(id: window, tabIDs: [a.id, b.id, TabID()], panes: [a.id, a.id, b.id], focusedPane: 7)],
            tabs: [a, b, stray]
        )
        let store = makeStore(session)
        #expect(store.windows.count == 1)
        #expect(store.windows[0].tabIDs == [b.id, a.id, stray.id], "pinned first; unknown ids dropped; strays join")
        #expect(store.windows[0].panes == [a.id, nil], "two panes at most, never one tab twice")
        #expect(store.windows[0].focusedPane == 1)
        #expect(persistence.recorded.isEmpty, "loading writes nothing")
    }

    // MARK: Windows

    @Test func closingAWindowIsOneBatchAndReopensIntoAnotherWindow() {
        let store = makeStore()
        let first = store.windows[0].id
        let second = store.addWindow()
        let a = store.open(url("a"), in: second)
        let b = store.open(url("b"), in: second)
        store.open(url("p"), in: second, isPrivate: true)
        store.closeWindow(second)
        #expect(store.windows.map(\.id) == [first])
        #expect(store.tabs.isEmpty)
        #expect(store.reopenLastClosed() == [a, b])
        #expect(store.windows[0].tabIDs == [a, b])
        #expect(store.windowID(of: a) == first)
    }

    @Test func reopenPrefersTheWindowsOwnCloseAndUsesItForAGoneWindow() {
        let store = makeStore()
        let first = store.windows[0].id
        let second = store.addWindow()
        let a = store.open(url("a"), in: first)
        let b = store.open(url("b"), in: second)
        store.close(a)
        store.close(b)
        // The first window's own close, though b's is newer.
        #expect(store.reopenLastClosed(window: first) == [a])
        #expect(store.windowID(of: a) == first)
        let third = store.addWindow()
        let c = store.open(url("c"), in: third)
        store.closeWindow(third)
        // c's window is gone: it comes back in the window that asked.
        #expect(store.reopenLastClosed(window: first) == [c], "the first window closed nothing left: the newest batch")
        #expect(store.windowID(of: c) == first)
    }

    @Test func addWindowKeepsAnExistingIDAndMergeMovesEveryTab() {
        let store = makeStore()
        let first = store.windows[0].id
        let second = WindowID()
        #expect(store.addWindow(id: second) == second)
        #expect(store.addWindow(id: second) == second)
        #expect(store.windows.count == 2)
        let a = store.open(url("a"), in: first)
        let b = store.open(url("b"), in: second)
        let p = store.open(url("p"), in: second, isPrivate: true)
        store.setPinned(true, for: b)
        store.mergeWindow(second, into: first)
        #expect(store.windows.map(\.id) == [first])
        #expect(store.windows[0].tabIDs == [b, a], "a pinned tab stays first")
        #expect(store.windows[0].privateTabIDs == [p])
        #expect(store.windowID(of: b) == first)
        #expect(store.windows[0].panes == [a], "the target's panes stay")
        store.mergeWindow(first, into: first)
        #expect(store.windows.count == 1)
    }

    @Test func aClosedSplitWindowReopensSplit() {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a")), b = store.open(url("b"))
        store.split(window, showing: b)
        store.closeWindow(window)
        #expect(store.windows[0].panes == [nil])
        store.reopenLastClosed()
        #expect(store.windows[0].panes == [a, b])
        #expect(store.windows[0].focusedPane == 1)
    }

    @Test func restoringFromTheArchiveTellsPersistence() {
        let store = makeStore()
        let entry = TabEntry(createdAt: clock.now)
        store.restoreArchived(entry, inBackground: true)
        #expect(persistence.recorded.contains(.unarchive([entry.id])))
    }

    @Test func theLastWindowIsEmptiedNotRemoved() {
        let store = makeStore()
        let window = store.windows[0].id
        store.open(url("a"))
        store.closeWindow(window)
        #expect(store.windows.map(\.id) == [window])
        #expect(store.windows[0].tabIDs.isEmpty)
    }
}

