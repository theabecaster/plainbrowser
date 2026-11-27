@testable import BrowserCore
import Testing

/// docs/state-rules.md §8, row by row: each test builds one state of the matrix and checks every
/// control the row names.
@Suite struct ControlRulesTests {
    // MARK: States

    /// First run: no tab at all.
    static var firstRun: ChromeState { ChromeState() }

    /// An empty tab on screen.
    static func emptyTab(others: Int = 0, isPrivate: Bool = false) -> ChromeState {
        var state = ChromeState()
        state.hasTab = true
        state.isPrivate = isPrivate
        state.others = others
        state.listCount = 1 + (isPrivate ? 0 : others)
        state.hasPrevious = others > 0 && !isPrivate
        return state
    }

    /// A loaded page.
    static func page(
        others: Int = 0, condition: PageCondition = .loaded, isPrivate: Bool = false,
        canGoBack: Bool = false, canGoForward: Bool = false, hasNext: Bool = false
    ) -> ChromeState {
        var state = ChromeState()
        state.hasTab = true
        state.hasPage = true
        state.condition = condition
        state.isPrivate = isPrivate
        state.canGoBack = canGoBack
        state.canGoForward = canGoForward
        state.others = others
        state.listCount = 1 + others
        state.hasPrevious = others > 0 && !hasNext
        state.hasNext = hasNext
        state.isWebPage = true
        state.isRecordable = true
        return state
    }

    // MARK: §8 rows

    @Test func firstRunShowsOnlyMoreAndBumpsEveryGesture() {
        let rules = ControlRules(Self.firstRun)
        #expect(rules.back == .hidden)
        #expect(rules.forward == .hidden)
        #expect(rules.share == .hidden)
        #expect(rules.more == .shown)
        #expect(rules.tabsSlot == .hidden)
        #expect(!rules.swipeUpOpensGallery)
        #expect(!rules.barSwipeSwitchesTabs)
        #expect(!rules.offersNewTabCard)
        #expect(!rules.pullToRefresh)
        #expect(rules.reload == .hidden)
    }

    @Test func noTabsButClosedOrArchivedOffersThemOnTheStartScreenAndInMore() {
        var state = Self.firstRun
        state.hasClosed = true
        state.hasArchived = true
        let rules = ControlRules(state)
        #expect(rules.tabsSlot == .hidden)
        #expect(rules.moreNewTabOpensPrivate)
        #expect(rules.moreReopenClosedTab)
        #expect(rules.moreArchivedTabs)
        #expect(rules.startShortcuts == [.privateTab, .reopenClosedTab, .archivedTabs])
        // Without them, only the private tab.
        let bare = ControlRules(Self.firstRun)
        #expect(!bare.moreReopenClosedTab)
        #expect(!bare.moreArchivedTabs)
        #expect(bare.startShortcuts == [.privateTab])
    }

    @Test func moreCarriesTheTabItemsInEveryStateWhereTheyApply() {
        var state = Self.page(others: 3)
        state.hasClosed = true
        let rules = ControlRules(state)
        #expect(rules.moreNewTabOpensPrivate)
        #expect(rules.moreReopenClosedTab)
        #expect(!rules.moreArchivedTabs)
        #expect(rules.startShortcuts.isEmpty, "shortcuts are for the start screen only")
    }

    @Test func emptyTabWithOthersShowsTabsAndTheGallery() {
        let rules = ControlRules(Self.emptyTab(others: 2))
        #expect(rules.tabsSlot == .tabs)
        #expect(rules.swipeUpOpensGallery)
        #expect(rules.menuShowAllTabs)
        #expect(rules.back == .hidden)
        #expect(rules.forward == .hidden)
        #expect(rules.share == .hidden)
        #expect(!rules.offersNewTabCard, "swiping past an empty tab would make a second empty tab")
        #expect(rules.startShortcuts == [.privateTab])
        #expect(!rules.menuNewTab, "New Tab would reuse the empty tab on screen")
        #expect(rules.menuNewPrivateTab)
        #expect(!rules.menuCloseTab)
        #expect(rules.menuPreviousTab == .shown)
        #expect(rules.menuNextTab == .dimmed)
    }

