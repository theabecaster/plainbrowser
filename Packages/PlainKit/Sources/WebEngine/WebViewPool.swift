#if canImport(UIKit)
import BrowserCore
import os
import PerfSignposts
import Storage
import UIKit
import WebKit

/// Owns every `WKWebView` the app shows (AGENTS.md: one owner per piece of state). The shell asks
/// the pool for tabs and puts them on screen with `attach(_:to:)`; it never creates, keeps or
/// configures a web view itself.
///
/// Tabs move between three tiers (docs/plan.md, "Engine rules" 2):
/// - **Live:** attached tabs plus the most recent others, up to `EngineChoices.maxLiveTabs`
///   (`FixedChoices.extraLiveTabs` beyond the visible ones). Hidden live tabs are throttled.
/// - **Suspended:** the next `EngineChoices.maxSuspendedTabs`. WebKit suspends their pages.
/// - **Discarded:** the rest. Only `interactionState` and sessionStorage stay, in memory and in
///   Storage's `TabStateStore`; the web view is released. A memory warning discards every tab
///   that is not on screen.
public final class WebViewPool {
    /// The shell. Without one, popups are refused, dialogs dismissed and permissions denied.
    public weak var host: (any EngineHost)?

    /// The size of a page pane when the tab is not attached: the shell sets it to its main pane's
    /// size. Attached tabs use their container's bounds. Desktop or mobile is decided from it when
    /// a navigation starts, never on resize (a switch would force a reload).
    public var defaultPaneSize = CGSize(width: 390, height: 844)

    public let downloads: DownloadCoordinator
    public let thumbnails: ThumbnailService

    private let baseConfiguration: WKWebViewConfiguration
    private let tabStates: TabStateStore?
    private let permissionStore: any SitePermissionStore
    private let contentModes: any SiteContentModeStore
    private let contentRules: (any UserContentRules)?
    let trustExceptions = ServerTrustExceptions()

