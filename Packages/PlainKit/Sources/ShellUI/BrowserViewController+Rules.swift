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
        state.canShowSidePane = duo.layout?.sidePaneAvailable ?? false
        state.isSidePaneOpen = isSidePaneShown
        state.hasClosed = tabs.canReopenClosedTab
        state.hasArchived = tabs.hasArchivedTabs
        state.usesAssistiveTech = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        state.isAIAvailable = session.summaries.isAvailable
        state.queryIsSearch = isEditingAddress && Self.isSearch(pill.textField.text ?? "")
        guard let tab = currentTab else {
            state.others = tabs.otherTabCount(besides: nil) + tabs.otherProfilesTabCount
            // The last tab's picture stands in until the restored session is in.
            if let hint = launchUI.placeholder { placeholderState(hint, into: &state) }
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
        // Tabs of other profiles count: the switcher is the way to them.
        state.others = tabs.otherTabCount(besides: tab.id) + tabs.otherProfilesTabCount
        // The list the bar swipe moves through: the tab on screen and its list's page tabs.
        state.listCount = tabs.entries(private: tab.isPrivate).count { $0.id == tab.id || !tabs.isEmpty($0.id) }
        let neighbours = tabs.neighbours(of: tab.id)
        state.hasPrevious = neighbours.previous != nil
        state.hasNext = neighbours.next != nil
        if let url = pageAddress {
            let scheme = url.scheme?.lowercased()
            state.isWebPage = scheme == "http" || scheme == "https"
            state.isRecordable = LiveAddressBarData.isRecordable(url)
            state.isCookieBannersOff = session.cookieBanners.isOff(for: url, isPrivate: tab.isPrivate)
        }
        state.isPDF = tab.isPDF
        state.isForeignLanguage = tab.translationTarget != nil
        if let language = tab.pageLanguage {
            state.isUnreadLanguage = !PageLanguage.isRead(language.maximalIdentifier, preferred: Locale.preferredLanguages)
        }
        state.isTranslated = tab.translation != .original
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
        guard let tab = currentTab else { return launchUI.placeholder?.url }
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
        // The pill names the page's mode (Reader, Translated) where it says Not Secure.
        pill.setMode(reader: rules.state.isReaderOpen, translated: rules.state.isTranslated)
        // A state that no longer lets the bar hide (a load, an error, VoiceOver) brings it back.
        chromeRulesChanged()
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
        applyTabsFace()
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
        // A card growing into its page brings the page's buttons back with it, not after it.
        let galleryUp = isShowingGallery && tabsUI.galleryTransition?.destination != .page
        let items = rules.barShown && !galleryUp ? PageButton.allCases.compactMap { barItems[$0] } : []
        guard (toolbarItems ?? []) != items else { return }
        setToolbarItems(items, animated: true)
    }

    /// The tabs slot's face: always Tabs where it shows; the long press is the tabs menu.
    /// VoiceOver hears how many tabs are open and, with two or more profiles, the window's
    /// profile ("3 tabs, Work"; no badge).
    private func applyTabsFace() {
        let open = rules.state.others + (rules.state.hasPage ? 1 : 0)
        let count = open == 1 ? String(localized: "1 tab") : String(localized: "\(open) tabs")
        let value = shownProfileName.map { "\(count), \($0)" } ?? count
        buttonBar.setAccessibilityValue(value, for: .tabs)
        barItems[.tabs]?.accessibilityValue = value
    }
}
#endif
