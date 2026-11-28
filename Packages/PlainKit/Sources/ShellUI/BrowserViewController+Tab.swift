#if canImport(UIKit)
import BrowserCore
import DesignSystem
import Observation
import os
import PerfSignposts
import Reader
import UIKit
import WebEngine
import WebKit

/// What the browser keeps about the tab on screen besides the tab itself, in one place so
/// `BrowserViewController` gains a single stored property for it.
final class EngineUIState {
    var observation: TabObservation?
    let reader = ReaderPresenter()
    var readerTask: Task<Void, Never>?
    /// What covers a page that can't show. Made on first use (`updatePageState`), never for the
    /// launch's first frame: most launches show no page state at all.
    var pageState: PageStateView {
        if let madePageState { return madePageState }
        let made = PageStateView()
        madePageState = made
        return made
    }
    /// The page state if it was made, for keeping it in front without making it.
    private(set) var madePageState: PageStateView?
    /// Tabs whose next visit the address bar asked for (`VisitKind.typed`).
    var typedVisitTabs: Set<UUID> = []
    /// Tabs whose page kept crashing after the engine's automatic reloads.
    var crashedTabs: Set<UUID> = []
    let prompts = PromptQueue()
    /// Which sites were told that a feature is off for Plain: once per site until it changes.
    /// Private tabs keep theirs apart, dropped with the private session.
    var accessNotices = SystemAccessNoticeMemory()
    var privateAccessNotices = SystemAccessNoticeMemory()
    /// The current tab's network error page was shown because of a switch of Plain's (cellular
    /// data off for Plain): turning it back on retries the page.
    var networkBlockedTab: UUID?
    /// Try Again on the error page, until its load ends (the warning if it fails again).
    var retry = RetryWatch()
    /// Checks a few times a second, while the find bar is open, whether it has closed: UIKit
    /// tells no one when the system find bar goes away (it can close without the keyboard).
    var findWatch: Task<Void, Never>?
    #if DEBUG
    var didPreviewPermissionPrompt = false
    #endif
}

// MARK: - The tab on screen

extension BrowserViewController {
    /// The scroll view on screen: the reader's while it shows, else the tab's page. The collapsing
    /// toolbar and pull to refresh follow it.
    var pageScrollView: UIScrollView? {
        if let reader = engineUI.reader.webView { return reader.scrollView }
        return currentTab.flatMap { session.pool.scrollView(for: $0) }
    }

    var isShowingReader: Bool { engineUI.reader.isShowing }

    /// Back closes the reader, then goes back in the page's history, then closes a popup and
    /// returns to the page that opened it.
    var canGoBack: Bool {
        guard let tab = currentTab else { return false }
        return isShowingReader || tab.canGoBack || returnsToOpener(tab) || summaryUI.returnTab === tab
    }

    /// The tab was opened from another one still open (a popup, a link, a search over a page):
    /// Back on its first page closes it and shows that one again (state rules §8).
    func returnsToOpener(_ tab: Tab) -> Bool {
        if tab.openerID != nil { return true }
        guard let opener = session.tabs.store.tabs[tab.id]?.openerID else { return false }
        return session.tabs.store.tabs[opener] != nil
    }

    func performBack() {
        guard let tab = currentTab else { return }
        dropLaunchCover(animated: true)
        if isShowingReader {
            closeReader(animated: true)
        } else if tab.canGoBack {
            tab.goBack()
        } else if summaryUI.returnTab === tab {
            // A source opened from a summary: Back closes it and the summary comes back.
            closeTab(tab)
            reopenSummary()
        } else if returnsToOpener(tab) {
            closeReturningToOpener(tab)
        }
    }

    /// Back on a link-opened tab's first page closes it and shows its opener with a pop: the
    /// tab's page slides off toward the trailing edge, where Back sends a page, and the opener
    /// slides in from a little behind it (docs/plan.md, motion table, "Back to the opener").
    /// Reduce Motion: the page crossfades to the opener. Nothing waits on it: the opener is live
    /// and takes touches from the first frame.
    private func closeReturningToOpener(_ tab: Tab) {
        let clip = pageClip
        let page = webContainer
        guard view.window != nil, let cover = page.snapshotView(afterScreenUpdates: false) else {
            return closeTab(tab)
        }
        closeTab(tab)
        // The opener (or the tab chosen in its place) holds the same pane; anything else (the
        // search field, the other pane of a split) gets no motion.
        guard currentTab != nil, !isEditingAddress, pageClip === clip, webContainer === page else { return }
        // The swap's own layout (the pill's text, the buttons) lands now, unanimated, so only the
        // pages move: otherwise the pill's host slid in from the side with them.
        UIView.performWithoutAnimation { view.layoutIfNeeded() }
        cover.frame = page.frame
        cover.isUserInteractionEnabled = false
        clip.addSubview(cover)
        if Motion.prefersCrossfade {
            UIView.animate(withDuration: Motion.crossfadeDuration, delay: 0, options: [.allowUserInteraction]) {
                cover.alpha = 0
            } completion: { _ in cover.removeFromSuperview() }
            return
        }
        let direction: CGFloat = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        let width = clip.bounds.width
        // The leaving page's edge casts a soft shadow on the opener, as a popped page does.
        cover.layer.shadowColor = Palette.floatingShadow.resolvedColor(with: traitCollection).cgColor
        cover.layer.shadowOpacity = 0.18
        cover.layer.shadowRadius = 12
        cover.layer.shadowPath = UIBezierPath(rect: cover.bounds).cgPath
        page.transform = CGAffineTransform(translationX: -direction * width * Motion.backToOpenerParallax, y: 0)
        Motion.animate(Motion.backToOpener, changes: {
            cover.transform = CGAffineTransform(translationX: direction * (width + 24), y: 0)
            page.transform = .identity
        }, completion: {
            cover.removeFromSuperview()
        })
    }