    private var slots: [UUID: Slot] = [:]
    private var warm: (webView: WKWebView, controller: WKUserContentController)?
    private var useClock: UInt64 = 0
    private var popupLimiter = RateLimiter(limit: EngineChoices.popupLimit, window: EngineChoices.popupWindow)
    private var dialogLimiter = RateLimiter(limit: EngineChoices.dialogLimit, window: EngineChoices.dialogWindow)
    private var externalLimiter = RateLimiter(
        limit: EngineChoices.externalAppLimit, window: EngineChoices.externalAppWindow
    )
    private var crashLimiter = RateLimiter(limit: EngineChoices.crashReloadLimit, window: EngineChoices.crashWindow)
    private var memoryWarningObserver: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - dataStore: one store for every tab, so cookies and logins are shared. A private-tabs
    ///     pool passes `.nonPersistent()`.
    ///   - tabStates: where discarded tabs' state is written; nil keeps it in memory only.
    ///   - permissionStore: remembered camera, microphone, location and motion answers.
    ///   - contentModes: remembered desktop/mobile choices from the page menu.
    ///   - contentRules: content blocking, applied to each web view's own controller.
    ///   - thumbnailDirectory: where thumbnails are written. Defaults to Caches/Thumbnails.
    ///   - downloadDirectory: where downloads go. Defaults to Documents/Downloads (Files-visible).
    public init(
        dataStore: WKWebsiteDataStore = .default(),
        tabStates: TabStateStore? = nil,
        permissionStore: any SitePermissionStore = InMemorySitePermissionStore(),
        contentModes: any SiteContentModeStore = InMemorySiteContentModeStore(),
        contentRules: (any UserContentRules)? = nil,
        thumbnailDirectory: URL? = nil,
        downloadDirectory: URL? = nil
    ) {
        baseConfiguration = Self.makeBaseConfiguration(dataStore: dataStore)
        self.tabStates = tabStates
        self.permissionStore = permissionStore
        self.contentModes = contentModes
        self.contentRules = contentRules
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        thumbnails = ThumbnailService(directory: thumbnailDirectory ?? caches.appending(path: "Thumbnails"))
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloads = DownloadCoordinator(
            directory: downloadDirectory ?? documents.appending(path: EngineChoices.downloadsFolderName)
        )
        downloads.pool = self
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMemoryWarning() }
        }
    }

    // MARK: - Configuration

    private static func makeBaseConfiguration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = EngineChoices.applicationNameForUserAgent
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        // Like Safari: muted video autoplays, sound waits for a tap.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        // Pinch zoom works on every page, as in Safari.
        configuration.ignoresViewportScaleLimits = true

        let preferences = configuration.preferences
        preferences.isElementFullscreenEnabled = true
        preferences.inactiveSchedulingPolicy = .suspend
        // WebKit then asks `createWebViewWith` only for popups a user gesture opened.
        preferences.javaScriptCanOpenWindowsAutomatically = false
        preferences.isFraudulentWebsiteWarningEnabled = true

        let page = configuration.defaultWebpagePreferences!
        page.preferredHTTPSNavigationPolicy = .automaticFallbackToHTTP
        // `.maximizeCompatibility` turns the JIT off (docs/research/notes.md).
        page.securityRestrictionMode = .none
        return configuration
    }

    /// Every web view gets its own copy of the configuration and its own
    /// `WKUserContentController`, so per-site content-blocking changes stay in one tab.
    private func makeConfiguration() -> (WKWebViewConfiguration, WKUserContentController) {
        let configuration = baseConfiguration.copy() as! WKWebViewConfiguration
        let controller = makeController()
        configuration.userContentController = controller
        return (configuration, controller)
    }

    private func makeController() -> WKUserContentController {
        let controller = WKUserContentController()
        controller.addUserScript(UserScripts.preconnect)
        return controller
    }

    private func makeWebView(configuration: WKWebViewConfiguration, controller: WKUserContentController) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.allowsBackForwardNavigationGestures = true
        contentRules?.apply(to: controller, forMainFrameURL: nil)
        return webView
    }

    // MARK: - Warm-up (docs/plan.md, "Engine rules" 1)

    /// Creates one offscreen web view and starts its WebContent and Networking processes. The first
    /// web view costs 47–100+ ms; later ones 2–8 ms (docs/research/notes.md). Call it once the first
    /// frame is on screen, never before. The first tab that needs a web view gets this one.
    ///
    /// It loads an empty HTML string, which leaves no back/forward item (measured: the first real
    /// load has an empty back list), so Back never leads to a blank page.
    public func warmUp() {
        guard warm == nil else { return }
        let state = Signposts.signposter.beginInterval(Signposts.webViewWarmUp)
        let (configuration, controller) = makeConfiguration()
        let webView = makeWebView(configuration: configuration, controller: controller)
        webView.loadHTMLString("", baseURL: nil)
        warm = (webView, controller)
        Signposts.signposter.endInterval(Signposts.webViewWarmUp, state)
    }

    /// Takes the warmed web view, or makes a new one.
    private func takeWebView() -> (WKWebView, WKUserContentController) {
        if let warm {
            self.warm = nil
            return warm
        }
        let (configuration, controller) = makeConfiguration()
        return (makeWebView(configuration: configuration, controller: controller), controller)
    }

    /// A configured web view the caller owns. Only for M0's `BrowserViewController`, which predates
    /// tabs; new code uses `makeTab` and `attach(_:to:)`.
    @available(*, deprecated, message: "Use makeTab(id:restoring:) and attach(_:to:).")
    public func dequeueWebView() -> WKWebView {
        takeWebView().0
    }

    // MARK: - Tabs

    /// A new tab, without a web view until it is attached or loads something. Pass `restoring` to
    /// bring back a tab from a previous launch: it restores history, scroll and sessionStorage on
    /// first attach.
    public func makeTab(id: UUID = UUID(), restoring state: TabRestorationState? = nil) -> Tab {
        Tab(id: id, openerID: nil, pool: self, restoring: state)
    }

    /// Puts `tab`'s page into `container`, filling it, and makes it live. A discarded tab is
    /// restored. Moving an attached tab to another container (the other Duo pane) re-parents the
    /// same web view without a reload.
    public func attach(_ tab: Tab, to container: UIView) {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabAttach, id: signposter.makeSignpostID())
        let slot = ensureSlot(for: tab)
        slot.isDiscarding = false
        slot.container = container
        slot.lastUse = tick()
        let webView = slot.webView
        if webView.superview !== container {
            webView.frame = container.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(webView)
        }
        if slot.needsReload {
            slot.needsReload = false
            reloadAfterCrash(slot, tab: tab)
        } else if webView.url == nil, !webView.isLoading, !slot.isRestoring, let url = tab.url {
            // The WebContent process died while hidden and WebKit never told us.
            webView.load(URLRequest(url: url))
        }
        enforceTiers()
        signposter.endInterval(Signposts.tabAttach, interval)
    }

    /// Takes `tab` off screen: stores a thumbnail and applies the tier limits. It stays live until
    /// newer tabs push it down.
    public func detach(_ tab: Tab) {
        guard let slot = slots[tab.id], slot.container != nil else { return }
        thumbnails.capture(slot.webView, for: tab)
        slot.webView.removeFromSuperview()
        slot.container = nil
        enforceTiers()
    }

    /// Releases everything the pool holds for `tab`: web view, thumbnail and saved state.
    public func close(_ tab: Tab) {
        if let slot = slots.removeValue(forKey: tab.id) {
            tearDown(slot)
        }
        tab.restoration = nil
        tab.tier = .discarded
        tab.pool = nil
        thumbnails.remove(tab.id)
        popupLimiter.reset(tab.id)
        dialogLimiter.reset(tab.id)
        externalLimiter.reset(tab.id)
        crashLimiter.reset(tab.id)
        if let tabStates {
            Task { await tabStates.delete([tab.id]) }
        }
        enforceTiers()
    }

    /// Stores a thumbnail of an attached tab now, for example before the gallery opens over it.
    public func captureThumbnail(of tab: Tab) {
        guard let slot = slots[tab.id], slot.container != nil else { return }
        thumbnails.capture(slot.webView, for: tab)
    }

    /// The tab's last thumbnail, decoded off the main thread and prepared for display.
    public func thumbnail(for tab: Tab) async -> UIImage? {
        await thumbnails.thumbnail(for: tab.id)
    }

    /// The page's scroll view, for the collapsing toolbar's scroll delegate. Nil when the tab has
    /// no web view.
    public func scrollView(for tab: Tab) -> UIScrollView? {
        slots[tab.id]?.webView.scrollView
    }

    /// Sets the insets the toolbar covers. `obscured` relayouts the page every time it is set, so
    /// set it once to the collapsed size and again only when the bar settles; animate the bar with
    /// transform and alpha (docs/plan.md, "Engine rules" 4).
    public func setInsets(
        for tab: Tab, obscured: UIEdgeInsets, minimumViewport: UIEdgeInsets, maximumViewport: UIEdgeInsets
    ) {
        guard let webView = slots[tab.id]?.webView else { return }
        if webView.obscuredContentInsets != obscured { webView.obscuredContentInsets = obscured }
        webView.setMinimumViewportInset(minimumViewport, maximumViewportInset: maximumViewport)
    }

    /// Discards every tab that is not on screen (Firefox's fix for watchdog kills). Called on
    /// `UIApplication.didReceiveMemoryWarningNotification`.
    public func handleMemoryWarning() {
        warm = nil
        thumbnails.dropMemoryCache()
        for slot in slots.values where slot.container == nil {
            discard(slot)
        }
    }

    /// The tier each tab is in, for tests and debugging.
    var liveWebViewCount: Int { slots.count }

    // MARK: - Commands from Tab

    func load(_ url: URL, in tab: Tab) {
        let slot = ensureSlot(for: tab)
        slot.whenRestored { webView in webView.load(URLRequest(url: url)) }
        if slot.container == nil { enforceTiers() }
    }

    func reload(_ tab: Tab) {
        if let slot = slots[tab.id] {
            if slot.webView.url == nil, let url = tab.url {
                slot.webView.load(URLRequest(url: url))
            } else {
                slot.webView.reload()
            }
        } else {
            _ = ensureSlot(for: tab)
            enforceTiers()
        }
    }

    /// The tab's web view, created (and restored) if it was discarded.
    func webView(for tab: Tab) -> WKWebView? {
        guard tab.pool === self else { return nil }
        return ensureSlot(for: tab).webView
    }

    func existingWebView(for tab: Tab) -> WKWebView? {
        slots[tab.id]?.webView
    }

    func isAttached(_ tab: Tab) -> Bool {
        slots[tab.id]?.container != nil
    }

    func setContentModeOverride(_ mode: ContentMode?, for tab: Tab) {
        guard let site = NavigationRules.siteKey(for: tab.url) else { return }
        contentModes.setContentMode(mode, forSite: site)
        reload(tab)
    }

    func restorationState(for tab: Tab) async -> TabRestorationState {
        guard let slot = slots[tab.id] else {
            return tab.restoration
                ?? TabRestorationState(url: tab.url, title: tab.title, interactionState: nil, sessionStorage: nil)
        }
        let webView = slot.webView
        let interaction = webView.interactionState as? Data
        let session = try? await webView.fetchData(of: .sessionStorage)
        return TabRestorationState(url: tab.url, title: tab.title, interactionState: interaction, sessionStorage: session)
    }

    // MARK: - Slots and tiers

    private func tick() -> UInt64 {
        useClock += 1
        return useClock
    }

    @discardableResult
    private func ensureSlot(for tab: Tab) -> Slot {
        if let slot = slots[tab.id] { return slot }
        let (webView, controller) = takeWebView()
        let slot = Slot(tab: tab, webView: webView, controller: controller, pool: self)
        slot.lastUse = tick()
        slots[tab.id] = slot
        tab.set(\.tier, .live)
        if let state = tab.restoration {
            tab.restoration = nil
            restore(state, into: slot)
        }
        return slot
    }

    /// Brings a discarded tab back: sessionStorage first (it must be in place before the page
    /// loads), then `interactionState`, which loads the current history item.
    private func restore(_ state: TabRestorationState, into slot: Slot) {
        let signposter = Signposts.signposter
        slot.restoreInterval = signposter.beginInterval(Signposts.tabRestore, id: signposter.makeSignpostID())
        slot.isRestoring = true
        let webView = slot.webView
        let finish: () -> Void = { [weak slot] in
            guard let slot, slot.isRestoring else { return }
            if let interaction = state.interactionState {
                webView.interactionState = interaction
            } else if let url = state.url {
                webView.load(URLRequest(url: url))
            } else {
                slot.endRestoreInterval()
            }
            slot.isRestoring = false
            slot.runPendingAfterRestore()
        }
        if let session = state.sessionStorage {
            webView.restoreData(session) { _ in finish() }
        } else {
            finish()
        }
    }

    /// Applies the tier limits: attached tabs are live; of the rest, the most recently used stay
    /// live (throttled), the next ones are suspended, and the others are discarded.
    func enforceTiers() {
        var attached = 0
        var hidden: [Slot] = []
        for slot in slots.values {
            if slot.container != nil {
                attached += 1
                slot.tab?.set(\.tier, .live)
            } else {
                hidden.append(slot)
            }
        }
        hidden.sort { $0.lastUse > $1.lastUse }
        let liveRoom = max(0, min(FixedChoices.extraLiveTabs, EngineChoices.maxLiveTabs - attached))
        for (index, slot) in hidden.enumerated() {
            if index < liveRoom {
                slot.setInactivePolicy(.throttle)
                slot.tab?.set(\.tier, .live)
            } else if index < liveRoom + EngineChoices.maxSuspendedTabs {
                slot.setInactivePolicy(.suspend)
                slot.tab?.set(\.tier, .suspended)
            } else {
                discard(slot)
            }
        }
    }

    /// Saves the tab's history, scroll and sessionStorage, then releases its web view. The state
    /// read is asynchronous; attaching the tab meanwhile cancels the discard.
    private func discard(_ slot: Slot) {
        guard !slot.isDiscarding, slot.container == nil, let tab = slot.tab else { return }
        slot.isDiscarding = true
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabDiscard, id: signposter.makeSignpostID())
        let webView = slot.webView
        let interaction = webView.interactionState as? Data
        let finish: (Data?) -> Void = { [weak self, weak slot, weak tab] session in
            defer { signposter.endInterval(Signposts.tabDiscard, interval) }
            guard let self, let slot, let tab, slot.isDiscarding, self.slots[tab.id] === slot else { return }
            let state = TabRestorationState(
                url: tab.url, title: tab.title, interactionState: interaction, sessionStorage: session
            )
            self.slots[tab.id] = nil
            self.tearDown(slot)
            tab.restoration = state
            tab.set(\.tier, .discarded)
            tab.set(\.isLoading, false)
            tab.setProgress(0)
            if let tabStates = self.tabStates {
                Task {
                    guard let data = try? await Self.encode(state) else { return }
                    try? await tabStates.write(data, for: tab.id)
                }
            }
        }
        if webView.url == nil {
            finish(nil)
        } else {
            webView.fetchData(of: .sessionStorage) { data, _ in finish(data) }
        }
    }

    @concurrent
    private nonisolated static func encode(_ state: TabRestorationState) async throws -> Data {
        try state.encoded()
    }

    private func tearDown(_ slot: Slot) {
        slot.invalidate()
        let webView = slot.webView
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        contentRules?.release(slot.controller)
        slot.controller.removeAllUserScripts()
    }

    // MARK: - Events from the tab handler

    func slot(for tab: Tab) -> Slot? {
        slots[tab.id]
    }

    /// `createWebViewWith`: a popup, `window.open` or `target=_blank`. The new web view must use
    /// the configuration WebKit passes in, or `window.opener` breaks. It gets its own controller.
    func openChild(configuration: WKWebViewConfiguration, from opener: Tab) -> WKWebView? {
        guard let host, popupLimiter.allow(opener.id) else { return nil }
        let controller = makeController()
        configuration.userContentController = controller
        let webView = makeWebView(configuration: configuration, controller: controller)
        let child = Tab(id: UUID(), openerID: opener.id, pool: self, restoring: nil)
        let slot = Slot(tab: child, webView: webView, controller: controller, pool: self)
        slot.lastUse = tick()
        slots[child.id] = slot
        child.tier = .live
        host.pool(self, didOpen: child, from: opener)
        enforceTiers()
        return webView
    }

    func childRequestsClose(_ tab: Tab) {
        host?.pool(self, tabRequestsClose: tab)
    }

    /// Dialogs only for the tab on screen, and at most `dialogLimit` per window.
    func mayShowDialog(for tab: Tab) -> Bool {
        isAttached(tab) && dialogLimiter.allow(tab.id)
    }

    func openExternally(_ url: URL, from tab: Tab) {
        guard isAttached(tab), let host, externalLimiter.allow(tab.id) else { return }
        Task { _ = await host.tab(tab, openExternally: url) }
    }

    /// The content mode for a navigation starting now: the site's remembered choice, otherwise
    /// the pane's size.
    func contentMode(for url: URL, in tab: Tab) -> ContentMode {
        if let site = NavigationRules.siteKey(for: url), let mode = contentModes.contentMode(forSite: site) {
            return mode
        }
        let size = slots[tab.id]?.container?.bounds.size ?? defaultPaneSize
        return NavigationRules.contentMode(forPaneSize: size)
    }

    func applyContentRules(_ slot: Slot, mainFrameURL: URL) {
        contentRules?.apply(to: slot.controller, forMainFrameURL: mainFrameURL)
    }

    func webContentProcessDidTerminate(_ tab: Tab) {
        Signposts.signposter.emitEvent(Signposts.tabCrash)
        guard let slot = slots[tab.id] else { return }
        if slot.container != nil {
            reloadAfterCrash(slot, tab: tab)
        } else {
            slot.needsReload = true
        }
    }

    private func reloadAfterCrash(_ slot: Slot, tab: Tab) {
        guard crashLimiter.allow(tab.id) else {
            host?.pool(self, tabKeepsCrashing: tab)
            return
        }
        if slot.webView.url != nil {
            slot.webView.reload()
        } else if let url = tab.url {
            slot.webView.load(URLRequest(url: url))
        }
    }

    /// Asks once per site and permission, then answers from `permissionStore`. Only the tab on
    /// screen can ask; background requests are denied without being remembered.
    func decide(_ permissions: [SitePermission], site: String, for tab: Tab) async -> Bool {
        var unknown: [SitePermission] = []
        for permission in permissions {
            switch await permissionStore.isAllowed(permission, forSite: site) {
            case false?: return false
            case true?: continue
            case nil: unknown.append(permission)
            }
        }
        guard !unknown.isEmpty else { return true }
        guard isAttached(tab), let host else { return false }
        let allowed = await host.tab(tab, allow: unknown, forSite: site)
        for permission in unknown {
            await permissionStore.setAllowed(allowed, permission, forSite: site)
        }
        return allowed
    }

    func handleCertificateError(_ error: NSError, in tab: Tab) {
        guard let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL, let hostName = url.host() else { return }
        let trust = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey].map { $0 as! SecTrust }
        let certificateError = CertificateError(
            url: url, host: hostName, code: URLError.Code(rawValue: error.code), trust: trust
        )
        guard let host else { return }
        Task {
            guard await host.tab(tab, shouldProceedPast: certificateError), let trust, tab.pool === self else {
                return
            }
            self.trustExceptions.allow(trust, forHost: hostName)
            tab.load(url)
        }
    }
}