    @Test func emptyTabAloneHasNoSwitcherAndNoNewTab() {
        let rules = ControlRules(Self.emptyTab())
        #expect(rules.tabsSlot == .hidden)
        #expect(!rules.galleryHasCards)
        #expect(!rules.swipeUpOpensGallery, "nothing to show: the swipe bumps")
        #expect(!rules.menuShowAllTabs)
        #expect(rules.barSwipeSwitchesTabs)
        #expect(!rules.offersNewTabCard)
        #expect(rules.menuPreviousTab == .hidden)
        #expect(rules.startShortcuts == [.privateTab])
    }

    @Test func emptyPrivateTabOffersARegularNewTab() {
        let rules = ControlRules(Self.emptyTab(isPrivate: true))
        #expect(!rules.moreNewTabOpensPrivate)
        #expect(rules.startShortcuts == [.regularTab])
        #expect(rules.menuNewTab)
        #expect(!rules.menuNewPrivateTab)
    }

    @Test func onePageNoOthersTapsAndSwipesToTheSwitcher() {
        let rules = ControlRules(Self.page())
        #expect(rules.tabsSlot == .tabs, "the tap opens the switcher, as the swipe up does")
        #expect(rules.galleryHasCards)
        #expect(rules.swipeUpOpensGallery, "one card and a New Tab card")
        #expect(rules.menuShowAllTabs, "same predicate as the swipe up")
        #expect(rules.back == .dimmed)
        #expect(rules.forward == .hidden)
        #expect(rules.share == .shown)
        #expect(rules.offersNewTabCard)
        #expect(rules.pullToRefresh)
        #expect(rules.menuPreviousTab == .hidden)
        #expect(rules.menuNextTab == .hidden)
        #expect(rules.menuCloseTab)
        #expect(rules.menuNewTab && rules.menuNewPrivateTab)
        #expect(rules.startShortcuts.isEmpty)
    }

    @Test func theTabsTapAndTheSwipeUpShareOnePredicate() {
        let states = [Self.firstRun, Self.emptyTab(), Self.emptyTab(others: 2), Self.page(),
                      Self.page(isPrivate: true), Self.page(others: 2)]
        for state in states {
            let rules = ControlRules(state)
            #expect((rules.tabsSlot == .tabs) == rules.swipeUpOpensGallery)
        }
    }

    @Test func backDimsAndForwardHidesInPlace() {
        #expect(ControlRules(Self.page(canGoBack: true)).back == .shown)
        #expect(ControlRules(Self.page(canGoForward: true)).forward == .shown)
        #expect(ControlRules(Self.page()).forward == .hidden)
    }

    @Test func theDuoVerticalBarDimsInsteadOfHidingInsideAMode() {
        var state = Self.page()
        state.usesVerticalBar = true
        let rules = ControlRules(state)
        #expect(rules.back == .dimmed)
        #expect(rules.forward == .dimmed)
        // Between modes it still changes shape: Start hides them.
        var start = Self.emptyTab()
        start.usesVerticalBar = true
        #expect(ControlRules(start).forward == .hidden)
        #expect(ControlRules(start).back == .hidden)
    }

    @Test func severalTabs() {
        let middle = ControlRules(Self.page(others: 2, hasNext: true))
        #expect(middle.tabsSlot == .tabs)
        #expect(middle.swipeUpOpensGallery)
        #expect(!middle.offersNewTabCard, "the card shows only past the last tab")
        #expect(middle.menuNextTab == .shown)
        let last = ControlRules(Self.page(others: 2))
        #expect(last.offersNewTabCard)
        #expect(last.menuNextTab == .dimmed)
        #expect(last.menuPreviousTab == .shown)
    }

    @Test func privateOnlyIsLikeOnePage() {
        let rules = ControlRules(Self.page(isPrivate: true))
        #expect(rules.tabsSlot == .tabs)
        #expect(rules.swipeUpOpensGallery)
        #expect(rules.menuShowAllTabs)
        #expect(!rules.blockingToggle, "the allow-list is saved to disk")
        #expect(rules.desktopSite)
    }

    @Test func privatePlusRegularShowsTabs() {
        var state = Self.page(isPrivate: true)
        state.others = 1
        let rules = ControlRules(state)
        #expect(rules.tabsSlot == .tabs)
        #expect(rules.swipeUpOpensGallery)
        #expect(rules.menuPreviousTab == .hidden, "this list has one tab")
    }