    /// Whether `tab`'s visits go into history: never for a private tab.
    func recordsHistory(for tab: Tab) -> Bool {
        !tab.isPrivate
    }

    /// After the first frame: warms the engine, then shows the last session's tab under the
    /// search sheet when the user has not opened a page meanwhile.
    func startSession() {
        data.firstFrameDidCommit()
        // After the first frame: is there a copied link to offer (asked without reading it)?
        refreshCopiedLink()
        Task { [weak self, session] in
            let restored = await session.start()
            guard let self else { return }
            if let restored, self.currentTab == nil { self.show(restored) }
            self.launchSessionRestored(restored)
            // From here a spare gallery may be built at idle: never inside the launch.
            self.tabsUI.isLaunchDone = true
            self.tabsDidChange()
            self.sessionDidLoadForCommands()
            self.tabsUI.tip.start(in: self)
            // Idle tabs move to the archive once both the saved tabs and the settings are in.
            self.archiveIdleTabs()
        }
    }

    /// A new tab from the store, on screen.
    @discardableResult
    func openNewTab() -> Tab {
        let tab = session.tabs.newTab()
        show(tab)
        return tab
    }

    /// Puts `tab` on screen in the focused pane, in place of the current one, which stays in the
    /// store. In a split, a tab already in the other pane gets the focus instead, and the tab it
    /// leaves stays on screen in its own pane.
    func show(_ tab: Tab) {
        guard self.currentTab !== tab else { return }
        tabsUI.swipe.cancel()
        // An empty tab exists only while it is on screen: leaving it drops it (state rules,
        // principle 7), once the new tab has the pane.
        let leftEmpty = currentTab.flatMap { session.tabs.isEmpty($0.id) ? $0 : nil }
        defer { if let leftEmpty { dropEmptyTab(leftEmpty) } }
        // One window, one mode: a tab of the other kind ends a split first.
        endSplitOfOtherMode(before: tab)
        let focusBefore = session.tabs.focusedPane
        // The store decides the pane first: the outgoing tab stays attached if it is still shown.
        session.tabs.select(tab)
        if let current = self.currentTab {
            closeReader(animated: false)
            engineUI.observation?.cancel()
            current.onProgress = nil
            if !isShownInOtherPane(current.id) {
                keepPreview(of: current, beside: tab)
                session.pool.detach(current)
                forgetAttachment(of: current.id)
            } else {
                // It stays on screen in the other pane, which keeps the expanded bar's reserve.
                applyOtherPaneInsets(to: current)
            }
        }
        self.currentTab = tab
        setPrivateChrome(tab.isPrivate)
        // A typed load that ended while the tab was off screen left its marker behind.
        if !tab.isLoading { engineUI.typedVisitTabs.remove(tab.id) }
        if session.tabs.focusedPane != focusBefore { focusDidChange() }
        if tab.id != launchUI.plan.hint?.tabID { dropLaunchCover(animated: false) }
        session.pool.attach(tab, to: webContainer)
        record(tab.id, inSlot: session.tabs.focusedPane)
        keepLaunchCoverOnTop()
        if let state = engineUI.madePageState { webContainer.bringSubviewToFront(state) }
        if let scrollView = session.pool.scrollView(for: tab) {
            scrollView.delegate = self
            scrollView.alwaysBounceVertical = true
            scrollView.hideChromeEdgeEffects()
        }
        // The page's first web view is off screen until attached: size it before insets apply.
        session.pool.defaultPaneSize = webContainer.bounds.size
        view.layoutIfNeeded()
        updatePageInsets()
        // Another tab (the sidebar, a link's new tab): it opens with the whole bar.
        revealChrome(.newTab)

        tab.onProgress = { [weak self, weak tab] progress in
            guard let self, let tab, tab.isLoading, tab === self.currentTab else { return }
            self.pill.progressBar.setProgress(progress)
        }
        tab.onVisit = { [weak self, weak tab] url, title in
            guard let self, let tab else { return }
            let kind: VisitKind = self.engineUI.typedVisitTabs.remove(tab.id) != nil ? .typed : .link
            guard self.recordsHistory(for: tab) else { return }
            self.data.pageVisited(url: url, title: title, kind: kind, profile: tab.profileID)
            self.noteVisit(url: url, title: title)
        }
        tab.onVisitTitleChange = { [weak self, weak tab] url, title in
            guard let self, let tab, self.recordsHistory(for: tab) else { return }
            self.data.pageTitleChanged(url: url, title: title, profile: tab.profileID)
            self.noteVisit(url: url, title: title)
        }
        engineUI.observation = TabObservation(tab) { [weak self] old, new in
            self?.tabChanged(from: old, to: new)
        }
        #if DEBUG
        previewPermissionPromptIfAsked(for: tab)
        #endif
        refreshNeighbourPreviews()
        updateButtons()
        syncPanes()
        // The last tab's web view may have held the keys; the new page takes them.
        claimKeyFocusIfFree()
        // A refresh spinning for the tab left behind ends with it.
        pullIndicator.endRefreshing()
    }