// MARK: - Slot

extension WebViewPool {
    /// One tab's web view and what hangs off it. Exists only while the tab has a web view.
    final class Slot {
        weak var tab: Tab?
        let webView: WKWebView
        let controller: WKUserContentController
        let handler: TabWebViewHandler
        weak var container: UIView?
        var lastUse: UInt64 = 0
        var isDiscarding = false
        var isRestoring = false
        var needsReload = false
        var restoreInterval: OSSignpostIntervalState?
        private var afterRestore: [(WKWebView) -> Void] = []
        private var observations: [NSKeyValueObservation] = []
        private var inactivePolicy: WKPreferences.InactiveSchedulingPolicy?

        init(tab: Tab, webView: WKWebView, controller: WKUserContentController, pool: WebViewPool) {
            self.tab = tab
            self.webView = webView
            self.controller = controller
            handler = TabWebViewHandler(tab: tab, pool: pool)
            webView.navigationDelegate = handler
            webView.uiDelegate = handler
            observe()
        }

        /// KVO only where WebKit has no delegate callback: title changes, same-document
        /// navigations (`pushState` changes URL and history), progress and late mixed content.
        private func observe() {
            observations = [
                webView.observe(\.url, options: .new) { [weak self] webView, _ in
                    MainActor.assumeIsolated {
                        guard let tab = self?.tab, let url = webView.url else { return }
                        tab.set(\.url, url)
                        self?.handler.updateSecurity(of: webView)
                    }
                },
                webView.observe(\.title, options: .new) { [weak self] webView, _ in
                    MainActor.assumeIsolated {
                        guard webView.url != nil else { return }
                        self?.tab?.set(\.title, webView.title ?? "")
                    }
                },
                webView.observe(\.isLoading, options: .new) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.tab?.set(\.isLoading, webView.isLoading) }
                },
                webView.observe(\.canGoBack, options: .new) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.tab?.set(\.canGoBack, webView.canGoBack) }
                },
                webView.observe(\.canGoForward, options: .new) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.tab?.set(\.canGoForward, webView.canGoForward) }
                },
                webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.tab?.setProgress(webView.estimatedProgress) }
                },
                webView.observe(\.hasOnlySecureContent, options: .new) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.handler.updateSecurity(of: webView) }
                },
            ]
        }

        func invalidate() {
            observations.forEach { $0.invalidate() }
            observations = []
            endRestoreInterval()
        }

        func setInactivePolicy(_ policy: WKPreferences.InactiveSchedulingPolicy) {
            guard inactivePolicy != policy else { return }
            inactivePolicy = policy
            webView.configuration.preferences.inactiveSchedulingPolicy = policy
        }

        /// Runs `work` once a pending restore has applied its history, so a load issued meanwhile
        /// lands on top of the restored history instead of being replaced by it.
        func whenRestored(_ work: @escaping (WKWebView) -> Void) {
            if isRestoring {
                afterRestore.append(work)
            } else {
                work(webView)
            }
        }

        func runPendingAfterRestore() {
            let pending = afterRestore
            afterRestore = []
            pending.forEach { $0(webView) }
        }

        func endRestoreInterval() {
            guard let interval = restoreInterval else { return }
            restoreInterval = nil
            Signposts.signposter.endInterval(Signposts.tabRestore, interval)
        }
    }
}
#endif
