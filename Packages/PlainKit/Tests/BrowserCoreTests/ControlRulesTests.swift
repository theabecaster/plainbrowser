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
        #expect(!rules.swipeUpOpensGallery)
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

    @Test func onePageNoOthersTurnsTheSlotIntoNewTab() {
        let rules = ControlRules(Self.page())
        #expect(rules.tabsSlot == .newTab)
        #expect(!rules.swipeUpOpensGallery)
        #expect(!rules.menuShowAllTabs)
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
        #expect(rules.tabsSlot == .newTab)
        #expect(!rules.swipeUpOpensGallery)
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

    @Test func editingHidesTheBarAndItsGestures() {
        var state = Self.page(others: 2)
        state.isEditing = true
        let rules = ControlRules(state)
        #expect(!rules.barShown)
        #expect(!rules.acceptsBarGestures)
        #expect(ControlRules(Self.firstRun).barShown)
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
        state.condition = .failed
        #expect(!ControlRules(state).openInOtherPane)
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
