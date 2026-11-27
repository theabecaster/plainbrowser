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

/// The bar's third slot (§3). Its long press is always the tabs menu.
public enum TabsSlotFace: Sendable, Equatable {
    /// The switcher has a card to show: a tap opens the gallery, as the swipe up does.
    case tabs
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

/// The dark pages item in the page menu (§4).
public enum DarkPagesItem: Sendable, Equatable {
    case turnOff, turnOn, hidden
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
    /// The search field is open (Editing mode).
    public var isEditing = false
    /// Downloads ran or run this session.
    public var hasDownloads = false
    /// The search field holds a query (not only spaces).
    public var hasQuery = false
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
    /// Plain darkens the page (only ever while the app is dark).
    public var isDarkened = false
    /// The user turned dark pages off for this site, and the app is dark.
    public var isDarkPagesOff = false
    /// The page can be a favorite (history-recordable address).
    public var isRecordable = false
    /// A Duo split can show (width and height both regular).
    public var canSplit = false
    /// Two panes show; the rules describe the focused one.
    public var isSplit = false
    /// The sidebar (Tab Layout Left or Right) is in effect: it is the tab list.
    public var sideTabs = false

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

    /// Editing hides the button bar (the keyboard and the field take the bottom), in the glass bar
    /// and in the Duo's vertical bar alike (§6). So does Find on Page: the find bar replaces the
    /// page's bar (§7).
    public var barShown: Bool { !state.isEditing && !state.isFindOpen }

    /// Start mode with the field closed, in the glass bar: the bar holds at most Tabs and More, so
    /// it shrinks to a round glass button beside the pill (a capsule with both) instead of a
    /// full-width bar with one button at its end. Start is its own mode, so the bar may change
    /// shape (§1, principle 5). The Duo's vertical bar packs its own items.
    public var barBesidePill: Bool { isStart && !state.isEditing && !state.usesVerticalBar }


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

    /// Tabs whenever the switcher has a card, the swipe up's predicate: with one page tab the tap
    /// opens its card beside a New Tab card, as dragging the bar up does (owner, 2026-11-27). With
    /// side tabs the slot shows and hides the sidebar, which is always there to toggle (M3).
    public var tabsSlot: TabsSlotFace {
        state.sideTabs || galleryHasCards ? .tabs : .hidden
    }

    /// The gallery has a card to show: another tab, or the page on screen (one page tab shows its
    /// card beside a New Tab card). An empty tab alone has nothing to show.
    public var galleryHasCards: Bool { state.others >= 1 || state.hasPage }

    /// The swipe up from the bar opens the gallery whenever it has a card, so the gesture always
    /// means the switcher; otherwise it bumps ("nothing there"). Off with side tabs: the sidebar
    /// is the switcher.
    public var swipeUpOpensGallery: Bool { !state.sideTabs && galleryHasCards }

    /// The bar's gestures run; Find on Page owns the bottom while it is open (§7).
    public var acceptsBarGestures: Bool { !state.isFindOpen && barShown }

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

    /// The gallery from the menu, with the swipe up's predicate. With side tabs too, as the button
    /// there toggles the sidebar; there the sidebar already lists a lone tab, so it needs another.
    public var menuShowAllTabs: Bool { state.sideTabs ? state.others >= 1 : galleryHasCards }
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

    /// Turn Off while Plain darkens the page, Turn On while the user has it off for the site; only
    /// on the page itself (not under the reader, not on an error page). In a light app, or on a
    /// page with its own dark design, there is nothing to switch.
    public var darkPages: DarkPagesItem {
        guard isPageShowing, state.isWebPage, !state.isReaderOpen else { return .hidden }
        if state.isDarkened { return .turnOff }
        if state.isDarkPagesOff { return .turnOn }
        return .hidden
    }

    /// A page that never loaded is not a favorite; the reader's page is.
    public var favorite: Bool {
        guard state.hasPage, state.isRecordable else { return false }
        return state.isReaderOpen || state.condition == .loaded
    }

    /// Downloads: while any ran this session.
    public var downloads: Bool { state.hasDownloads }

    /// Open in Other Pane: a page that shows, where a split can show and none does yet.
    public var openInOtherPane: Bool { state.canSplit && !state.isSplit && isPageShowing && !state.isReaderOpen }

    /// Swap Panes and Close Pane while a split shows, whatever the focused pane holds.
    public var paneItems: Bool { state.canSplit && state.isSplit }

    // The tabs menu's other items sit in More's top section in every state where they apply, one
    // visible tap away; the long press on the tabs slot is a shortcut, never the only way (owner,
    // 2026-11-26).

    /// Whether More's new-tab item opens a private tab. Always shown; on an empty private tab it
    /// reads "New Tab" and turns this tab regular (nothing is added).
    public var moreNewTabOpensPrivate: Bool { !(state.hasTab && !state.hasPage && state.isPrivate) }

    public var moreReopenClosedTab: Bool { state.hasClosed }
    public var moreArchivedTabs: Bool { state.hasArchived }

    // MARK: The start screen (§3)

    /// While a query is typed on the start screen, the mark, sentence and shortcuts recede (fade,
    /// shrink a little, drift up) so suggestion rows never draw over them; they come back when the
    /// query is cleared or the field closes (owner, 2026-11-26).
    public var startScreenRecedes: Bool { isStart && state.isEditing && state.hasQuery }

    /// Small shortcuts under the mark on the start screen, only the ones that apply: a private tab
    /// always (a regular one from an empty private tab), Reopen Closed Tab with `closed`, Archived
    /// Tabs with `archived`.
    public var startShortcuts: [StartShortcut] {
        guard isStart else { return [] }
        var shortcuts: [StartShortcut] = [moreNewTabOpensPrivate ? .privateTab : .regularTab]
        if state.hasClosed { shortcuts.append(.reopenClosedTab) }
        if state.hasArchived { shortcuts.append(.archivedTabs) }
        return shortcuts
    }
}

/// A shortcut under the start screen's mark.
public enum StartShortcut: Sendable, Equatable {
    case privateTab, regularTab, reopenClosedTab, archivedTabs
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

    /// One card in the list: a paper New Tab card sits beside it, so the switcher never looks
    /// half empty and the next step is in plain sight (owner, 2026-11-26).
    public var newTabCard: Bool { state.listCount == 1 }

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