    @Test func loadingSwapsReloadForStop() {
        let rules = ControlRules(Self.page(condition: .loading))
        #expect(rules.reload == .stop)
        #expect(rules.findOnPage)
        #expect(rules.zoom)
        #expect(rules.pullToRefresh)
        #expect(rules.reader == .hidden)
        #expect(!rules.favorite, "a page that never loaded is not a favorite")
    }

    @Test func failedPageKeepsWhatCanBeTheCause() {
        let rules = ControlRules(Self.page(condition: .failed))
        #expect(rules.reload == .reload)
        #expect(!rules.findOnPage)
        #expect(!rules.zoom)
        #expect(rules.reader == .hidden)
        #expect(!rules.favorite)
        #expect(rules.shareAndCopy)
        #expect(rules.desktopSite)
        #expect(rules.blockingToggle)
        #expect(!rules.pullToRefresh, "Try Again owns it")
        #expect(rules.back == .dimmed && rules.share == .shown)
    }

    @Test func darkPagesItemOnlyWhereItSwitchesSomething() {
        var state = Self.page()
        #expect(ControlRules(state).darkPages == .hidden, "light app or a site's own dark design")
        state.isDarkened = true
        #expect(ControlRules(state).darkPages == .turnOff)
        state.isPrivate = true
        #expect(ControlRules(state).darkPages == .turnOff, "private tabs keep it for the session")
        state.isDarkened = false
        state.isDarkPagesOff = true
        #expect(ControlRules(state).darkPages == .turnOn)
        state.condition = .loading
        #expect(ControlRules(state).darkPages == .turnOn)
        for condition in [PageCondition.failed, .crashed, .awaitingResubmit] {
            state.condition = condition
            #expect(ControlRules(state).darkPages == .hidden, "\(condition)")
        }
        state.condition = .loaded
        state.isReaderOpen = true
        #expect(ControlRules(state).darkPages == .hidden, "under the reader it acts out of sight")
    }

    @Test func crashedAndResendPagesAreReduced() {
        for condition in [PageCondition.crashed, .awaitingResubmit] {
            let rules = ControlRules(Self.page(condition: condition))
            #expect(rules.reload == .reload)
            #expect(!rules.findOnPage)
            #expect(!rules.zoom)
            #expect(!rules.desktopSite)
            #expect(!rules.blockingToggle)
            #expect(!rules.favorite)
            #expect(rules.shareAndCopy)
            #expect(!rules.pullToRefresh)
        }
    }

    @Test func readerHidesWhatActsOnTheHiddenPage() {
        var state = Self.page(canGoBack: true, canGoForward: true)
        state.isReaderOpen = true
        let rules = ControlRules(state)
        #expect(rules.reload == .hidden)
        #expect(rules.findOnPage)
        #expect(rules.reader == .hide)
        #expect(!rules.zoom)
        #expect(!rules.desktopSite)
        #expect(!rules.blockingToggle)
        #expect(rules.favorite)
        #expect(!rules.pullToRefresh)
        #expect(rules.forward == .dimmed)
        #expect(!rules.savePDF)
    }

    @Test func readerAndPDFItemsOnlyWhereTheyApply() {
        var state = Self.page()
        #expect(ControlRules(state).reader == .hidden)
        state.isReaderAvailable = true
        #expect(ControlRules(state).reader == .show)
        state.isPDF = true
        #expect(ControlRules(state).savePDF)
        state.condition = .loading
        #expect(!ControlRules(state).savePDF)
    }

    @Test func translateOnlyOnAForeignPageThatShows() {
        var state = Self.page()
        #expect(ControlRules(state).translate == .hidden, "a page in a language the user reads")
        state.isForeignLanguage = true
        #expect(ControlRules(state).translate == .translate)
        state.condition = .loading
        #expect(ControlRules(state).translate == .hidden, "wait for the page before offering")
        state.isTranslated = true
        #expect(ControlRules(state).translate == .showOriginal, "a translated page loading more keeps the way back")
        state.condition = .loaded
        #expect(ControlRules(state).translate == .showOriginal)
        for condition in [PageCondition.failed, .crashed, .awaitingResubmit] {
            state.condition = condition
            #expect(ControlRules(state).translate == .hidden, "\(condition)")
        }
        state.condition = .loaded
        state.isReaderOpen = true
        #expect(ControlRules(state).translate == .hidden, "under the reader it acts out of sight")
        state.isReaderOpen = false
        state.isWebPage = false
        #expect(ControlRules(state).translate == .hidden)
    }

