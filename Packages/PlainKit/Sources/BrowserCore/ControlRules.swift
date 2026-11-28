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

/// The reload control inside the resting pill (§3): Reload, Stop while the page loads, or
/// nothing. Its long press offers Reload Without Cache.
public enum PillReloadFace: Sendable, Equatable {
    case reload, stop, hidden
}

/// The reader item in the page menu (§4).
public enum ReaderItem: Sendable, Equatable {
    case show, hide, hidden
}

/// The side pane item in the page menu (§4): Show Side Pane, Hide Side Pane, or nothing where the
/// pane can't show (the Duo's outer screen, phones).
public enum SidePaneItem: Sendable, Equatable {
    case show, hide, hidden
}

/// The page appearance control inside the resting pill (§3): the glyph of what the page shows
/// (Dark, Light, or Off by the user's choice), or absent while Plain changes nothing.
public enum PageAppearanceIndicator: Sendable, Equatable {
    case shown(PageAppearance)
    case hidden
}

/// What Dark Pages is doing on the page on screen, in the app's dark colors (in light colors it
/// is always `.none`). docs/research/dark-pages-optin.md, the state table.
public enum DarkPagesPage: Sendable, Equatable {
    /// Light colors, a page with its own dark design, or not checked yet.
    case none
    /// The page could use it, the switch is off and the site has no choice of its own.
    case available
    /// Plain darkens the page.
    case darkened
    /// The page could use it, and the user turned it off for this site.
    case off
}

/// The translate item in the page menu (§4).
public enum TranslateItem: Sendable, Equatable {
    case translate, showOriginal, hidden
}

/// The cookie banner item in Site Settings (§4).
public enum CookieBannersItem: Sendable, Equatable {
    /// Plain answers the site's cookie banner (rejecting where it can): offer to stop.
    case turnOff
    /// The user stopped it for this site: offer to start again.
    case turnOn
    case hidden
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
    /// The empty field shows rows of its own (recent pages, closed tabs, a copied link).
    public var showsFocusRows = false
    /// Open tabs besides the one on screen, regular and private together. Empty tabs never count.
    public var others = 0
    /// Tabs in the on-screen tab's own list (regular or private), itself included.
    public var listCount = 0
    /// Tabs of that list Close All Tabs would close: pinned tabs stay (`closeAllKeepsPinnedTabs`).
    public var closableInList = 0
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
    /// What Dark Pages is doing on the page (only ever anything while the page is dark).
    public var darkPages = DarkPagesPage.none
    /// The page appearance the page's site gets (its own choice, else the default), and whether
    /// it is the site's own (`PageAppearanceChoices`).
    public var pageAppearance = PageAppearance.off
    public var pageAppearanceIsOwn = false
    /// The site has no light design (made only in dark): Light can't apply to it.
    public var isLightless = false
    /// The page's language is known, can be translated on the device, and is not one the user
    /// reads (their preferred languages).
    public var isForeignLanguage = false
    /// The page's language is known and is not one the user reads, whether or not the device can
    /// translate it (Summarize Page would write in that language).
    public var isUnreadLanguage = false
    /// The page shows translated text, or a translation is on its way.
    public var isTranslated = false
    /// The user turned cookie banner handling off for this site.
    public var isCookieBannersOff = false
    /// The page can be a favorite (history-recordable address).
    public var isRecordable = false
    /// A Duo split can show (width and height both regular).
    public var canSplit = false
    /// Two panes show; the rules describe the focused one.
    public var isSplit = false
    /// The side pane can show here (the top bar's screens: the Duo's inner screen).
    public var canShowSidePane = false
    /// The side pane is open in this window.
    public var isSidePaneOpen = false
    /// The sidebar (Tab Layout Left or Right) is in effect: it is the tab list.
    public var sideTabs = false
    /// VoiceOver or Switch Control runs: the bar stays reachable, never hidden.
    public var usesAssistiveTech = false
    /// Apple's on-device model can run now (`AIAvailability.available`): eligible phone, Apple
    /// Intelligence on, model ready, language supported.
    public var isAIAvailable = false
    /// The search field holds text that would search, not an address (`AddressBarInput.search`).
    public var queryIsSearch = false

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

