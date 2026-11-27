#if canImport(UIKit)
import BrowserCore
import DesignSystem
import UIKit
import WebEngine

// MARK: - State rules: describe the state, apply what ControlRules answers

extension BrowserViewController {
    /// The screen's state in the terms of docs/state-rules.md §2. Reads the tab store once per
    /// call (a pass over the open tabs), so hot paths use the cached `rules` instead.
    var chromeState: ChromeState {
        let tabs = session.tabs
        var state = ChromeState()
        state.usesVerticalBar = usesVerticalBar
        state.isEditing = isEditingAddress
        state.hasDownloads = !session.pool.downloads.downloads.isEmpty
        state.sideTabs = duo.layout?.showsSidebar ?? false
        state.canSplit = canSplit
        state.isSplit = isSplit
        state.hasClosed = tabs.canReopenClosedTab
        state.hasArchived = tabs.hasArchivedTabs
        guard let tab = currentTab else {
            state.others = tabs.otherTabCount(besides: nil)
            return state
        }
        state.hasTab = true
        state.isPrivate = tab.isPrivate
        state.hasPage = !tabs.isEmpty(tab.id)
        if engineUI.crashedTabs.contains(tab.id) {
            state.condition = .crashed
        } else if tab.isAwaitingResubmit {
            state.condition = .awaitingResubmit
        } else if tab.loadError != nil, !tab.isLoading {
            state.condition = .failed
        } else {
            state.condition = tab.isLoading ? .loading : .loaded
        }
        state.canGoBack = canGoBack
        state.canGoForward = tab.canGoForward
        state.isReaderOpen = isShowingReader
        state.isFindOpen = isFindOpen
        state.others = tabs.otherTabCount(besides: tab.id)
        // The list the bar swipe moves through: the tab on screen and its list's page tabs.
        state.listCount = tabs.entries(private: tab.isPrivate).count { $0.id == tab.id || !tabs.isEmpty($0.id) }
        let neighbours = tabs.neighbours(of: tab.id)
        state.hasPrevious = neighbours.previous != nil
        state.hasNext = neighbours.next != nil
        if let url = pageAddress {
            let scheme = url.scheme?.lowercased()
            state.isWebPage = scheme == "http" || scheme == "https"
            state.isRecordable = LiveAddressBarData.isRecordable(url)
        }
        state.isPDF = tab.isPDF
        // Both only while Plain is dark: the page reports `.inactive` otherwise.
        state.isDarkened = tab.darkPages == .darkened
        state.isDarkPagesOff = tab.darkPages == .offForSite
        if let page = session.pool.webView(for: tab) {
            state.isReaderAvailable = session.reader.isAvailable(in: page) == true
        }
        return state
    }

    /// The rules for the state right now (fresh, not the cached `rules`).
    func currentRules() -> ControlRules {
        ControlRules(chromeState)
    }

    /// The address the tab on screen is about: its page, or the one a failed load tried.
    var pageAddress: URL? {
        guard let tab = currentTab else { return nil }
        if let error = tab.loadError, !tab.isLoading, let tried = error.url { return tried }
        return tab.url
    }

    /// The system find bar shows over the page or the reader.
    var isFindOpen: Bool {
        let page = engineUI.reader.webView ?? currentTab.flatMap { session.pool.webView(for: $0) }
        return page?.findInteraction?.isFindNavigatorVisible ?? false
    }

    /// Applies the rules to the bar: each control shown, dimmed or hidden in place, and the tabs
    /// slot's face. Called whenever the tab on screen or the tab list changes.
    func updateButtons() {
        rules = currentRules()
        // Under the gallery the page's own buttons rest; Tabs goes back to the page.
        let onPage = !isShowingGallery
        let tabsSlot: ControlVisibility = rules.tabsSlot == .hidden ? .hidden : .shown
        let visibility: [PageButton: ControlVisibility] = [
            .back: rules.back,
            .forward: rules.forward,
            .tabs: tabsSlot,
            .share: rules.share,
            .more: rules.more,
        ]
        for (kind, rule) in visibility {
            let applied = onPage || kind == .tabs ? rule : (rule.isVisible ? .dimmed : .hidden)
            buttonBar.setVisibility(applied, for: kind)
            guard let item = barItems[kind] else { continue }
            if item.isHidden == applied.isVisible { item.isHidden = !applied.isVisible }
            if item.isEnabled != applied.isEnabled { item.isEnabled = applied.isEnabled }
        }
        applyTabsFace(rules.tabsSlot)
        duo.sidebar?.setNewTabShown(rules.menuNewTab)
        if !tabsUI.start.isHidden { applyStartShortcuts() }
        applyToolbarItems()
        updateBarShapeIfNeeded()
    }

    /// The system's vertical bar (Duo) holds the page buttons only where the bar shows (state
    /// rules: hidden while editing, the gallery has its own). It empties rather than hides, so its
    /// column keeps its width and nothing under it lays out again.
    func applyToolbarItems() {
        // Kept in step in either bar mode, so a switch to the vertical bar finds them right.
        let items = rules.barShown && !isShowingGallery ? PageButton.allCases.compactMap { barItems[$0] } : []
        guard (toolbarItems ?? []) != items else { return }
        setToolbarItems(items, animated: true)
    }

    /// The tabs slot's face: Tabs, or New Tab with one page tab. The long press is the tabs menu
    /// whatever it shows. VoiceOver hears how many tabs are open (no badge).
    private func applyTabsFace(_ face: TabsSlotFace) {
        let isNewTab = face == .newTab
        let symbol = isNewTab ? "plus" : PageButton.tabs.symbol
        let title = isNewTab ? String(localized: "New Tab") : PageButton.tabs.title
        let open = rules.state.others + (rules.state.hasPage ? 1 : 0)
        let value = open == 1 ? String(localized: "1 tab") : String(localized: "\(open) tabs")
        buttonBar.setFace(of: .tabs, symbol: symbol, title: title, value: value)
        if let item = barItems[.tabs], item.title != title {
            item.image = UIImage(systemName: symbol)
            item.title = title
            item.accessibilityLabel = title
        }
        barItems[.tabs]?.accessibilityValue = value
    }
}
#endif