    @Test func printAndPDFOnlyOnWhatFinishedLoading() {
        var state = Self.page()
        #expect(ControlRules(state).print)
        #expect(ControlRules(state).saveAsPDF)
        for condition in [PageCondition.loading, .failed, .crashed, .awaitingResubmit] {
            state.condition = condition
            #expect(!ControlRules(state).print, "\(condition)")
            #expect(!ControlRules(state).saveAsPDF, "\(condition)")
        }
        state.condition = .loaded
        state.isPDF = true
        state.isWebPage = false
        #expect(ControlRules(state).print, "a PDF prints")
        #expect(!ControlRules(state).saveAsPDF, "a PDF is saved with Save PDF to Files")
        state = Self.page(condition: .loading)
        state.isReaderOpen = true
        #expect(ControlRules(state).print, "the reader prints its article")
        #expect(ControlRules(state).saveAsPDF)
        #expect(!ControlRules(Self.emptyTab()).print)
    }

    @Test func cookieBannerSwitchOnThePageItself() {
        var state = Self.page()
        #expect(ControlRules(state).cookieBanners == .turnOff)
        state.isCookieBannersOff = true
        #expect(ControlRules(state).cookieBanners == .turnOn)
        state.isPrivate = true
        #expect(ControlRules(state).cookieBanners == .turnOn, "private tabs keep it for the session")
        for condition in [PageCondition.failed, .crashed, .awaitingResubmit] {
            state.condition = condition
            #expect(ControlRules(state).cookieBanners == .hidden, "\(condition)")
        }
        state.condition = .loaded
        state.isReaderOpen = true
        #expect(ControlRules(state).cookieBanners == .hidden)
        #expect(ControlRules(Self.emptyTab()).cookieBanners == .hidden)
    }

    @Test func editingHidesTheBarAndItsGestures() {
        var state = Self.page(others: 2)
        state.isEditing = true
        let rules = ControlRules(state)
        #expect(!rules.barShown)
        #expect(!rules.acceptsBarGestures)
        #expect(ControlRules(Self.firstRun).barShown)
        var finding = Self.page()
        finding.isFindOpen = true
        #expect(!ControlRules(finding).barShown, "the find bar replaces the page's bar")
    }

    @Test func theStartBarSitsBesideThePill() {
        #expect(ControlRules(Self.firstRun).barBesidePill)
        #expect(ControlRules(Self.emptyTab(others: 2)).barBesidePill)
        var editing = Self.emptyTab()
        editing.isEditing = true
        #expect(!ControlRules(editing).barBesidePill, "the field takes the whole width")
        var duo = Self.emptyTab()
        duo.usesVerticalBar = true
        #expect(!ControlRules(duo).barBesidePill, "the vertical bar packs its own items")
        #expect(!ControlRules(Self.page()).barBesidePill, "a page has the full bar")
    }

    @Test func theStartScreenRecedesWhileTyping() {
        var state = Self.emptyTab()
        state.isEditing = true
        #expect(!ControlRules(state).startScreenRecedes, "an empty field keeps the mark")
        state.hasQuery = true
        #expect(ControlRules(state).startScreenRecedes)
        state.isEditing = false
        #expect(!ControlRules(state).startScreenRecedes, "the field closed: the mark comes back")
        var page = Self.page()
        page.isEditing = true
        page.hasQuery = true
        #expect(!ControlRules(page).startScreenRecedes, "no start screen on a page")
    }

    @Test func downloadsOnlyAfterOneRan() {
        var state = Self.page()
        #expect(!ControlRules(state).downloads)
        state.hasDownloads = true
        #expect(ControlRules(state).downloads)
    }

    @Test func findOpenStopsTheBarGestures() {
        var state = Self.page(others: 2)
        #expect(ControlRules(state).acceptsBarGestures)
        state.isFindOpen = true
        #expect(!ControlRules(state).acceptsBarGestures)
    }

    @Test func openInOtherPaneNeedsASplit() {
        var state = Self.page()
        #expect(!ControlRules(state).openInOtherPane)
        state.canSplit = true
        #expect(ControlRules(state).openInOtherPane)
        #expect(!ControlRules(state).paneItems)
        state.condition = .failed
        #expect(!ControlRules(state).openInOtherPane)
    }