    /// The bar may leave the screen while the user reads (state rules, "Chrome while reading"):
    /// only on a loaded page. Not while it loads (the pill carries the progress and the page may
    /// not have painted), not on a failed, crashed or resend page (its button is the next step),
    /// not while editing or finding, and never for VoiceOver or Switch Control, which need the
    /// bar in reach. The pill stays allowed in all of these, as it is today. The page must also
    /// be long enough, which the shell checks from the scroll view.
    public var chromeMayHide: Bool {
        isPageShowing && state.condition == .loaded && !state.isEditing && !state.isFindOpen
            && !state.usesAssistiveTech
    }


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

    /// New Tab in the bar (docs/research/new-tab.md): from any page, regular or private, loaded or
    /// not. Hidden on Start: the tab on screen is already a new tab, and New Tab there would only
    /// reuse it (principle 8). Share, which had this slot, is the page sheet's last tile.
    public var newTab: ControlVisibility { isStart ? .hidden : .shown }

    /// History, Settings and Edit Favorites apply everywhere.
    public var more: ControlVisibility { .shown }

    /// Tabs whenever the switcher has a card, the swipe up's predicate: with one page tab the tap
    /// opens its card, as dragging the bar up does (owner, 2026-11-27). With
    /// side tabs the slot shows and hides the sidebar, which is always there to toggle (M3).
    public var tabsSlot: TabsSlotFace {
        state.sideTabs || galleryHasCards ? .tabs : .hidden
    }

    /// The gallery has a card to show: another tab, or the page on screen (one page tab shows its
    /// card alone, with New Tab in the bar under it). An empty tab alone has nothing to show.
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

    /// The reload glyph at the resting pill's trailing end (owner, 2026-11-28: "easy access to
    /// refresh"), with pull to refresh's predicate, so the button and the gesture never disagree
    /// (principle 3): on a page that shows, Reload, or Stop while it loads. Not on Start (nothing
    /// to reload), not in the reader (the article is already what the page has; Back leaves it),
    /// not on a failed, crashed or resend page (its one button, Try Again or Reload, is the next
    /// step; a second would repeat it), not while editing (the pill is the field). Private tabs
    /// keep it. The collapsed pill and the inner screen's slim band leave it out on their own:
    /// they take a tap that brings the bar back, nothing else.
    public var pillReload: PillReloadFace {
        guard pullToRefresh, !state.isEditing else { return .hidden }
        return state.condition == .loading ? .stop : .reload
    }

    /// Reload Without Cache, the pill reload's long press: wherever Reload itself shows.
    public var reloadFromOrigin: Bool { pillReload == .reload }

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
    /// On a private tab with another private page open: ends private browsing in one step, as
    /// Safari's and Chrome's Close All. With one, Close Tab already does it.
    public var menuCloseAllPrivateTabs: Bool { state.isPrivate && state.listCount >= 2 }
    /// Close All Tabs under Close Tab, as Safari's tabs button offers it: on a regular tab, with two
    /// or more tabs it would close (one is Close Tab's job). Confirmed first, as in the gallery's
    /// More. A private list has its own Close All Private Tabs above.
    public var menuCloseAllTabs: Bool { !state.isPrivate && state.closableInList >= 2 }

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

    /// Site Settings' "Page Appearance" (Dark, Light, Off) on every web page itself (not under the
    /// reader, not on an error page): how the site looks is the user's to choose in any colors of
    /// Plain's, as it is separate from Plain's own Appearance.
    public var pageAppearanceMenu: Bool {
        isPageShowing && state.isWebPage && !state.isReaderOpen
    }

