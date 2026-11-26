import Foundation

// docs/state-rules.md as plain values. The shell describes the state it is in (`ChromeState`,
// `GalleryState`); these rules say which control shows, hides or dims. The view code only applies
// the answer, so every "is this control on screen?" decision lives here and is tested over the
// state matrix on macOS (BrowserCoreTests/ControlRulesTests).

/// How a control appears in the current state.
public enum ControlVisibility: Sendable, Equatable {
    /// Shown and working.
    case shown
    /// Shown but disabled: it applies, but cannot act right now.
    case dimmed
    /// Not on screen. In the glass bar its slot is kept, so nothing moves under the thumb.
    case hidden

    public var isVisible: Bool { self != .hidden }
    public var isEnabled: Bool { self == .shown }

    /// Hidden in place becomes dimmed: the Duo's system vertical bar packs its items itself, so
    /// inside a mode nothing hides there (principle 5).
    public func dimmingInsteadOfHiding(_ dims: Bool) -> ControlVisibility {
        dims && self == .hidden ? .dimmed : self
    }
}

/// The bar's third slot: one slot, three faces (§3). Its long press is always the tabs menu.
public enum TabsSlotFace: Sendable, Equatable {
    /// Another tab to switch to: a tap opens the gallery.
    case tabs
    /// One page tab and nothing else: a tap opens a second tab.
    case newTab
    /// On the start screen with nothing else open: you are already in a new tab.
    case hidden
}

/// What the page in the tab on screen is doing, first match wins (§7, item 7).
public enum PageCondition: Sendable, Equatable {
    case loading, loaded, failed, crashed, awaitingResubmit
}

/// What the page menu's first item is (§4).
public enum ReloadItem: Sendable, Equatable {
    case reload, stop, hidden
}

/// The reader item in the page menu (§4).
public enum ReaderItem: Sendable, Equatable {
    case show, hide, hidden
}

/// The state of the browser screen, in the terms of docs/state-rules.md §2.
public struct ChromeState: Sendable, Equatable {
    /// A tab is on screen. An empty tab counts; no tab at all (first run) does not.
    public var hasTab = false
    /// The tab on screen has an address: loaded, loading, failed or crashed. False is Start.
    public var hasPage = false
    public var condition = PageCondition.loaded
    public var isPrivate = false
    /// Back has something to do: history, the reader to close, or an opener to return to.
    public var canGoBack = false
    public var canGoForward = false
    public var isReaderOpen = false
    public var isFindOpen = false
    /// Open tabs besides the one on screen, regular and private together. Empty tabs never count.
    public var others = 0
    /// Tabs in the on-screen tab's own list (regular or private), itself included.
    public var listCount = 0
    /// The bar swipe has a neighbour on that side in `list`.
    public var hasPrevious = false
    public var hasNext = false
    /// The recently closed stack holds a batch.
    public var hasClosed = false
    /// The archive holds at least one tab.
    public var hasArchived = false
    /// The buttons sit in the system's vertical bar (iPhone Duo): it dims instead of hiding.
    public var usesVerticalBar = false
    // Facts about the page, for the page menu.
    public var isWebPage = false
    public var isReaderAvailable = false
    public var isPDF = false
    /// The page can be a favorite (history-recordable address).
    public var isRecordable = false
    /// A Duo split can show (width and height both regular).
    public var canSplit = false

    public init() {}
}

/// Which controls show in `ChromeState` (docs/state-rules.md §3 to §5, §8).
public struct ControlRules: Sendable, Equatable {
    public let state: ChromeState

    public init(_ state: ChromeState) {
        self.state = state
    }

    /// Start mode: no page in the tab on screen.
    public var isStart: Bool { !state.hasPage }

    /// The page shows and can be read, scrolled and zoomed (loading or loaded).
    private var isPageShowing: Bool {
        state.hasPage && (state.condition == .loading || state.condition == .loaded)
    }

    // MARK: The bar (§3)