    @Test func duoSplitActsOnTheFocusedPane() {
        var state = Self.page(others: 1)
        state.canSplit = true
        state.isSplit = true
        let rules = ControlRules(state)
        #expect(!rules.openInOtherPane, "the other pane already shows")
        #expect(rules.paneItems)
        #expect(rules.tabsSlot == .tabs, "the other pane's tab counts")
        var empty = Self.emptyTab(others: 1)
        empty.canSplit = true
        empty.isSplit = true
        #expect(ControlRules(empty).paneItems, "an empty pane can still be swapped or closed")
    }

    @Test func sidePaneShowsWhereItFitsAndTakesHistoryAndFind() {
        var state = Self.page()
        #expect(ControlRules(state).sidePane == .hidden, "phones and the outer screen have no side pane")
        #expect(!ControlRules(state).historyInSidePane)
        #expect(!ControlRules(state).findInSidePane)
        state.canShowSidePane = true
        #expect(ControlRules(state).sidePane == .show)
        #expect(ControlRules(state).historyInSidePane)
        #expect(ControlRules(state).findInSidePane)
        state.isSidePaneOpen = true
        #expect(ControlRules(state).sidePane == .hide)
        state.isReaderOpen = true
        #expect(!ControlRules(state).findInSidePane, "the reader on the page keeps the find bar")
        var start = Self.emptyTab()
        start.canShowSidePane = true
        #expect(ControlRules(start).sidePane == .show, "History is useful on the start screen too")
    }

    @Test func aSidePaneOverASplitHidesThePaneItems() {
        var state = Self.page(others: 1)
        state.canSplit = true
        state.isSplit = true
        state.canShowSidePane = true
        state.isSidePaneOpen = true
        #expect(!ControlRules(state).paneItems, "the side pane has the second pane's place")
        state.isSplit = false
        #expect(!ControlRules(state).openInOtherPane, "a split would have nowhere to show")
    }

    @Test func sideTabsMakeTheSidebarTheSwitcher() {
        var state = Self.page()
        state.sideTabs = true
        let rules = ControlRules(state)
        #expect(rules.tabsSlot == .tabs, "the slot shows and hides the sidebar")
        #expect(!rules.swipeUpOpensGallery, "the sidebar is the switcher")
        #expect(!rules.menuShowAllTabs, "nothing else to show")
        state.others = 2
        #expect(ControlRules(state).menuShowAllTabs)
        #expect(!ControlRules(state).swipeUpOpensGallery)
    }

    @Test func reopenAndArchiveFollowTheirStores() {
        var state = Self.page(others: 1)
        #expect(!ControlRules(state).menuReopenClosedTab)
        #expect(!ControlRules(state).menuArchivedTabs)
        state.hasClosed = true
        state.hasArchived = true
        #expect(ControlRules(state).menuReopenClosedTab)
        #expect(ControlRules(state).menuArchivedTabs)
        #expect(ControlRules(state).moreReopenClosedTab)
    }

    // MARK: Gallery (§6)

    static func gallery(count: Int, isPrivate: Bool = false, selection: Bool = true) -> GalleryState {
        var state = GalleryState()
        state.listCount = count
        state.closableCount = count
        state.isPrivateList = isPrivate
        state.selectionInList = selection && count > 0
        return state
    }

    @Test func galleryEmptyListHasOneNewTabButton() {
        let rules = GalleryRules(Self.gallery(count: 0))
        #expect(!rules.newTabButton)
        #expect(!rules.done)
        #expect(!rules.more)
        #expect(GalleryRules(Self.gallery(count: 1)).newTabButton)
    }

    @Test func galleryOneCardGetsANewTabCardBesideIt() {
        #expect(!GalleryRules(Self.gallery(count: 0)).newTabCard, "the empty state has its own button")
        #expect(GalleryRules(Self.gallery(count: 1)).newTabCard)
        #expect(GalleryRules(Self.gallery(count: 1, isPrivate: true)).newTabCard)
        #expect(GalleryRules(Self.gallery(count: 1, selection: false)).newTabCard, "the other list's lone card too")
        #expect(!GalleryRules(Self.gallery(count: 2)).newTabCard)
    }

