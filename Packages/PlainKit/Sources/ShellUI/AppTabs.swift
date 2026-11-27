#if canImport(UIKit)
import BrowserCore
import Foundation
import Storage

/// The app's tabs across all its windows (per-window browser state, docs/plan.md, section 6): one
/// `TabStore` for every scene, so two windows never save over each other's tabs. Each scene's
/// `EngineTabs` acts on its own window in it; the web views stay with each window's pool.
///
/// The saved session is read once, off the main thread, by the first window that asks
/// (`load()`). A window that connects before that works on a store in memory; its tabs join the
/// saved window it maps to once the session is in.
///
/// Which window a scene shows (`claim`):
/// - its saved window, when the store has it and no other scene shows it;
/// - with no saved window (the system made the scene new): the first window no scene shows, when
///   it is the only scene (the app's first window after an update or a lost scene), else a new
///   empty window ("Open in New Window");
/// - a saved window the store no longer has: a new window with that id.
/// Windows no open scene names any more (their scene was discarded while the app was not running)
/// join the first scene's window, so no tab is left where no window shows it.
public final class AppTabs {
    public private(set) var store: TabStore
    private let database: DatabaseProvider
    private var loading: Task<Void, Never>?
    /// The saved session is in the store.
    private(set) var isLoaded = false
    /// Windows a connected scene shows.
    private var claimed: Set<WindowID> = []
    /// Windows claimed before the load without a saved id: each takes a saved window at load.
    private var unbound: [WindowID] = []
    /// A window claimed before the load that became a saved one.
    private var remapped: [WindowID: WindowID] = [:]
    /// Windows that had tabs opened in them before the load: their own tabs stay on screen.
    private var openedBeforeLoad: Set<WindowID> = []
    /// Windows whose scene the system discarded before the load: closed once it is in.
    private var discardedBeforeLoad: Set<WindowID> = []
    private var engines: [WeakEngine] = []
    /// The window ids every open scene session names (`UIApplication.openSessions`, through
    /// `SceneState`); windows outside it are orphans. Nil: none are.
    public var sessionWindowIDs: (() -> Set<WindowID>)?

    public init(database: @escaping DatabaseProvider) {
        self.database = database
        store = TabStore(session: TabSession(windows: []))
        // A fresh store has one empty window no scene asked for; claims replace it.
        unclaimedPlaceholder = store.windows.first?.id
        wireStore()
    }

    /// The empty window a fresh in-memory store starts with, until a scene claims its own.
    private var unclaimedPlaceholder: WindowID?

    // MARK: Windows

    /// The window a connecting scene shows, given the window it showed last time. `isNew`: the
    /// scene was asked for as a new window ("Open in New Window"), which never takes a saved one.
    func claim(saved: WindowID?, isNew: Bool = false) -> WindowID {
        let id: WindowID
        if !isLoaded {
            id = saved ?? WindowID()
            store.addWindow(id: id)
            if saved == nil, !isNew { unbound.append(id) }
            dropPlaceholder(keeping: id)
        } else if let saved, store.window(saved) != nil, !claimed.contains(saved) {
            id = saved
        } else if saved == nil, !isNew, claimed.isEmpty, let first = firstFreeWindow() {
            id = first
        } else {
            id = store.addWindow(id: saved.flatMap { claimed.contains($0) ? nil : $0 } ?? WindowID())
        }
        claimed.insert(id)
        if isLoaded { adoptOrphans(into: id) }
        return id
    }

    /// The first window no scene shows and no other open scene session names (that session will
    /// come back to it).
    private func firstFreeWindow(in windows: [WindowID]? = nil) -> WindowID? {
        let named = sessionWindowIDs?() ?? []
        return (windows ?? store.windows.map(\.id)).first { !claimed.contains($0) && !named.contains($0) }
    }

    /// The scene left (disconnected); its window stays for when it comes back.
    func release(_ window: WindowID) {
        claimed.remove(resolved(window))
    }

    /// The system discarded these windows' scenes: the user closed them for good, or removed the
    /// app from the app switcher. While another window remains, their tabs become a recently
    /// closed batch each, as a closed Safari window's do. When none would remain (the app was
    /// swiped away), they stay: the next scene takes the first and the rest join it, so quitting
    /// the app never closes tabs.
    public func discard(_ windows: [WindowID]) {
        guard isLoaded else {
            discardedBeforeLoad.formUnion(windows)
            return
        }
        closeDiscarded(Set(windows.map(resolved)))
    }

    private func closeDiscarded(_ windows: Set<WindowID>) {
        let named = sessionWindowIDs?() ?? []
        let remaining = claimed.union(named).subtracting(windows)
        guard !remaining.isEmpty else { return }
        var changed = false
        for window in windows where !claimed.contains(window) && store.window(window) != nil {
            store.closeWindow(window)
            changed = true
        }
        if changed { didChange(from: nil) }
    }