    /// Removes an empty tab the user left, with no Reopen: it never shows as a card or neighbour.
    func dropEmptyTab(_ tab: Tab) {
        // A split's other pane may still show it (focus moved): it is still on screen.
        guard tab !== currentTab, session.tabs.isEmpty(tab.id), !isShownInOtherPane(tab.id) else { return }
        engineUI.crashedTabs.remove(tab.id)
        engineUI.typedVisitTabs.remove(tab.id)
        session.tabs.discard(tab.id)
    }

    /// Takes the page off screen with no tab in its place (the tab on screen is closing, or the
    /// pane shows the start page). A tab still shown in a split's other pane stays attached there.
    func clearPage() {
        tabsUI.swipe.cancel()
        dropLaunchCover(animated: false)
        if let current = currentTab {
            closeReader(animated: false)
            engineUI.observation?.cancel()
            engineUI.observation = nil
            current.onProgress = nil
            if !isShownInOtherPane(current.id) {
                session.pool.detach(current)
                forgetAttachment(of: current.id)
                engineUI.crashedTabs.remove(current.id)
                engineUI.typedVisitTabs.remove(current.id)
            }
        }
        currentTab = nil
        updateHandoff(page: nil, title: "", isPrivate: false)
        pill.display(url: nil)
        pill.progressBar.finish()
        // An empty pane beside a private page is in the window's private mode.
        setPrivateChrome(showsPrivateMode)
        refreshNeighbourPreviews()
        updateButtons()
        updatePageState()
    }

    /// Closes `tab` and shows the next one (its opener for a popup). The last private tab gives the
    /// screen back to the regular tab seen last. With no tab left, the search field opens, as after
    /// the last tab closes (docs/ui-reference.md). `offerReopen` shows the Reopen toast (a close
    /// from the tabs menu) when the close can be undone; it shows over the search field too.
    func closeTab(_ tab: Tab, offerReopen: Bool = false) {
        let wasShown = tab === self.currentTab
        if wasShown { clearPage() }
        engineUI.crashedTabs.remove(tab.id)
        engineUI.typedVisitTabs.remove(tab.id)
        let batchBefore = session.tabs.lastClosedBatchID
        session.tabs.close(tab.id)
        // Only a close that made a batch can be undone (a private tab never does).
        if offerReopen, let batch = session.tabs.lastClosedBatchID, batch != batchBefore {
            self.offerReopen(batch)
        } else if offerReopen {
            // An earlier offer must not read as this close's undo.
            tabsUI.toast.hide(animated: true)
        }
        guard wasShown else { return updateButtons() }
        if let next = session.tabs.selected {
            show(next)
        } else if tab.isPrivate, let regular = session.tabs.mostRecent(private: false) {
            show(session.tabs.tab(regular))
        } else {
            beginAddressEditing()
        }
    }

    /// The chrome's private tint, and private suggestions (no remote ones) in the search field.
    func setPrivateChrome(_ isPrivate: Bool) {
        data.isPrivate = isPrivate
        pullIndicator.isPrivate = isPrivate
        guard pill.isPrivateTint != isPrivate else { return }
        pill.isPrivateTint = isPrivate
        Motion.animate(Motion.quick) {
            self.pill.setPrivate(isPrivate)
            self.duo.top.band.setPrivate(isPrivate)
            self.duo.strip?.setPrivate(isPrivate)
            self.duo.sidebar?.setPrivate(isPrivate)
            self.sheet.setPrivate(isPrivate)
            self.verticalBarBacking.setPrivate(isPrivate)
            self.buttonBar.setPrivate(isPrivate)
            self.tabsUI.toast.setPrivate(isPrivate)
            // The strip under the status bar too, so the whole screen says private, quietly.
            self.view.backgroundColor = isPrivate ? Palette.privateBackground : Paper.background
        }
        // The tab lists swap to the mode's own tabs (one crossfade each, `reloadTabs`).
        duo.sidebar?.reloadTabs()
        duo.strip?.reloadTabs()
    }