    /// Leftmost; dim inside Page so its place stays muscle memory. Hidden on Start.
    public var back: ControlVisibility {
        guard !isStart else { return .hidden }
        return state.canGoBack ? .shown : .dimmed
    }

    /// Hidden in place until there is somewhere forward; dim in the vertical bar. In the reader it
    /// does nothing, so a Forward already showing dims.
    public var forward: ControlVisibility {
        guard !isStart else { return .hidden }
        let base: ControlVisibility
        if state.isReaderOpen {
            base = state.canGoForward ? .dimmed : .hidden
        } else {
            base = state.canGoForward ? .shown : .hidden
        }
        return base.dimmingInsteadOfHiding(state.usesVerticalBar)
    }

    /// Nothing to share on Start. A failed page shares the address that was tried.
    public var share: ControlVisibility { isStart ? .hidden : .shown }

    /// History, Settings and Edit Favorites apply everywhere.
    public var more: ControlVisibility { .shown }

    /// One predicate, `others ≥ 1`, for the tap, the swipe up and Show All Tabs.
    public var tabsSlot: TabsSlotFace {
        if state.others >= 1 { return .tabs }
        return state.hasPage ? .newTab : .hidden
    }

    /// The swipe up from the bar opens the gallery; otherwise it bumps ("nothing there").
    public var swipeUpOpensGallery: Bool { state.others >= 1 }

    /// The bar's gestures run; Find on Page owns the bottom while it is open (§7).
    public var acceptsBarGestures: Bool { !state.isFindOpen }

    /// A sideways bar swipe moves between tabs. With no tab at all it only bumps.
    public var barSwipeSwitchesTabs: Bool { state.hasTab }

    /// The New Tab card past the last tab: only from a page, never from an empty tab.
    public var offersNewTabCard: Bool { state.hasPage && !state.hasNext }

    /// Off on Start, in the reader, and on failed, crashed or resend pages (their button owns it).
    public var pullToRefresh: Bool { isPageShowing && !state.isReaderOpen }

    // MARK: The tabs menu (§5)

    /// Hidden on an empty regular tab: it would reuse the tab already on screen.
    public var menuNewTab: Bool { !(state.hasTab && !state.hasPage && !state.isPrivate) }

    /// Hidden on an empty private tab.
    public var menuNewPrivateTab: Bool { !(state.hasTab && !state.hasPage && state.isPrivate) }

    /// A pair shown with 2 or more tabs in the list; each dims at its end.
    public var menuPreviousTab: ControlVisibility {
        guard state.listCount >= 2 else { return .hidden }
        return state.hasPrevious ? .shown : .dimmed
    }

    public var menuNextTab: ControlVisibility {
        guard state.listCount >= 2 else { return .hidden }
        return state.hasNext ? .shown : .dimmed
    }

    public var menuShowAllTabs: Bool { swipeUpOpensGallery }
    public var menuReopenClosedTab: Bool { state.hasClosed }
    public var menuArchivedTabs: Bool { state.hasArchived }
    /// Closing an empty tab does nothing useful; it goes away by itself.
    public var menuCloseTab: Bool { state.hasPage }

    // MARK: The page menu (§4)

    /// Stop in Reload's place while loading; nothing to reload on Start or in the reader.
    public var reload: ReloadItem {
        guard state.hasPage, !state.isReaderOpen else { return .hidden }
        return state.condition == .loading ? .stop : .reload
    }

    /// Nothing to find on an error; in the reader it finds in the article.
    public var findOnPage: Bool { isPageShowing || (state.hasPage && state.isReaderOpen) }

    public var reader: ReaderItem {
        if state.isReaderOpen { return .hide }
        return state.hasPage && state.condition == .loaded && state.isReaderAvailable ? .show : .hidden
    }

    public var savePDF: Bool {
        state.hasPage && state.condition == .loaded && state.isPDF && !state.isReaderOpen
    }

    /// Share and Copy Link: any page, the failed one's address included.
    public var shareAndCopy: Bool { state.hasPage }

    /// Zoom acts on the page, which is hidden under the reader.
    public var zoom: Bool { isPageShowing && !state.isReaderOpen }