    /// The control in the resting pill, while Plain changes how the page looks: Dark (forced dark,
    /// or darkened), Light (forced light, on a site that has a light design), or Off when the user
    /// chose it for this site against a default (so the way back is where it was left). Absent
    /// when nothing is applied (the page as the site made it, by default), while editing (the
    /// field takes the pill), under the reader and on error pages.
    public var pageAppearanceIndicator: PageAppearanceIndicator {
        guard isPageShowing, state.isWebPage, !state.isReaderOpen, !state.isEditing else { return .hidden }
        switch state.pageAppearance {
        case .dark: return .shown(.dark)
        case .light: return state.isLightless ? .hidden : .shown(.light)
        case .off: return state.pageAppearanceIsOwn ? .shown(.off) : .hidden
        }
    }

    /// Translate Page on a loaded page in a language the user doesn't read; Show Original while it
    /// is translated (also while loading: a translated page keeps translating what it adds).
    /// Never under the reader (it would act out of sight) or on an error page.
    public var translate: TranslateItem {
        guard isPageShowing, state.isWebPage, !state.isReaderOpen else { return .hidden }
        if state.isTranslated { return .showOriginal }
        return state.condition == .loaded && state.isForeignLanguage ? .translate : .hidden
    }

    /// Print and Save as PDF, Plain's actions in the share sheet, act on what finished loading: the
    /// page, a PDF, or the reader's article (which prints instead of the page under it). Not on
    /// Start, while loading (half a page), or on an error or crashed page (Plain's own message,
    /// nothing of the site's).
    public var print: Bool {
        if state.isReaderOpen { return state.hasPage }
        return state.hasPage && state.condition == .loaded && (state.isWebPage || state.isPDF)
    }

    /// As Print, except on a PDF, which is already one: "Save PDF to Files" keeps the original.
    public var saveAsPDF: Bool { print && (state.isReaderOpen || !state.isPDF) }

    /// Cookie banners are answered on every web page (`FixedChoices.cookieBannersHandled`); the
    /// switch for the site sits with the other per-site choices, on the page itself only.
    /// Private tabs: shown, kept for the private session only.
    public var cookieBanners: CookieBannersItem {
        guard isPageShowing, state.isWebPage, !state.isReaderOpen else { return .hidden }
        return state.isCookieBannersOff ? .turnOn : .turnOff
    }

    /// A page that never loaded is not a favorite; the reader's page is.
    public var favorite: Bool {
        guard state.hasPage, state.isRecordable else { return false }
        return state.isReaderOpen || state.condition == .loaded
    }

    /// Read Later follows Add to Favorites: a page that loaded, or the reader's page. A failed
    /// page is not saved (there is nothing to read later, and it may never load).
    public var readLater: Bool { favorite }

