#if canImport(UIKit)
import DesignSystem
import Observation
import os
import PerfSignposts
import QuickLook
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
    /// Tabs whose page kept crashing after the engine's automatic reloads.
    var crashedTabs: Set<UUID> = []
    let prompts = PromptQueue()
    /// The file Quick Look shows after "Open" on a finished download.
    let preview = DownloadPreview()
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

    /// After the first frame: warms the engine, then shows the last session's tab under the
    /// search sheet when the user has not opened a page meanwhile.
    func startSession() {
        Task { [weak self, session] in
            let restored = await session.start()
            guard let self, let restored, self.currentTab == nil else { return }
            self.show(restored)
        }
    }

    /// A new tab from the store, on screen.
    @discardableResult
    func openNewTab() -> Tab {
        let tab = session.tabs.newTab()
        show(tab)
        return tab
    }

    /// Puts `tab` on screen in place of the current one, which stays in the store.
    func show(_ tab: Tab) {
        guard self.currentTab !== tab else { return }
        if let current = self.currentTab {
            closeReader(animated: false)
            engineUI.observation?.cancel()
            current.onProgress = nil
            session.pool.detach(current)
        }
        self.currentTab = tab
        session.tabs.select(tab)
        session.pool.attach(tab, to: webContainer)
        webContainer.bringSubviewToFront(engineUI.pageState)
        if let scrollView = session.pool.scrollView(for: tab) {
            scrollView.delegate = self
            scrollView.alwaysBounceVertical = true
            // Hard: the page under the resting bar is obscured anyway, and an opaque edge keeps
            // text from refracting through the glass.
            scrollView.bottomEdgeEffect.style = .hard
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
        tab.onVisit = { [weak self] url, title in
            guard let self, self.recordsHistory else { return }
            self.data.pageVisited(url: url, title: title)
        }
        tab.onVisitTitleChange = { [weak self] url, title in
            guard let self, self.recordsHistory else { return }
            self.data.pageTitleChanged(url: url, title: title)
        }
        engineUI.observation = TabObservation(tab) { [weak self] old, new in
            self?.tabChanged(from: old, to: new)
        }
    }

    /// Closes `tab` and shows the next one (its opener for a popup). With no tab left, the search
    /// field opens, as after the last tab closes (docs/ui-reference.md).
    func closeTab(_ tab: Tab) {
        let wasShown = tab === self.currentTab
        if wasShown {
            closeReader(animated: false)
            engineUI.observation?.cancel()
            engineUI.observation = nil
            self.currentTab = nil
        }
        engineUI.crashedTabs.remove(tab.id)
        let next = session.tabs.close(tab)
        guard wasShown else { return }
        if let next {
            show(next)
        } else {
            pill.display(url: nil)
            updateButtons()
            pillTappedToEdit()
        }
    }

    private func pillTappedToEdit() {
        applyEditingLayout(true, animated: true)
        if !pill.beginEditing() { applyEditingLayout(false, animated: false) }
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
        guard let tab = currentTab else { return state.show(nil) }
        if engineUI.crashedTabs.contains(tab.id) {
            state.show(.init(message: "This page stopped working.", button: "Reload") { [weak tab] in tab?.reload() })
        } else if tab.isAwaitingResubmit {
            state.show(.init(message: "Reload to send the form again.", button: "Reload") { [weak tab] in
                tab?.reload()
            })
        } else if let error = tab.loadError, !tab.isLoading {
            let retry = error.url ?? tab.url
            state.show(.init(message: PageStateView.message(for: error), button: "Try Again") { [weak tab] in
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

    func findOnPage() {
        if let reader = engineUI.reader.webView {
            reader.findInteraction?.presentFindNavigator(showingReplace: false)
        } else {
            currentTab?.findOnPage()
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
            reader.prepare(pool: session.pool, in: self.webContainer, scrollDelegate: self)
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
        attachEdgeEffects()
        updateButtons()
        updatePageInsets()
    }
}

// MARK: - Observing a tab

/// The tab values the chrome shows, compared to find what changed.
struct TabSnapshot: Equatable {
    var url: URL?
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var security: SecurityState
    var loadError: LoadError?
    var isAwaitingResubmit: Bool

    init(_ tab: Tab) {
        url = tab.url
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

// MARK: - Download preview

/// Quick Look's data source for one finished download.
final class DownloadPreview: NSObject, QLPreviewControllerDataSource {
    var file: URL?

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        MainActor.assumeIsolated { file == nil ? 0 : 1 }
    }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { (file ?? URL(fileURLWithPath: "/")) as NSURL }
    }
}
#endif