    /// The window `window` became at load (a scene that connected before it).
    func resolved(_ window: WindowID) -> WindowID {
        remapped[window] ?? window
    }

    /// Whether `window` had tabs opened in it before the saved session was in.
    func hadTabsBeforeLoad(_ window: WindowID) -> Bool {
        openedBeforeLoad.contains(resolved(window))
    }

    /// The windows connected scenes show, in the store's order.
    var claimedWindows: [WindowID] {
        store.windows.map(\.id).filter(claimed.contains)
    }

    // MARK: Loading

    /// Reads the saved session once, off the main thread, and puts it in the store with every tab
    /// opened meanwhile. Later calls wait for the first.
    func load() async {
        if let loading { return await loading.value }
        let task = Task { await performLoad() }
        loading = task
        await task.value
    }

    private func performLoad() async {
        guard let database = await database() else { return }
        let saved = (try? await database.loadTabSession()) ?? .empty
        let current = store
        var session = saved
        var remapped: [WindowID: WindowID] = [:]
        // Windows another open scene session names wait for that session.
        var taken = sessionWindowIDs?() ?? []
        // Windows that connected with a saved id keep theirs.
        for window in current.windows where session.windows.contains(where: { $0.id == window.id }) {
            taken.insert(window.id)
        }
        for window in current.windows {
            let hasTabs = !current.tabs(in: window.id).isEmpty
            var target = session.windows.firstIndex { $0.id == window.id }
            if target == nil, unbound.contains(window.id) {
                // A new scene takes the first saved window no other scene has.
                target = session.windows.firstIndex { !taken.contains($0.id) }
            }
            if let target {
                let id = session.windows[target].id
                taken.insert(id)
                if id != window.id { remapped[window.id] = id }
                if hasTabs {
                    // The user's tabs join the saved window and stay on screen.
                    session.windows[target].tabIDs += window.tabIDs
                    session.windows[target].panes = window.panes
                    session.windows[target].focusedPane = window.focusedPane
                    openedBeforeLoad.insert(id)
                }
            } else {
                session.windows.append(WindowSession(
                    id: window.id, tabIDs: window.tabIDs, panes: window.panes, focusedPane: window.focusedPane
                ))
                if hasTabs { openedBeforeLoad.insert(window.id) }
            }
        }
        session.tabs += current.session.tabs
        self.remapped = remapped
        claimed = Set(claimed.map { remapped[$0] ?? $0 })
        let loaded = TabStore(session: session, persistence: database.tabSession)
        store = loaded
        wireStore()
        // Empty tabs are never left behind: a blank saved tab (an older build kept them) goes.
        for entry in saved.tabs where entry.url == nil { loaded.discard(entry.id) }
        // Private tabs opened before the session loaded stay (the store never saves them).
        for window in current.windows {
            let target = remapped[window.id] ?? window.id
            for entry in current.tabs(in: window.id, private: true) {
                loaded.open(entry.url, title: entry.title, in: target, isPrivate: true, id: entry.id)
            }
            if let id = current.selectedTabID(in: window.id), current.tabs[id]?.isPrivate == true {
                loaded.select(id)
            }
        }
        isLoaded = true
        unbound = []
        if !discardedBeforeLoad.isEmpty {
            let discarded = discardedBeforeLoad
            discardedBeforeLoad = []
            closeDiscarded(discarded)
        }
        if let first = claimedWindows.first { adoptOrphans(into: first) }
    }

    /// Windows no open scene names and no scene shows join `target`.
    private func adoptOrphans(into target: WindowID) {
        guard let named = sessionWindowIDs?() else { return }
        for window in store.windows.map(\.id) where window != target && !claimed.contains(window) && !named.contains(window) {
            store.mergeWindow(window, into: target)
        }
    }

    private func dropPlaceholder(keeping id: WindowID) {
        guard let placeholder = unclaimedPlaceholder, placeholder != id else { return }
        unclaimedPlaceholder = nil
        if store.tabs(in: placeholder).isEmpty, store.tabs(in: placeholder, private: true).isEmpty {
            store.mergeWindow(placeholder, into: id)
        }
    }

    // MARK: Engines

    /// `engine` shows a window: it hears about changes other windows make (`didChange`).
    func register(_ engine: EngineTabs) {
        engines.removeAll { $0.engine == nil }
        engines.append(WeakEngine(engine: engine))
    }

    /// The store changed in a way that may reach other windows (archive, reopen, a window closed):
    /// every other window drops engine tabs that left the store and refreshes its lists.
    func didChange(from source: EngineTabs?) {
        for box in engines {
            guard let engine = box.engine, engine !== source else { continue }
            engine.storeChangedElsewhere()
        }
    }

    /// "Must this tab stay open?": any window's engine tab that is busy (media, downloads).
    private func wireStore() {
        store.isTabInUse = { [weak self] id in
            self?.engines.contains { $0.engine?.isBusy(id) == true } ?? false
        }
    }

    private struct WeakEngine {
        weak var engine: EngineTabs?
    }
}
#endif
