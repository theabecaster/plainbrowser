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
    /// The app's tabs in every window (`AppTabs`): one store for all scenes.
    let app: AppTabs
    var store: TabStore { app.store }
    /// The window this scene shows (per-window state, docs/plan.md, section 6): every read and
    /// change here acts on it. The scene keeps it across launches.
    private(set) var windowID: WindowID
    /// Tabs the bar swipe and Next/Previous Tab skip: the other pane's tab while a split shows.
    var excludedFromNeighbours: Set<TabID> = []
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
    /// The saved profile list was read (not a failed read standing in as empty), so data of
    /// profiles missing from it really belongs to deleted ones (`AppTabs`).
    var areProfilesKnown: Bool { app.areProfilesKnown }
    /// The archive holds at least one tab (read off the main thread; `refreshArchiveState()`).
    private(set) var hasArchivedTabs = false

    /// - Parameter windowID: the window the scene showed last time, when it has one (`AppTabs`
    ///   decides which window the scene shows).
    init(
        pool: WebViewPool, app: AppTabs, database: @escaping DatabaseProvider, tabStates: TabStateStore?,
        windowID: WindowID? = nil, isNewWindow: Bool = false
    ) {
        self.pool = pool
        self.app = app
        self.database = database
        self.tabStates = tabStates
        self.windowID = app.claim(saved: windowID, isNew: isNewWindow)
        app.register(self)
    }

    /// The scene went away; its window stays in the store for when it comes back.
    func releaseWindow() {
        app.release(windowID)
    }

    /// Whether this window's engine tab `id` must stay open (media, a download).
    func isBusy(_ id: TabID) -> Bool {
        engineTabs[id]?.isBusy ?? false
    }

    /// Another window changed the store (archive, reopen, a closed window): engine tabs whose tab
    /// left it go, and the lists reload.
    func storeChangedElsewhere() {
        for id in engineTabs.keys where store.tabs[id] == nil { drop(id) }
        checkProfile()
        scheduleChange()
    }

    private var window: WindowID { windowID }

    /// What the window's panes show (one, or two in a split) and which one is focused.
    var panes: [TabID?] { store.window(windowID)?.panes ?? [nil] }
    var focusedPane: Int { store.window(windowID)?.focusedPane ?? 0 }

    // MARK: Reading

    /// The id of the tab the focused pane shows.
    var selectedID: TabID? {
        store.selectedTabID(in: window)
    }

    /// The tab the focused pane shows.
    var selected: Tab? {
        selectedID.map(tab)
    }

    /// The window's tabs in order: one profile's regular tabs (the window's unless `profile` names
    /// another), or the private ones.
    func entries(private isPrivate: Bool, profile: ProfileID? = nil) -> [TabEntry] {
        store.tabs(in: window, private: isPrivate, profile: profile)
    }

    // MARK: Profiles

    /// Every profile, Personal first.
    var profiles: [Profile] { store.profiles }

    /// The window's profile: the tab on screen's, or the last one shown.
    var activeProfile: ProfileID { store.profileID(of: window) }

    /// Page tabs of the window's other profiles: the switcher can reach them.
    var otherProfilesTabCount: Int {
        guard profiles.count > 1, let window = store.window(windowID) else { return 0 }
        let active = activeProfile
        return window.tabIDs.count { id in store.tabs[id].map { $0.profileID != active } == true && !isEmpty(id) }
    }

    /// The other profile whose page tab was on screen last; nil when no other profile has one.
    var profileWithLatestTab: ProfileID? {
        guard profiles.count > 1, let window = store.window(windowID) else { return nil }
        let active = activeProfile
        return window.tabIDs.compactMap { store.tabs[$0] }
            .filter { $0.profileID != active && !isEmpty($0.id) }
            .max { $0.lastActiveAt < $1.lastActiveAt }?.profileID
    }

    /// Called once per main run loop turn after the window's profile changed (a tab of another
    /// profile was shown, or the profile was deleted): the shell switches history, favorites and
    /// the archive to it.
    var onProfileChange: ((ProfileID) -> Void)?
    private var reportedProfile = Profile.defaultID

    @discardableResult
    func addProfile(named name: String) -> ProfileID? {
        let id = store.addProfile(named: name)
        scheduleChange()
        return id
    }

    @discardableResult
    func renameProfile(_ id: ProfileID, to name: String) -> Bool {
        defer { scheduleChange() }
        return store.renameProfile(id, to: name)
    }

    /// Deletes a profile: its tabs close for good (state files and thumbnails too), its archive
    /// and recently closed tabs go, and its website data store is let go. The caller removes the
    /// store's data and the profile's history database.
    func deleteProfile(_ id: ProfileID) {
        Signposts.signposter.emitEvent(Signposts.profileDelete)
        for tab in store.deleteProfile(id) {
            watches.removeValue(forKey: tab)?.cancel()
            if let engineTab = engineTabs.removeValue(forKey: tab) {
                pool.close(engineTab, keepingSavedState: false)
            }
        }
        pool.forgetProfile(id)
        checkProfile()
        refreshArchiveState()
        scheduleChange()
        // The profile's tabs in other windows went too: they let go of its web views and store.
        app.profileDeleted(id, from: self)
    }

    /// Another window deleted `profile`: its engine tabs here close for good, the pool lets go of
    /// its website data store, and the window moves to another profile if it showed that one.
    func profileDeletedElsewhere(_ profile: ProfileID) {
        for (id, tab) in engineTabs where store.tabs[id] == nil {
            watches.removeValue(forKey: id)?.cancel()
            engineTabs[id] = nil
            pool.close(tab, keepingSavedState: false)
        }
        pool.forgetProfile(profile)
        checkProfile()
        refreshArchiveState()
        scheduleChange()
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
        let list = entries(private: entry.isPrivate, profile: entry.profileID).map(\.id)
            .filter { $0 == id || !excludedFromNeighbours.contains($0) }
        guard let index = list.firstIndex(of: id) else { return (nil, nil) }
        return (index > 0 ? list[index - 1] : nil, index + 1 < list.count ? list[index + 1] : nil)
    }

    /// Reopen Closed Tab has a close of the window's profile to bring back.
    var canReopenClosedTab: Bool { store.lastClosedBatch(in: activeProfile) != nil }

    /// The newest batch on the recently closed stack: what a Reopen offer made right after a close
    /// brings back.
    var lastClosedBatchID: UUID? { store.recentlyClosed.last?.id }

    // MARK: Empty tabs (docs/state-rules.md, principle 7)

    /// A tab with nothing in it: no address, not loading, no failed load. An empty tab never counts
    /// as a tab: it is not a card, a neighbour or one of the "others".
    func isEmpty(_ id: TabID) -> Bool {
        if let tab = engineTabs[id] { return tab.url == nil && !tab.isLoading && tab.loadError == nil }
        return store.tabs[id]?.url == nil
    }

    /// The window's tabs in order, regular (of `profile`, else the window's) or private, without
    /// empty tabs: the gallery's cards.
    func pageEntries(private isPrivate: Bool, profile: ProfileID? = nil) -> [TabEntry] {
        entries(private: isPrivate, profile: profile).filter { !isEmpty($0.id) }
    }

    /// Open tabs besides `id`, regular and private together, empty tabs left out (the rules'
    /// `others`).
    func otherTabCount(besides id: TabID?) -> Int {
        var count = 0
        for isPrivate in [false, true] {
            for entry in entries(private: isPrivate) where entry.id != id && !isEmpty(entry.id) { count += 1 }
        }
        return count
    }

    /// The tab of a list the user saw last, empty tabs left out.
    func mostRecent(private isPrivate: Bool) -> TabID? {
        pageEntries(private: isPrivate).max { $0.lastActiveAt < $1.lastActiveAt }?.id
    }

    /// The engine tab for a store id, made on first use from what the store knows. A tab with an
    /// address reads its state file when it first gets a web view.
    func tab(_ id: TabID) -> Tab {
        if let tab = engineTabs[id] { return tab }
        let entry = store.tabs[id]
        let tab: Tab
        let profile = entry?.profileID ?? activeProfile
        if let entry, entry.isPrivate {
            tab = pool.makeTab(id: id, isPrivate: true, profile: profile)
        } else if let url = entry?.url {
            tab = pool.makeSavedTab(id: id, url: url, title: entry?.title ?? "", profile: profile)
        } else {
            tab = pool.makeTab(id: id, profile: profile)
        }
        adopt(tab)
        return tab
    }

    // MARK: Changing

    /// A new tab at the end of its list (or after `opener`), shown in the focused pane unless
    /// `inBackground`, in the opener's profile, else `profile`, else the window's. It has no web
    /// view until it is shown or loads something.
    @discardableResult
    func newTab(
        url: URL? = nil, isPrivate: Bool = false, opener: Tab? = nil, inBackground: Bool = false, profile: ProfileID? = nil
    ) -> Tab {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabOpen, id: signposter.makeSignpostID(), "\(inBackground ? "background" : "shown")")
        defer { signposter.endInterval(Signposts.tabOpen, interval) }
        let id = store.open(
            url, in: window, opener: opener?.id, inBackground: inBackground, isPrivate: isPrivate || opener?.isPrivate == true,
            profile: profile
        )
        checkProfile()
        return tab(id)
    }

    /// A tab the pool made for a popup: opened next to its opener and shown.
    func add(_ child: Tab, after opener: Tab) {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabOpen, id: signposter.makeSignpostID(), "popup")
        defer { signposter.endInterval(Signposts.tabOpen, interval) }
        adopt(child)
        store.open(child.url, in: window, opener: opener.id, isPrivate: child.isPrivate, id: child.id)
        checkProfile()
    }

    func select(_ tab: Tab) {
        guard store.selectedTabID(in: window) != tab.id else { return }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabSelect, id: signposter.makeSignpostID())
        defer { signposter.endInterval(Signposts.tabSelect, interval) }
        store.select(tab.id)
        checkProfile()
    }

    // MARK: Panes

    /// Shows `id` in `pane` (a tab already in the other pane trades places), focusing that pane.
    func show(_ id: TabID, inPane pane: Int) {
        store.select(id, pane: pane)
        checkProfile()
    }

    /// Splits the window, `id` in the new pane, focused; the first pane keeps a tab of its own
    /// (TabStore's rule). No-op when already split.
    func split(showing id: TabID?) {
        store.split(window, showing: id)
        checkProfile()
    }

    /// Closes `pane`; its tab stays open. The other pane is focused.
    func closePane(_ pane: Int, touching: Bool = true) {
        store.closePane(pane, in: window, touching: touching)
        checkProfile()
    }

    func focusPane(_ pane: Int) {
        store.focusPane(pane, in: window)
        checkProfile()
    }

    func swapPanes() {
        store.swapPanes(in: window)
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

    /// Removes an empty tab the user left, with no Reopen (docs/state-rules.md, principle 7).
    func discard(_ id: TabID, refillingPane: Bool = true) {
        let wasPrivate = store.tabs[id]?.isPrivate == true
        store.discard(id, refillingPane: refillingPane)
        drop(id)
        if wasPrivate { endPrivateSessionIfEmpty() }
    }

    /// Close All Tabs: every regular tab except pinned ones, or every private tab, as one batch that
    /// Reopen Closed Tab brings back (private tabs never come back).
    func closeAll(private isPrivate: Bool, profile: ProfileID? = nil) {
        Signposts.signposter.emitEvent(Signposts.tabCloseAll, "\(isPrivate ? "private" : "regular")")
        let before = Set(entries(private: isPrivate, profile: profile).map(\.id))
        store.closeAllTabs(in: window, private: isPrivate, profile: profile)
        let after = Set(entries(private: isPrivate, profile: profile).map(\.id))
        for id in before.subtracting(after) { drop(id) }
        if isPrivate { endPrivateSessionIfEmpty() }
    }

    /// Reopens the window's profile's last closed batch, the one closed in this window first;
    /// the store shows it, and tabs of a window that is gone come back here. Returns its ids.
    @discardableResult
    func reopenLastClosed() -> [TabID] {
        Signposts.signposter.emitEvent(Signposts.tabReopen)
        defer {
            checkProfile()
            app.didChange(from: self)
        }
        return store.reopenLastClosed(in: activeProfile, window: window)
    }

    /// Reopens exactly the batch a Reopen offer was made for; nothing if it is gone.
    @discardableResult
    func reopenClosed(_ batchID: UUID) -> [TabID] {
        Signposts.signposter.emitEvent(Signposts.tabReopen)
        defer {
            checkProfile()
            app.didChange(from: self)
        }
        return store.reopenClosed(batchID, fallbackWindow: window)
    }

    /// Moves `id` to `index` in its list as the gallery, strip and sidebar show it: empty tabs
    /// are left out there, so the store places it among the tabs shown.
    func move(_ id: TabID, to index: Int) {
        guard let entry = store.tabs[id] else { return }
        store.move(id, to: index, among: pageEntries(private: entry.isPrivate, profile: entry.profileID).map(\.id))
    }

    /// Brings an archived tab back at the end of the list and shows it.
    @discardableResult
    func restoreArchived(_ archived: ArchivedTab) -> Tab {
        Signposts.signposter.emitEvent(Signposts.tabUnarchive)
        defer {
            checkProfile()
            refreshArchiveState()
        }
        return tab(store.restoreArchived(archived.entry, in: window))
    }

    func deleteArchived(_ ids: [TabID]) {
        store.deleteArchived(ids)
        refreshArchiveState()
    }

    /// Reads whether the window's profile's archive holds anything, off the main thread (one
    /// count, after the pending tab writes), so Archived Tabs shows only when it leads somewhere.
    func refreshArchiveState() {
        let profile = activeProfile
        Task { [weak self, database] in
            guard let database = await database() else { return }
            let count = (try? await database.archivedTabCount(profile: profile)) ?? 0
            guard let self, activeProfile == profile, hasArchivedTabs != (count > 0) else { return }
            hasArchivedTabs = count > 0
            scheduleChange()
        }
    }

    /// Moves tabs not opened for `setting`'s interval to the archive (launch and each return to
    /// the foreground). WebKit is asked first whether hidden tabs play media, so a tab playing
    /// sound stays. Archived tabs keep their state file.
    func archiveIdleTabs(after setting: ArchiveAfter) async {
        guard isSessionLoaded else { return }
        // Tabs past their 30 days leave the archive first, whatever the setting.
        store.pruneArchive()
        guard setting.interval != nil else { return refreshArchiveState() }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabArchive, id: signposter.makeSignpostID())
        let visible = store.visibleTabIDs
        for (id, tab) in engineTabs where !visible.contains(id) && tab.tier != .discarded {
            await tab.refreshMediaState()
        }
        let archived = await store.archiveIdleTabs(after: setting)
        for id in archived { drop(id) }
        // The count reads after the prune and the archive are written.
        refreshArchiveState()
        // Other windows' idle tabs went too.
        if !archived.isEmpty { app.didChange(from: self) }
        signposter.endInterval(Signposts.tabArchive, interval, "\(archived.count)")
    }

    /// Writes what is waiting. Call when the app moves to the background.
    func flush() async {
        await store.flush()
    }

    /// Archived tabs past their 30 days leave the archive (written off the main thread).
    func pruneArchive() {
        guard isSessionLoaded else { return }
        store.pruneArchive()
    }

    /// Whether the database no longer lists `profile`: its deletion is written. A write that gave
    /// up (`TabSessionWriter` retries, then drops) leaves it listed, so its data must stay.
    func isProfileDeletionSaved(_ profile: ProfileID) async -> Bool {
        await store.flush()
        guard let database = await database(), let saved = try? await database.loadTabSession() else { return false }
        return !saved.profiles.contains { $0.id == profile }
    }

    // MARK: Restore

    /// Loads the saved session off the main thread and gives the store its persistence. Every
    /// saved tab is back in the list; none has a web view yet. Returns the selected tab (it reads
    /// its state file when shown), unless the user opened a page meanwhile.
    func restoreSession() async -> Tab? {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.launchRestoreTab)
        defer { signposter.endInterval(Signposts.launchRestoreTab, interval) }
        await app.load()
        guard app.isLoaded else { return nil }
        windowID = app.resolved(windowID)
        guard !isSessionLoaded else { return nil }
        isSessionLoaded = true
        checkProfile()
        refreshArchiveState()
        scheduleChange()
        guard !app.hadTabsBeforeLoad(windowID), let id = selectedID, store.tabs[id]?.url != nil else { return nil }
        return tab(id)
    }

    /// Deletes files no tab row names any more: state files left by a crash between two writes,
    /// and thumbnails of tabs gone for good. Off the main thread, after launch.
    func pruneFiles() async {
        guard let database = await database() else { return }
        // Only files older than this may go: a tab made from here on keeps its new files.
        let cutoff = Date()
        await store.flush()
        // Tabs in the store are kept even when their row is not written yet (a tab opened before
        // the session loaded is saved with the next change).
        let open = Set(store.tabs.keys)
        try? await database.removeOrphanedTabStates(alsoKeeping: open, writtenBefore: cutoff)
        guard let referenced = try? await database.referencedTabIDs() else { return }
        await pool.thumbnails.prune(keeping: referenced.union(open), writtenBefore: cutoff)
    }

    // MARK: Private

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

    /// Called when the last private tab closed, after the pool dropped the private session: the
    /// session's other private-only state (cookie banner choices) goes with it.
    var privateSessionDidEnd: (() -> Void)?

    private func endPrivateSessionIfEmpty() {
        guard entries(private: true).isEmpty else { return }
        pool.endPrivateSession()
        privateSessionDidEnd?()
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

    /// Tells the shell when the window's profile changed. Called after every change that shows a
    /// tab (only showing a tab, or deleting a profile, changes it), so it costs one comparison.
    private func checkProfile() {
        let profile = activeProfile
        guard profile != reportedProfile else { return }
        reportedProfile = profile
        refreshArchiveState()
        onProfileChange?(profile)
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
