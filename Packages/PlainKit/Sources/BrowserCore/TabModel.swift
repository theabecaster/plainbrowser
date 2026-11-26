import Foundation

/// A tab's identity. The same id names the tab everywhere: `TabStore`, the web engine's `Tab`,
/// its state file and its thumbnail.
public typealias TabID = UUID

/// A browser window (one scene). Each window has its own tabs and pane selection, so "Open in
/// New Window" can ship later without a rewrite (docs/plan.md, section 6).
public typealias WindowID = UUID

/// Where a tab's thumbnail lives. The web engine takes and stores the image; this is only the
/// metadata that survives a relaunch.
public struct TabThumbnail: Hashable, Sendable, Codable {
    /// File name inside the engine's thumbnail folder.
    public var fileName: String
    /// Bumped by each new capture, so a gallery cell can tell a stale image from a new one.
    public var revision: Int

    public init(fileName: String, revision: Int) {
        self.fileName = fileName
        self.revision = revision
    }
}

/// What `TabStore` knows about one tab. Page state (loading, back/forward, security) belongs to
/// the engine's `Tab`; the shell copies the URL and title here so they survive a relaunch and the
/// archive can be searched.
public struct TabEntry: Identifiable, Hashable, Sendable, Codable {
    public let id: TabID
    public var url: URL?
    public var title: String?
    /// The tab whose page (or link) opened this one. Kept while the opener is open.
    public var openerID: TabID?
    /// Pinned tabs sit first in their window and are never archived or closed by Close All Tabs.
    public var isPinned: Bool
    /// Private tabs live in their own list and are never written to disk.
    public let isPrivate: Bool
    public var createdAt: Date
    /// The last time the tab was on screen. Auto-archive counts from here.
    public var lastActiveAt: Date
    public var thumbnail: TabThumbnail?

    public init(
        id: TabID = TabID(), url: URL? = nil, title: String? = nil, openerID: TabID? = nil,
        isPinned: Bool = false, isPrivate: Bool = false, createdAt: Date, lastActiveAt: Date? = nil,
        thumbnail: TabThumbnail? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.openerID = openerID
        self.isPinned = isPinned
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt ?? createdAt
        self.thumbnail = thumbnail
    }
}

/// One window's tabs and what its panes show.
///
/// A window has one pane, or two in a split (the Duo's inner screen). Each pane shows one tab or
/// nothing (the start page). The focused pane is the one touched last; the shared bar buttons and
/// a plain `select` act on it.
public struct TabWindow: Identifiable, Hashable, Sendable {
    public let id: WindowID
    /// Regular tabs in order, pinned ones first.
    public internal(set) var tabIDs: [TabID]
    /// Private tabs in order. Never persisted.
    public internal(set) var privateTabIDs: [TabID]
    /// The tab each pane shows; nil shows the start page. One or two panes.
    public internal(set) var panes: [TabID?]
    public internal(set) var focusedPane: Int

    public init(id: WindowID = WindowID(), tabIDs: [TabID] = [], privateTabIDs: [TabID] = [], panes: [TabID?] = [nil], focusedPane: Int = 0) {
        self.id = id
        self.tabIDs = tabIDs
        self.privateTabIDs = privateTabIDs
        self.panes = panes.isEmpty ? [nil] : panes
        self.focusedPane = min(max(0, focusedPane), self.panes.count - 1)
    }

    /// The tab in the focused pane.
    public var selectedTabID: TabID? { panes[focusedPane] }
}

/// A tab as it was when closed, with enough to put it back where it was.
public struct ClosedTab: Hashable, Sendable, Codable {
    public var entry: TabEntry
    public var windowID: WindowID
    /// Its index in the window's list when it closed.
    public var index: Int
    /// The tab right before it then; reopening goes after it when it is still open.
    public var previousTabID: TabID?
    /// The pane it was shown in, if any; reopening shows it there again.
    public var pane: Int?
    /// Its pane was the focused one; reopening focuses it again.
    public var wasFocused: Bool

    public init(entry: TabEntry, windowID: WindowID, index: Int, previousTabID: TabID?, pane: Int? = nil, wasFocused: Bool = false) {
        self.entry = entry
        self.windowID = windowID
        self.index = index
        self.previousTabID = previousTabID
        self.pane = pane
        self.wasFocused = wasFocused
    }
}

/// Tabs closed by one action: a single close, Close All Tabs or a closed window. Reopen brings
/// back the whole batch.
public struct ClosedTabBatch: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var closedAt: Date
    /// In window order.
    public var tabs: [ClosedTab]

    public init(id: UUID = UUID(), closedAt: Date, tabs: [ClosedTab]) {
        self.id = id
        self.closedAt = closedAt
        self.tabs = tabs
    }
}

/// A window as persisted: only regular tabs, and pane tabs only when they are regular.
public struct WindowSession: Hashable, Sendable {
    public var id: WindowID
    public var tabIDs: [TabID]
    public var panes: [TabID?]
    public var focusedPane: Int

    public init(id: WindowID, tabIDs: [TabID], panes: [TabID?], focusedPane: Int) {
        self.id = id
        self.tabIDs = tabIDs
        self.panes = panes
        self.focusedPane = focusedPane
    }
}

/// Everything about open tabs that survives a relaunch: windows in order, their regular tabs and
/// selection, and the recently closed stack. The archive is not part of it; it is read on demand.
public struct TabSession: Hashable, Sendable {
    public var windows: [WindowSession]
    /// Every open regular tab, in no particular order; windows hold the order.
    public var tabs: [TabEntry]
    /// Oldest first; the last batch reopens first.
    public var recentlyClosed: [ClosedTabBatch]

    public init(windows: [WindowSession] = [], tabs: [TabEntry] = [], recentlyClosed: [ClosedTabBatch] = []) {
        self.windows = windows
        self.tabs = tabs
        self.recentlyClosed = recentlyClosed
    }

    public static let empty = TabSession()
}

/// A change `TabStore` hands to persistence. Changes arrive in the order they happened.
public enum TabChange: Sendable, Equatable {
    /// The whole open session after a change. A later one supersedes an earlier one.
    case session(TabSession)
    /// These tabs moved to the archive at `at`.
    case archive([TabEntry], at: Date)
    /// These archived tabs were restored: they leave the archive, whatever happens to them next.
    case unarchive([TabID])
    /// Delete these archived tabs; nil deletes the whole archive.
    case deleteArchived([TabID]?)
}

/// Where `TabStore` sends its changes. Storage's `TabSessionWriter` implements it.
///
/// `enqueue` is called on the main thread after every change, so it must return at once and
/// keep the order; the writing happens elsewhere.
public protocol TabPersistence: Sendable {
    func enqueue(_ change: TabChange)
    /// Writes everything enqueued so far. Call it when the app moves to the background.
    func flush() async
}