    /// Follows the tab's observed state: the pill, the buttons, progress and the page's state.
    private func tabChanged(from old: TabSnapshot?, to new: TabSnapshot) {
        // Try Again that failed again: the warning, as the error page shows again, unless the
        // gallery or a sheet covers it.
        if engineUI.retry.update(
            tab: old == nil ? nil : currentTab?.id, isLoading: new.isLoading, failures: new.loadFailures,
            failedAddress: new.loadError?.url
        ), !isShowingGallery, presentedViewController == nil {
            Haptic.failed.play(in: view)
        }
        if old?.shownAddress != new.shownAddress || old?.security != new.security || old?.isFailed != new.isFailed {
            // A failed load shows the address that was tried, as Share and Copy Link use it
            // (state rules §4), not the page before it. Nothing loaded, so nothing is "Not Secure".
            let notSecure = !new.isFailed && (new.security == .notSecure || new.security == .certificateBypassed)
            pill.display(url: new.shownAddress, notSecure: notSecure)
            if !isEditingAddress { pill.textField.text = new.shownAddress?.absoluteString }
        }
        if let old, old.url != new.url, isShowingReader, !ReaderRenderer.isReaderURL(new.url) {
            // The page went somewhere else under the reader: the article no longer belongs to it.
            closeReader(animated: true)
        }
        if old?.isLoading != new.isLoading {
            if new.isLoading {
                // A new load brings the bar back. Same-document URL changes (pushState) do not.
                if old != nil { expandForNewPage() }
                pill.progressBar.begin()
                pill.progressBar.setProgress(max(0.1, currentTab?.progress ?? 0))
                if let tab = currentTab { engineUI.crashedTabs.remove(tab.id) }
            } else if old != nil {
                pill.progressBar.finish()
                pullIndicator.endRefreshing()
                pullIndicator.prepareColors()
                // A typed load that ended without a new page (it failed): later visits are links.
                if let tab = currentTab { engineUI.typedVisitTabs.remove(tab.id) }
            }
        }
        if old != nil, old?.canTranslate == false, new.canTranslate { offerTranslationOnce() }
        darkPagesPageChanged(from: old, to: new)
        updateButtons()
        updatePageState()
        updateHandoff(page: new.isFailed ? nil : new.url, title: new.title, isPrivate: currentTab?.isPrivate ?? false)
        // A page from the reading list that can't load offline opens its saved copy instead.
        if new.isFailed, old?.isFailed != true, let error = new.loadError, let tried = new.shownAddress,
           ControlRules.opensSavedCopy(errorDomain: error.domain, code: error.code) {
            openSavedCopy(of: tried)
        }
        // A new tab on screen, a new address or a finished load: the side pane follows the page.
        if old == nil || old?.url != new.url || old?.isLoading != new.isLoading { sidePanePageDidChange() }
    }

    // MARK: Page state (crash, error, form waiting)

    /// One sentence and one button over the page when it can't show (docs/ui-reference.md).
    func updatePageState() {
        // Nothing to say and nothing shown yet: the view is not made for a page that loads fine.
        let needed = currentTab.map {
            engineUI.crashedTabs.contains($0.id) || $0.isAwaitingResubmit || ($0.loadError != nil && !$0.isLoading)
        } ?? false
        guard needed || engineUI.madePageState != nil else { return updateStartScreen() }
        let state = engineUI.pageState
        if state.superview !== webContainer {
            state.frame = webContainer.bounds
            state.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webContainer.addSubview(state)
        }
        updateStartScreen()
        guard let tab = currentTab else { return state.show(nil) }
        if engineUI.crashedTabs.contains(tab.id) {
            state.show(.init(message: "This page stopped working.", button: "Reload") { [weak tab] in
                Signposts.signposter.emitEvent(Signposts.pageStateAction, "reload after crash")
                tab?.reload()
            })
        } else if tab.isAwaitingResubmit {
            state.show(.init(message: "Reload to send the form again.", button: "Reload") { [weak tab] in
                Signposts.signposter.emitEvent(Signposts.pageStateAction, "resend form")
                tab?.reload()
            })
        } else if let error = tab.loadError, !tab.isLoading {
            let retry = error.url ?? tab.url
            let tryAgain = { [weak self, weak tab] in
                Signposts.signposter.emitEvent(Signposts.pageStateAction, "try again")
                guard let tab else { return }
                self?.engineUI.retry.begin(tab.id, address: retry, failures: tab.loadFailures)
                if let retry { tab.load(retry) } else { tab.reload() }
            }
            let access = session.pool.systemAccess
            if PageStateView.isNetworkFailure(error, simulated: access.simulatesNetworkBlock),
               let block = access.networkBlock {
                // A switch of Plain's, not the connection: say which, and where to turn it on.
                engineUI.networkBlockedTab = tab.id
                state.show(.init(
                    message: block.notice.message, button: "Open Settings",
                    action: { Self.openSettings() }, secondary: ("Try Again", tryAgain)
                ))
            } else {
                state.show(.init(message: PageStateView.message(for: error), button: "Try Again", action: tryAgain))
            }
        } else {
            state.show(nil)
        }
        if engineUI.networkBlockedTab == tab.id, state.isHidden || tab.loadError == nil { engineUI.networkBlockedTab = nil }
        if !isShowingReader { webContainer.bringSubviewToFront(state) }
    }

