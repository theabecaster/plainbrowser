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
    let pageState = PageStateView()
    /// Tabs whose next visit the address bar asked for (`VisitKind.typed`).
    var typedVisitTabs: Set<UUID> = []
    /// Tabs whose page kept crashing after the engine's automatic reloads.
    var crashedTabs: Set<UUID> = []
    let prompts = PromptQueue()
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
        return isShowingReader || tab.canGoBack || tab.openerID != nil
    }

    func performBack() {
        guard let tab = currentTab else { return }
        if isShowingReader {
            closeReader(animated: true)
        } else if tab.canGoBack {
            tab.goBack()
        } else if tab.openerID != nil {
            closeTab(tab)
        }
    }

    /// Whether `tab`'s visits go into history: never for a private tab.
    func recordsHistory(for tab: Tab) -> Bool {
        !tab.isPrivate
    }

    /// After the first frame: warms the engine, then shows the last session's tab under the
    /// search sheet when the user has not opened a page meanwhile.
    func startSession() {
        data.firstFrameDidCommit()
        Task { [weak self, session] in
            let restored = await session.start()
            guard let self else { return }
            if let restored, self.currentTab == nil { self.show(restored) }
            self.tabsDidChange()
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
            }
        }
        self.currentTab = tab
        setPrivateChrome(tab.isPrivate)
        // A typed load that ended while the tab was off screen left its marker behind.
        if !tab.isLoading { engineUI.typedVisitTabs.remove(tab.id) }
        if session.tabs.focusedPane != focusBefore { focusDidChange() }
        session.pool.attach(tab, to: webContainer)
        record(tab.id, inSlot: session.tabs.focusedPane)
        webContainer.bringSubviewToFront(engineUI.pageState)
        if let scrollView = session.pool.scrollView(for: tab) {
            scrollView.delegate = self
            scrollView.alwaysBounceVertical = true
            // No edge effect: the page runs under the bar and the pill floats on it (owner's
            // choice). The pill's own dense glass keeps its text readable.
            scrollView.bottomEdgeEffect.isHidden = true
        }
        attachEdgeEffects()
        // The page's first web view is off screen until attached: size it before insets apply.
        session.pool.defaultPaneSize = webContainer.bounds.size
        view.layoutIfNeeded()
        updatePageInsets()

        tab.onProgress = { [weak self, weak tab] progress in
            guard let self, let tab, tab.isLoading, tab === self.currentTab else { return }
            self.pill.progressBar.setProgress(progress)
        }
        tab.onVisit = { [weak self, weak tab] url, title in
            guard let self, let tab else { return }
            let kind: VisitKind = self.engineUI.typedVisitTabs.remove(tab.id) != nil ? .typed : .link
            guard self.recordsHistory(for: tab) else { return }
            self.data.pageVisited(url: url, title: title, kind: kind)
        }
        tab.onVisitTitleChange = { [weak self, weak tab] url, title in
            guard let self, let tab, self.recordsHistory(for: tab) else { return }
            self.data.pageTitleChanged(url: url, title: title)
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
    }

    /// Takes the page off screen with no tab in its place (the tab on screen is closing, or the
    /// pane shows the start page). A tab still shown in a split's other pane stays attached there.
    func clearPage() {
        tabsUI.swipe.cancel()
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
        pill.display(url: nil)
        pill.progressBar.finish()
        setPrivateChrome(false)
        refreshNeighbourPreviews()
        updateButtons()
        updatePageState()
    }

    /// Closes `tab` and shows the next one (its opener for a popup). With no tab left, the search
    /// field opens, as after the last tab closes (docs/ui-reference.md). `offerReopen` shows the
    /// Reopen toast (a close from the tabs menu).
    func closeTab(_ tab: Tab, offerReopen: Bool = false) {
        let wasShown = tab === self.currentTab
        if wasShown { clearPage() }
        engineUI.crashedTabs.remove(tab.id)
        engineUI.typedVisitTabs.remove(tab.id)
        session.tabs.close(tab.id)
        if offerReopen, !tab.isPrivate { self.offerReopen() }
        guard wasShown else { return }
        if let next = session.tabs.selected {
            show(next)
        } else {
            beginAddressEditing()
        }
    }

    /// The chrome's private tint, and private suggestions (no remote ones) in the search field.
    func setPrivateChrome(_ isPrivate: Bool) {
        data.isPrivate = isPrivate
        guard pill.isPrivateTint != isPrivate else { return }
        pill.isPrivateTint = isPrivate
        Motion.animate(Motion.quick) {
            self.pill.setPrivate(isPrivate)
            self.buttonBar.setPrivate(isPrivate)
            self.tabsUI.toast.setPrivate(isPrivate)
            // The strip under the status bar too, so the whole screen says private, quietly.
            self.view.backgroundColor = isPrivate ? Palette.privateBackground : Palette.background
        }
    }

    /// Follows the tab's observed state: the pill, the buttons, progress and the page's state.
    private func tabChanged(from old: TabSnapshot?, to new: TabSnapshot) {
        if old?.url != new.url || old?.security != new.security {
            pill.display(url: new.url, notSecure: new.security == .notSecure || new.security == .certificateBypassed)
            if !isEditingAddress { pill.textField.text = new.url?.absoluteString }
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
                // A typed load that ended without a new page (it failed): later visits are links.
                if let tab = currentTab { engineUI.typedVisitTabs.remove(tab.id) }
            }
        }
        updateButtons()
        updatePageState()
    }

    // MARK: Page state (crash, error, form waiting)

    /// One sentence and one button over the page when it can't show (docs/ui-reference.md).
    func updatePageState() {
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
            state.show(.init(message: PageStateView.message(for: error), button: "Try Again") { [weak tab] in
                Signposts.signposter.emitEvent(Signposts.pageStateAction, "try again")
                if let retry { tab?.load(retry) } else { tab?.reload() }
            })
        } else {
            state.show(nil)
        }
        if !isShowingReader { webContainer.bringSubviewToFront(state) }
    }

    // MARK: Insets

    /// The chrome's scroll edge effects follow the scroll view on screen: the reader's or the page's.
    func attachEdgeEffects() {
        for effect in pageEdgeEffects { effect.scrollView = pageScrollView }
    }

    /// Every inset change goes through here: the page and, while it shows, the reader. Values
    /// come from `updatePageInsets()`, which decides them.
    func applyPageInsets(obscuredBottom: CGFloat, collapsedBottom: CGFloat, expandedBottom: CGFloat) {
        let obscured = UIEdgeInsets(top: 0, left: 0, bottom: obscuredBottom, right: 0)
        let minimum = UIEdgeInsets(top: 0, left: 0, bottom: collapsedBottom, right: 0)
        let maximum = UIEdgeInsets(top: 0, left: 0, bottom: expandedBottom, right: 0)
        if let tab = currentTab {
            session.pool.setInsets(for: tab, obscured: obscured, minimumViewport: minimum, maximumViewport: maximum)
        }
        engineUI.reader.setInsets(obscured: obscured, minimumViewport: minimum, maximumViewport: maximum)
    }

    // MARK: Page commands

    func reloadPage() {
        if isShowingReader {
            engineUI.reader.webView?.reload()
        } else {
            currentTab?.reload()
        }
    }

    /// Find on Page: in the reader while it shows, else on the page (`Tab.beginFind`, which emits
    /// the signpost itself).
    func findOnPage() {
        if let reader = engineUI.reader.webView {
            Signposts.signposter.emitEvent(Signposts.findOnPage)
            reader.findInteraction?.presentFindNavigator(showingReplace: false)
        } else {
            currentTab?.beginFind()
        }
    }

    // MARK: Page menu items

    /// Desktop Site and blocking for this site, both remembered per site and applied by reloading.
    func siteMenuItems(for tab: Tab, url: URL) -> [UIMenuElement] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host()
        else { return [] }
        let isDesktop = tab.contentMode == .desktop
        let desktop = UIAction(
            title: "Desktop Site", image: UIImage(systemName: "desktopcomputer"), state: isDesktop ? .on : .off
        ) { [weak tab] _ in
            Signposts.signposter.emitEvent(Signposts.desktopSite)
            tab?.setContentModeOverride(isDesktop ? .mobile : .desktop)
        }
        desktop.accessibilityIdentifier = "menu.desktopSite"
        // The blocking allow-list is saved to disk: a private tab must not add its site to it.
        // Private tabs follow the regular choice instead (polish backlog: a private-only toggle).
        guard !tab.isPrivate else { return [desktop] }

        let blocking = session.isBlockingEnabled(for: url)
        let toggle = UIAction(
            title: blocking ? "Turn Off Blocking on This Site" : "Turn On Blocking on This Site",
            image: UIImage(systemName: blocking ? "shield.slash" : "checkmark.shield")
        ) { [weak self, weak tab] _ in
            self?.session.blocker.setBlockingEnabled(!blocking, forHost: host)
            tab?.reload()
        }
        toggle.accessibilityIdentifier = "menu.blocking"
        return [desktop, toggle]
    }

    /// Show Reader only when the page's readerable check said yes; Hide Reader while it shows.
    func readerMenuItems(for tab: Tab) -> [UIMenuElement] {
        if isShowingReader {
            let hide = UIAction(title: "Hide Reader", image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
                Signposts.signposter.emitEvent(Signposts.readerToggle, "hide")
                self?.closeReader(animated: true)
            }
            hide.accessibilityIdentifier = "menu.reader"
            return [hide]
        }
        guard let page = session.pool.webView(for: tab), session.reader.isAvailable(in: page) == true else {
            return []
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
            self.expandChrome(animated: true)
            let reader = self.engineUI.reader
            reader.onOpenLink = { [weak self] url in
                guard let self, let tab = self.currentTab else { return }
                self.closeReader(animated: true)
                tab.load(url)
            }
            reader.onShown = { [weak self] in self?.updateButtons() }
            reader.prepare(pool: session.pool, isPrivate: tab.isPrivate, in: self.webContainer, scrollDelegate: self)
            // A tap on the status bar scrolls the reader, not the page under it.
            session.pool.scrollView(for: tab)?.scrollsToTop = false
            self.attachEdgeEffects()
            self.updatePageInsets()
            try? await reader.show(article)
            self.updateButtons()
        }
    }

    /// Back to the page under the reader.
    func closeReader(animated: Bool) {
        engineUI.readerTask?.cancel()
        engineUI.readerTask = nil
        guard isShowingReader else { return }
        engineUI.reader.close(animated: animated)
        if let tab = currentTab { session.pool.scrollView(for: tab)?.scrollsToTop = true }
        attachEdgeEffects()
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
    var isAwaitingResubmit: Bool

    init(_ tab: Tab) {
        url = tab.url
        title = tab.title
        isLoading = tab.isLoading
        canGoBack = tab.canGoBack
        canGoForward = tab.canGoForward
        security = tab.security
        loadError = tab.loadError
        isAwaitingResubmit = tab.isAwaitingResubmit
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

#endif