    /// Stays on a failed page: a remembered Desktop Site choice can be why it failed.
    public var desktopSite: Bool {
        guard state.hasPage, state.isWebPage, !state.isReaderOpen else { return false }
        return isPageShowing || state.condition == .failed
    }

    /// Like Desktop Site, regular tabs only (the allow-list is saved to disk).
    public var blockingToggle: Bool { desktopSite && !state.isPrivate }

    /// A page that never loaded is not a favorite; the reader's page is.
    public var favorite: Bool {
        guard state.hasPage, state.isRecordable else { return false }
        return state.isReaderOpen || state.condition == .loaded
    }

    public var openInOtherPane: Bool { state.canSplit && isPageShowing && !state.isReaderOpen }

    /// The tabs menu's items move into the page menu while the tabs slot is hidden, so none is
    /// ever out of reach. Nil when they don't show; else whether the new-tab item opens a private
    /// tab (on an empty private tab it reads "New Tab" and turns this tab regular).
    public var startNewTabOpensPrivate: Bool? {
        guard tabsSlot == .hidden else { return nil }
        return !(state.hasTab && state.isPrivate)
    }

    public var startReopenClosedTab: Bool { tabsSlot == .hidden && state.hasClosed }
    public var startArchivedTabs: Bool { tabsSlot == .hidden && state.hasArchived }
}

// MARK: - Tab gallery (§6)

/// The gallery's list and what it can do, in the terms of docs/state-rules.md §6.
public struct GalleryState: Sendable, Equatable {
    /// Cards in the shown list. Empty tabs are never cards.
    public var listCount = 0
    /// Cards Close All Tabs would close (pinned tabs stay).
    public var closableCount = 0
    public var isPrivateList = false
    /// The tab on screen is a card in the shown list.
    public var selectionInList = false
    public var hasClosed = false
    public var hasArchived = false

    public init() {}
}

/// Where the gallery goes after its last card in the shown list closes (§6).
public enum GalleryAfterLastCard: Sendable, Equatable {
    /// The tab on screen still exists (it is in the other list): the gallery opens it.
    case openScreenTab
    /// The other list has tabs: the gallery switches to it.
    case switchList
    /// Nothing left: the search field.
    case search
}

public struct GalleryRules: Sendable, Equatable {
    public let state: GalleryState

    public init(_ state: GalleryState) {
        self.state = state
    }

    /// In an empty list, the empty state's button is the one New Tab (principle 8).
    public var newTabButton: Bool { state.listCount > 0 }

    /// Done returns to the tab on screen, so it shows only when that tab is in the list.
    public var done: Bool { state.selectionInList }

    public var reopenClosedTab: Bool { state.hasClosed && !state.isPrivateList }
    public var archivedTabs: Bool { state.hasArchived && !state.isPrivateList }

    /// With one card, its swipe or menu closes it.
    public var closeAllTabs: Bool { state.closableCount >= 2 }

    /// A menu button with an empty menu is a dead end.
    public var more: Bool { reopenClosedTab || archivedTabs || closeAllTabs }

    /// Private tabs never come back, so their close offers nothing.
    public var reopenToastAfterClose: Bool { !state.isPrivateList }

    /// The list the gallery opens on, or nil when it must not open (no tab to switch to). The
    /// on-screen tab's list wins while it has cards; never an empty list when the other has some.
    public static func listToOpen(screenTabIsPrivate: Bool?, regularCount: Int, privateCount: Int) -> Bool? {
        guard regularCount + privateCount > 0 else { return nil }
        let preferred = screenTabIsPrivate ?? false
        let preferredCount = preferred ? privateCount : regularCount
        return preferredCount > 0 ? preferred : !preferred
    }

    /// The last card of the shown list just closed. Never an empty gallery (Arc).
    public static func afterLastCard(screenTabStillOpen: Bool, otherListCount: Int) -> GalleryAfterLastCard {
        if screenTabStillOpen { return .openScreenTab }
        return otherListCount > 0 ? .switchList : .search
    }
}