    // MARK: Insets

    /// Every inset change goes through here: the page and, while it shows, the reader. Values
    /// come from `updatePageInsets()`, which decides them. The top is the status bar's height
    /// (`pageStatusInset`), the same in every state of the bar.
    func applyPageInsets(obscuredBottom: CGFloat, minimumBottom: CGFloat, expandedBottom: CGFloat) {
        let top = pageStatusInset
        let obscured = UIEdgeInsets(top: top, left: 0, bottom: obscuredBottom, right: 0)
        let minimum = UIEdgeInsets(top: top, left: 0, bottom: minimumBottom, right: 0)
        let maximum = UIEdgeInsets(top: top, left: 0, bottom: expandedBottom, right: 0)
        if let tab = currentTab {
            session.pool.setInsets(for: tab, obscured: obscured, minimumViewport: minimum, maximumViewport: maximum)
            session.pool.scrollView(for: tab)?.followObscuredBottom(obscuredBottom)
            session.pool.scrollView(for: tab)?.showStatusEdgeEffect(top > 0)
        }
        engineUI.reader.setInsets(obscured: obscured, minimumViewport: minimum, maximumViewport: maximum)
        engineUI.reader.webView?.scrollView.showStatusEdgeEffect(top > 0)
    }

    /// Under a bottom bar (phones, the Duo's outer screen) the page runs under the status bar, as
    /// in Safari, and its obscured top inset is the status bar: a fixed header rests just under
    /// the clock, and WebKit extends its color up behind the status bar the way Safari's does. The
    /// page's first line starts under the status bar too: that is the scroll view's safe-area
    /// adjustment (`setPageTopStart(0)`), the same height, so WebKit's own top and the scroll
    /// range's start agree and nothing needs moving after a load.
    var pageStatusInset: CGFloat { view.safeAreaInsets.top }

    // MARK: Page commands

    func reloadPage() {
        dropLaunchCover(animated: true)
        if isShowingReader {
            engineUI.reader.webView?.reload()
        } else {
            currentTab?.reload()
        }
    }

    /// Reload Without Cache: the page and everything on it from the site again. Only where Reload
    /// itself shows (`ControlRules.reloadFromOrigin`), so never under the reader.
    func reloadPageFromOrigin() {
        guard currentRules().reloadFromOrigin else { return Haptic.nothingThere.play() }
        // On screen it looks like any reload, so `tap` says the stronger one was taken.
        Haptic.tap.play()
        dropLaunchCover(animated: true)
        currentTab?.reloadFromOrigin()
    }

    /// Find on Page: in the reader while it shows, else on the page (`Tab.beginFind`, which emits
    /// the signpost itself).
    func findOnPage() {
        // A list of matches beside the page where the side pane can show.
        if currentRules().findInSidePane { return openSidePane(.find, focus: true) }
        if let reader = engineUI.reader.webView {
            Signposts.signposter.emitEvent(Signposts.findOnPage)
            reader.findInteraction?.presentFindNavigator(showingReplace: false)
        } else {
            currentTab?.beginFind()
        }
        // The find bar replaces the bar; when it closes, the whole bar is back.
        revealChrome(.find)
        watchFindBar()
    }