    @Test func galleryDoneOnlyWithTheScreenTabInTheList() {
        #expect(GalleryRules(Self.gallery(count: 2)).done)
        #expect(!GalleryRules(Self.gallery(count: 2, selection: false)).done)
    }

    @Test func galleryMoreHidesWhenItsMenuIsEmpty() {
        var state = Self.gallery(count: 1)
        #expect(!GalleryRules(state).more, "one card, nothing closed, empty archive")
        state.hasClosed = true
        #expect(GalleryRules(state).more)
        #expect(GalleryRules(state).reopenClosedTab)
        state = Self.gallery(count: 2)
        #expect(GalleryRules(state).closeAllTabs)
        state.closableCount = 1
        #expect(!GalleryRules(state).closeAllTabs, "Close All counts only the tabs it closes")
        state = Self.gallery(count: 1)
        state.hasArchived = true
        #expect(GalleryRules(state).archivedTabs)
    }

    @Test func galleryPrivateListOffersNoReopenOrArchive() {
        var state = Self.gallery(count: 3, isPrivate: true)
        state.hasClosed = true
        state.hasArchived = true
        let rules = GalleryRules(state)
        #expect(!rules.reopenClosedTab)
        #expect(!rules.archivedTabs)
        #expect(!rules.reopenToastAfterClose, "private tabs never come back")
        #expect(GalleryRules(Self.gallery(count: 3)).reopenToastAfterClose)
    }

    @Test func galleryOpensOnAListWithCards() {
        #expect(GalleryRules.listToOpen(screenTabIsPrivate: false, regularCount: 2, privateCount: 1) == false)
        #expect(GalleryRules.listToOpen(screenTabIsPrivate: true, regularCount: 2, privateCount: 1) == true)
        // An empty regular tab with private pages open opens the private list, and the reverse.
        #expect(GalleryRules.listToOpen(screenTabIsPrivate: false, regularCount: 0, privateCount: 1) == true)
        #expect(GalleryRules.listToOpen(screenTabIsPrivate: true, regularCount: 2, privateCount: 0) == false)
        // No tab on screen: regular first.
        #expect(GalleryRules.listToOpen(screenTabIsPrivate: nil, regularCount: 0, privateCount: 2) == true)
        #expect(GalleryRules.listToOpen(screenTabIsPrivate: nil, regularCount: 1, privateCount: 2) == false)
        // Nothing to switch to: never an empty gallery.
        #expect(GalleryRules.listToOpen(screenTabIsPrivate: false, regularCount: 0, privateCount: 0) == nil)
    }

    @Test func galleryLastCardNeverLeavesAnEmptyGallery() {
        #expect(GalleryRules.afterLastCard(screenTabStillOpen: true, otherListCount: 0) == .openScreenTab)
        #expect(GalleryRules.afterLastCard(screenTabStillOpen: false, otherListCount: 2) == .switchList)
        #expect(GalleryRules.afterLastCard(screenTabStillOpen: false, otherListCount: 0) == .search)
    }
}

@Suite struct ChromeMayHideTests {
    private func page(_ condition: PageCondition = .loaded) -> ChromeState {
        var state = ChromeState()
        state.hasTab = true
        state.hasPage = true
        state.condition = condition
        return state
    }

    @Test func onlyALoadedPageLetsTheBarHide() {
        #expect(ControlRules(page()).chromeMayHide)
        for condition in [PageCondition.loading, .failed, .crashed, .awaitingResubmit] {
            #expect(!ControlRules(page(condition)).chromeMayHide)
        }
        var start = ChromeState()
        start.hasTab = true
        #expect(!ControlRules(start).chromeMayHide)
    }

    @Test func editingFindAndAssistiveTechKeepTheBar() {
        var editing = page()
        editing.isEditing = true
        #expect(!ControlRules(editing).chromeMayHide)
        var finding = page()
        finding.isFindOpen = true
        #expect(!ControlRules(finding).chromeMayHide)
        var voiceOver = page()
        voiceOver.usesAssistiveTech = true
        #expect(!ControlRules(voiceOver).chromeMayHide)
    }

    @Test func theReaderAndTheDuoBarCanHideThePill() {
        var reader = page()
        reader.isReaderOpen = true
        #expect(ControlRules(reader).chromeMayHide)
        var duo = page()
        duo.usesVerticalBar = true
        #expect(ControlRules(duo).chromeMayHide)
    }
}