    /// A saved page whose load failed for want of the network (offline, the site gone or slow to
    /// answer) opens its saved copy in the reader (`FixedChoices.readingListOpensCopyWhenOffline`).
    /// Not on a certificate error: the site answered, and its warning must stay in front.
    public static func opensSavedCopy(errorDomain: String, code: Int) -> Bool {
        guard FixedChoices.readingListOpensCopyWhenOffline, errorDomain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
            NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
            NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive,
        ].contains(code)
    }

    /// Summarize Page: an article (the reader's own, or a loaded page Reader can read), where the
    /// on-device model can run. A page Reader can't read has no article to summarize; without
    /// the model the item is left out, never dimmed (§4). Not on a page in a language the user
    /// doesn't read: the summary is written in the page's language, so Translate Page is the
    /// item that helps there (and the menu keeps fitting the Duo's outer screen).
    public var summarizePage: Bool {
        guard state.isAIAvailable, state.hasPage, !state.isUnreadLanguage else { return false }
        return state.isReaderOpen || (state.condition == .loaded && state.isReaderAvailable && !state.isPDF)
    }

    /// Downloads: while any ran this session.
    public var downloads: Bool { state.hasDownloads }

    /// Open in Other Pane: a page that shows, where a split can show and none does yet.
    public var openInOtherPane: Bool {
        state.canSplit && !state.isSplit && !state.isSidePaneOpen && isPageShowing && !state.isReaderOpen
    }

    /// Swap Panes and Close Pane while a split shows, whatever the focused pane holds. The side
    /// pane takes the second pane's place while it is open, so neither applies then.
    public var paneItems: Bool { state.canSplit && state.isSplit && !state.isSidePaneOpen }

    /// Show or Hide Side Pane wherever the pane can show, page or start screen: History is useful on
    /// either, and the item is how the pane closes from the bar.
    public var sidePane: SidePaneItem {
        guard state.canShowSidePane, !state.isEditing else { return .hidden }
        return state.isSidePaneOpen ? .hide : .show
    }

    /// History and Find on Page open in the side pane where it can show (next to the page), and
    /// as a sheet and the find bar elsewhere.
    public var historyInSidePane: Bool { state.canShowSidePane }
    public var findInSidePane: Bool { state.canShowSidePane && !state.isReaderOpen }

    // The tabs menu's other items sit in More's top section in every state where they apply, one
    // visible tap away; the long press on the tabs slot is a shortcut, never the only way (owner,
    // 2026-11-26).

    /// Whether More's new-tab item opens a private tab. Always shown; on an empty private tab it
    /// reads "New Tab" and turns this tab regular (nothing is added).
    /// Not on an empty private tab, nor on an empty pane in a private window: there it reads
    /// Leave Private.
    public var moreNewTabOpensPrivate: Bool { !(!state.hasPage && state.isPrivate) }

    public var moreReopenClosedTab: Bool { state.hasClosed }
    public var moreArchivedTabs: Bool { state.hasArchived }

    // MARK: The search field (§6)

    /// Browse for Me beside the field: while the text would search (an address opens, there is
    /// nothing to browse), where the on-device model can run. Private tabs too: it leaves nothing
    /// behind (`FixedChoices.summariesLeaveNoTrace`).
    public var browseForMe: Bool { state.isEditing && state.queryIsSearch && state.isAIAvailable }

    // MARK: The start screen (§3)

    /// While a query is typed on the start screen, the mark, sentence and shortcuts recede (fade,
    /// shrink a little, drift up) so suggestion rows never draw over them; they come back when the
    /// query is cleared or the field closes (owner, 2026-11-26). The same while the empty field
    /// shows rows of its own (recent pages, closed tabs, a copied link): they take the paper the
    /// mark kept company.
    public var startScreenRecedes: Bool { isStart && state.isEditing && (state.hasQuery || state.showsFocusRows) }
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
    /// Profiles there are; 0 where the data source has none (previews, tests).
    public var profileCount = 0

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

    /// With one card, its swipe or menu closes it. The private list offers Close All Private Tabs
    /// with any card: it is how people expect to end private browsing (Safari, Chrome).
    public var closeAllTabs: Bool { state.closableCount >= (state.isPrivateList ? 1 : 2) }

    /// The profile switcher above the cards: only with a second profile to switch to, and never
    /// over private tabs, which belong to no profile's data.
    public var profileSwitcher: Bool { state.profileCount >= 2 && !state.isPrivateList }

    /// New Profile in the More menu while Personal is the only profile; from the second one on it
    /// lives in the switcher's menu with the profiles.
    public var newProfile: Bool { state.profileCount == 1 && !state.isPrivateList }

    /// A menu button with an empty menu is a dead end.
    public var more: Bool { reopenClosedTab || archivedTabs || closeAllTabs || newProfile }

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

// MARK: - First-run intro

/// What the intro may promise on this screen.
public enum IntroRules {
    /// "Made for iPhone Duo — Unfold for two pages side by side" shows only on a phone that folds.
    /// UIKit says so directly: a `UIHingeInteraction` gets a hinge only in a hierarchy that has
    /// one (iOS 27.1). The traits back it up until that first answer: the outer screen (the system
    /// gives it a vertical bar edge) or the inner one (both size classes regular; Plain is
    /// iPhone-only, so no iPad takes that branch). Other iPhones can't unfold, and the row would
    /// promise something they can't do. Never the device model (AGENTS.md).
    public static func showsUnfoldRow(
        hasHinge: Bool = false, hasVerticalBarEdge: Bool, widthRegular: Bool, heightRegular: Bool
    ) -> Bool {
        hasHinge || hasVerticalBarEdge || (widthRegular && heightRegular)
    }
}