    /// The find bar replaces the page's bar while it is open (state rules §7): the pill and the
    /// buttons fade out, so the find bar never sits on top of them once the keyboard goes down,
    /// and come back when it closes.
    private func watchFindBar() {
        engineUI.findWatch?.cancel()
        setChromeHiddenForFind(true)
        // The Duo's vertical bar empties too (`ControlRules.barShown`).
        updateButtons()
        engineUI.findWatch = Task { [weak self] in
            // The find bar can take a moment to show (it rides in with the keyboard): the chrome
            // stays hidden until it has shown and closed again, or never showed within 2 s.
            var hasShown = false
            var checks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                checks += 1
                let isOpen = self.isFindOpen
                hasShown = hasShown || isOpen
                // Bar gestures follow the rules, which read the find bar when they are applied.
                if isOpen != self.rules.state.isFindOpen { self.updateButtons() }
                guard !isOpen, hasShown || checks >= 8 else { continue }
                self.engineUI.findWatch = nil
                self.setChromeHiddenForFind(false)
                return
            }
        }
    }

    private func setChromeHiddenForFind(_ hidden: Bool) {
        let content = chromeGlass.contentView
        content.isUserInteractionEnabled = !hidden
        let alpha: CGFloat = hidden ? 0 : 1
        guard content.alpha != alpha else { return }
        // Once faded, the whole glass container hides, so the pill and the bar also leave the
        // accessibility tree: the glass exposes its controls even inside a hidden content view.
        // The gallery hides the same container; it cannot open while the find bar is up.
        if !hidden { chromeGlass.isHidden = isShowingGallery }
        // The top band holds nothing while the find bar stands in for the bar.
        duo.top.isHiddenForFind = hidden
        Motion.animate(Motion.quick, changes: { content.alpha = alpha; self.updateTopBandAlpha() }) { [weak self] in
            guard let self, content.alpha == 0, engineUI.findWatch != nil else { return }
            chromeGlass.isHidden = true
        }
    }

    // MARK: Page menu items

    /// Desktop Site, blocking and dark pages for this site, all remembered per site. Desktop Site
    /// and blocking apply by reloading; dark pages applies at once. `desktop`, `blocking` and
    /// `darkPages` are the state rules' answer for the page (§4). Each item is named for what it
    /// controls and checked while it is on (clarity audit 20): under a menu titled Site Settings,
    /// "Turn Off … on This Site" said the same thing three ways and Desktop Site's state not at all.
    func siteMenuItems(
        for tab: Tab, url: URL, desktop showsDesktop: Bool, blocking showsBlocking: Bool, darkPages: Bool
    ) -> [UIMenuElement] {
        guard showsDesktop, let host = url.host() else { return [] }
        let isDesktop = tab.contentMode == .desktop
        let desktop = UIAction(
            title: "Desktop Site", image: UIImage(systemName: "desktopcomputer"), state: isDesktop ? .on : .off
        ) { [weak self, weak tab] _ in
            Signposts.signposter.emitEvent(Signposts.desktopSite)
            // A tick: the state flipped, and the menu is gone before the reload shows (haptics
            // plan, §4.2). Content Blocking and Cookie Banner Blocking tick the same way.
            Haptic.selection.play(in: self?.view)
            tab?.setContentModeOverride(isDesktop ? .mobile : .desktop)
        }
        desktop.accessibilityIdentifier = "menu.desktopSite"
        // The blocking allow-list is saved to disk: a private tab must not add its site to it
        // (the rules leave the toggle out there). Private tabs follow the regular choice instead
        // (polish backlog: a private-only toggle).
        let cookies = cookieBannerMenuItems(for: tab, url: url)
        guard showsBlocking else { return [desktop] + cookies + darkPagesMenuItems(for: tab, shown: darkPages) }

        let blocking = session.isBlockingEnabled(for: url)
        let toggle = UIAction(
            title: "Content Blocking", image: UIImage(systemName: "shield.lefthalf.filled"), state: blocking ? .on : .off
        ) { [weak self, weak tab] _ in
            Haptic.selection.play(in: self?.view)
            self?.session.blocker.setBlockingEnabled(!blocking, forHost: host)
            tab?.reload()
        }
        toggle.accessibilityIdentifier = "menu.blocking"
        return [desktop, toggle] + cookies + darkPagesMenuItems(for: tab, shown: darkPages)
    }

    /// Cookie Banner Blocking for the site, checked while on (state rules §4, `cookieBanners`).
    /// Applies by reloading, like the blocking switch; a private tab keeps it for its session.
    private func cookieBannerMenuItems(for tab: Tab, url: URL) -> [UIMenuElement] {
        let item = currentRules().cookieBanners
        guard item != .hidden else { return [] }
        let isOff = item == .turnOn
        let action = UIAction(
            title: "Cookie Banner Blocking", image: UIImage(systemName: "bubble.left.and.exclamationmark.bubble.right"),
            state: isOff ? .off : .on
        ) { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            Haptic.selection.play(in: self.view)
            self.session.cookieBanners.setOff(!isOff, for: url, isPrivate: tab.isPrivate)
            tab.reload()
        }
        action.accessibilityIdentifier = "menu.cookieBanners"
        return [action]
    }

    /// Show Reader only when the page's readerable check said yes; Hide Reader while it shows.
    func readerMenuItems(_ item: ReaderItem) -> [UIMenuElement] {
        switch item {
        case .hidden:
            return []
        case .hide:
            let hide = UIAction(title: "Hide Reader", image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
                Signposts.signposter.emitEvent(Signposts.readerToggle, "hide")
                self?.closeReader(animated: true)
            }
            hide.accessibilityIdentifier = "menu.reader"
            // On: the sheet's tile shows in the accent while the reader is open.
            hide.state = .on
            return [hide]
        case .show:
            break
        }
        let show = UIAction(title: "Show Reader", image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
            Signposts.signposter.emitEvent(Signposts.readerToggle, "show")
            self?.openReader()
        }
        show.accessibilityIdentifier = "menu.reader"
        return [show]
    }

    // MARK: Reader

    /// Extracts the page's article, then shows it in the reader view over the page.
    func openReader() {
        guard let tab = currentTab, let page = session.pool.webView(for: tab) else { return }
        engineUI.readerTask?.cancel()
        engineUI.readerTask = Task { [weak self, session] in
            let article = try? await session.reader.article(in: page)
            guard let self, !Task.isCancelled, self.currentTab === tab else { return }
            guard let article else { return Haptic.nothingThere.play() }
            await self.presentReader(article, over: tab)
        }
    }

    /// A saved page failed to load for want of the network (`ControlRules.opensSavedCopy`): its
    /// reader copy, if the reading list has one, opens over the error, as if the user had opened
    /// the reader. Back or Hide Reader returns to the error and its Try Again.
    func openSavedCopy(of url: URL) {
        guard let tab = currentTab, !isShowingReader, let failure = tab.loadError else { return }
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.readingListOfflineCopy)
        engineUI.readerTask?.cancel()
        engineUI.readerTask = Task { [weak self, weak tab, data] in
            defer { signposter.endInterval(Signposts.readingListOfflineCopy, state) }
            guard let copy = await data.savedCopy(for: url), let article = await Self.decodeArticle(copy) else { return }
            // Still the same failure: a new load (even one that failed another way, such as a
            // certificate warning that must stay in front) or another tab makes the copy moot.
            guard let self, let tab, !Task.isCancelled, self.currentTab === tab, !tab.isLoading,
                  tab.loadError == failure
            else { return }
            // Once the copy is on screen, say why the page reads as the reader and offer the live
            // page again.
            await self.presentReader(article, over: tab) { [weak self, weak tab] in
                self?.showToastWhenFree { [weak self, weak tab] in
                    self?.tabsUI.toast.show(String(localized: "Showing your saved copy."), button: "Try Again") {
                        guard let self, let tab, self.currentTab === tab else { return }
                        Signposts.signposter.emitEvent(Signposts.pageStateAction, "try again from saved copy")
                        self.closeReader(animated: true)
                        tab.load(url)
                    }
                }
            }
        }
    }

    @concurrent
    nonisolated private static func decodeArticle(_ data: Data) async -> ReaderArticle? {
        try? JSONDecoder().decode(ReaderArticle.self, from: data)
    }

    /// Puts `article` in the reader view over `tab`'s page; `shown` runs once it is on screen.
    private func presentReader(_ article: ReaderArticle, over tab: Tab, shown: (() -> Void)? = nil) async {
        expandChrome(animated: true)
        let reader = engineUI.reader
        reader.onOpenLink = { [weak self] url in
            guard let self, let tab = self.currentTab else { return }
            self.closeReader(animated: true)
            tab.load(url)
        }
        reader.onShown = { [weak self] in
            self?.updateButtons()
            shown?()
        }
        reader.prepare(
            pool: session.pool, isPrivate: tab.isPrivate, profile: tab.profileID, in: webContainer, scrollDelegate: self
        )
        // A tap on the status bar scrolls the reader, not the page under it.
        session.pool.scrollView(for: tab)?.scrollsToTop = false
        updatePageInsets()
        try? await reader.show(article)
        updateButtons()
    }

    /// Back to the page under the reader.
    func closeReader(animated: Bool) {
        engineUI.readerTask?.cancel()
        engineUI.readerTask = nil
        guard isShowingReader else { return }
        engineUI.reader.close(animated: animated)
        if let tab = currentTab { session.pool.scrollView(for: tab)?.scrollsToTop = true }
        updateButtons()
        updatePageInsets()
    }
}

// MARK: - Observing a tab

/// The tab values the chrome shows, compared to find what changed.
struct TabSnapshot: Equatable {
    var url: URL?
    var title: String
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var security: SecurityState
    var loadError: LoadError?
    var loadFailures: Int
    var isAwaitingResubmit: Bool
    /// The page is in a language the user doesn't read (Translate Page applies).
    var canTranslate: Bool
    /// Translated text is on screen (the pill's "Translated —").
    var isTranslated: Bool
    /// What Dark Pages does on the page, and the document that said so, and whether the site has
    /// no light design.
    var darkPages: DarkPagesState
    var darkPagesDocument: String?
    var isLightless: Bool

    init(_ tab: Tab) {
        url = tab.url
        title = tab.title
        isLoading = tab.isLoading
        canGoBack = tab.canGoBack
        canGoForward = tab.canGoForward
        security = tab.security
        loadError = tab.loadError
        loadFailures = tab.loadFailures
        isAwaitingResubmit = tab.isAwaitingResubmit
        canTranslate = tab.translationTarget != nil && tab.translation == .original
        isTranslated = tab.translation == .translated
        darkPages = tab.darkPages
        darkPagesDocument = tab.darkPagesDocument
        isLightless = tab.isLightless
    }

    /// The load failed and nothing newer is loading.
    var isFailed: Bool { loadError != nil && !isLoading }

    /// The address the pill shows: the page's, or the one a failed load tried (`pageAddress`).
    var shownAddress: URL? {
        if isFailed, let tried = loadError?.url { return tried }
        return url
    }
}

/// Calls `changed` when the tab's observed state changes, at most once per main run loop turn
/// however many properties changed, with the values before and after. The first call (old nil)
/// is immediate. Observation instead of KVO: `Tab` is `@Observable`, and changes arrive only a
/// few times per navigation (progress goes through `Tab.onProgress`).
final class TabObservation {
    private weak var tab: Tab?
    private let changed: (TabSnapshot?, TabSnapshot) -> Void
    private var last: TabSnapshot?
    private var isCancelled = false

    init(_ tab: Tab, changed: @escaping (TabSnapshot?, TabSnapshot) -> Void) {
        self.tab = tab
        self.changed = changed
        track()
    }

    func cancel() {
        isCancelled = true
    }

    private func track() {
        guard !isCancelled, let tab else { return }
        let snapshot = withObservationTracking {
            TabSnapshot(tab)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        guard snapshot != last else { return }
        let old = last
        last = snapshot
        changed(old, snapshot)
    }
}

// MARK: - Prompts one at a time

/// The engine's questions wait for each other, so two never fight for the screen.
final class PromptQueue {
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

extension UIScrollView {
    /// Makes the page's scroll range end above the resting chrome: `obscuredContentInsets` places
    /// fixed footers and the viewport, but leaves the range at the safe area, so without this the
    /// page's last lines would stay under the expanded bar. Set with the obscured inset, once per
    /// rest, never per frame: a range change, not a relayout.
    func followObscuredBottom(_ obscuredBottom: CGFloat) {
        let system = adjustedContentInset.bottom - contentInset.bottom
        let bottom = max(0, obscuredBottom - system)
        guard abs(contentInset.bottom - bottom) > 0.5 else { return }
        contentInset.bottom = bottom
    }

    /// Keeps a page that WebKit put at its top under a floating top bar, not behind it. WebKit's
    /// top for a page is its obscured top inset: a load's first paint, a history restore and a
    /// page's own `scrollTo(0, 0)` move the scroll view to exactly minus that inset
    /// (`-[WKWebView _initialContentOffsetForScrollView]`), and under the top bar that inset is the
    /// status strip, not the bar (`TopChromeGeometry.obscuredInset`). The page's top rests lower,
    /// at the scroll range's start under the expanded bar (`setPageTopStart`), so a move to
    /// WebKit's top that no finger made goes on to there, in the same pass, before anything is
    /// drawn. Moves under the finger, a fling's coast and a bounce are the reader's own and are
    /// left alone, and so is a page already there (`previousY`, the offset this scroll view had
    /// at its last callback, nil for none): a horizontal scroll or a zoom's end at a top the
    /// reader left is no move to the top. Returns true when it moved the page.
    func keepPageTopUnderBar(webKitTop: CGFloat, previousY: CGFloat?) -> Bool {
        let start = -adjustedContentInset.top
        guard start < -webKitTop - 0.5, abs(contentOffset.y + webKitTop) < 0.01,
              previousY.map({ abs($0 - contentOffset.y) >= 0.01 }) ?? true,
              !isTracking, !isDecelerating, !isZooming, !isZoomBouncing else { return false }
        contentOffset.y = start
        return true
    }

    /// No scroll edge effect where Plain's chrome floats: the page runs under the bottom pill and
    /// under the inner screen's top bar, and the glass's own dense tint keeps the controls readable
    /// (owner's rule: no band, docs/decisions.md). The top one would otherwise blur and dim a band
    /// under the status row while reading, after the bar has gone. Set where the scroll view is
    /// attached, once; a scroll view whose effects are hidden is left alone.
    func hideChromeEdgeEffects() {
        if !bottomEdgeEffect.isHidden { bottomEdgeEffect.isHidden = true }
        if !topEdgeEffect.isHidden { topEdgeEffect.isHidden = true }
    }

    /// The system's top edge effect under a status bar that spans the page (phones, the Duo's
    /// outer screen), where the page now runs under the status bar: its soft blur keeps the clock
    /// readable over the page's text, as in Safari. It covers the scroll view's top inset, which
    /// there is the status bar alone (the safe area), never Plain's chrome. Off under the inner
    /// screen's top bar, whose inset is the bar's (`hideChromeEdgeEffects`). Set with the insets.
    func showStatusEdgeEffect(_ show: Bool) {
        if topEdgeEffect.isHidden == show { topEdgeEffect.isHidden = !show }
    }
}
#endif
