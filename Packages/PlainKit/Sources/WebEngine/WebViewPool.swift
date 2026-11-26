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
/// - **Live:** attached (on screen).
/// - **Suspended:** detached but keeping its web view, up to `EngineChoices.maxWebViews` web views
///   in all, most recently used first. WebKit suspends a page as soon as it leaves the window
///   (`inactiveSchedulingPolicy` stays at its `.suspend` default: it lives on a `WKPreferences`
///   that every copied configuration shares, so it can't be set per tab).
/// - **Discarded:** the rest. Only `interactionState` and sessionStorage stay, in memory and in
///   Storage's `TabStateStore`; the web view is released. A memory warning discards every tab
///   that is not on screen. Tabs playing media, in fullscreen or picture in picture, capturing
///   camera or microphone, or downloading are never discarded.
///
/// State is saved for relaunch after every main-frame load (debounced) and for every tab when
/// the app resigns active, not only on discard.
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
    private let pageZooms: any SitePageZoomStore
    let contentRules: (any UserContentRules)?
    let dataStore: WKWebsiteDataStore
    /// Where Copy Link and Copy Image write. Tests use a private one: reading the general
    /// pasteboard needs the user's permission.
    var pasteboard = UIPasteboard.general
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
    /// State-file writes and deletes run one after another, in the order they were issued, so an
    /// older write never lands after a newer one or after the tab was closed.
    private var stateWrites: Task<Void, Never>?
    /// Permission prompts in flight, so two requests for the same site and permissions ask once.
    private var pendingPermissionAsks: [String: Task<Bool, Never>] = [:]
    private var lifecycleObservers: [any NSObjectProtocol] = []
    /// False while the app is in the background or inactive. Tests never leave the active state.
    private(set) var isAppActive = true

    /// - Parameters:
    ///   - dataStore: one store for every tab, so cookies and logins are shared. A private-tabs
    ///     pool passes `.nonPersistent()`.
    ///   - tabStates: where discarded tabs' state is written; nil keeps it in memory only.
    ///   - permissionStore: remembered camera, microphone, location and motion answers.
    ///   - contentModes: remembered desktop/mobile choices from the page menu.
    ///   - contentRules: content blocking, applied to each web view's own controller.
    ///   - thumbnailDirectory: where thumbnails are written. Defaults to Caches/Thumbnails.
    ///   - downloadDirectory: where downloads go. Defaults to Documents/Downloads (Files-visible).
    ///   - pageZooms: remembered page zoom per site.
    public init(
        dataStore: WKWebsiteDataStore = .default(),
        tabStates: TabStateStore? = nil,
        permissionStore: any SitePermissionStore = InMemorySitePermissionStore(),
        contentModes: any SiteContentModeStore = InMemorySiteContentModeStore(),
        contentRules: (any UserContentRules)? = nil,
        thumbnailDirectory: URL? = nil,
        downloadDirectory: URL? = nil,
        pageZooms: any SitePageZoomStore = InMemorySitePageZoomStore()
    ) {
        baseConfiguration = Self.makeBaseConfiguration(dataStore: dataStore)
        self.dataStore = dataStore
        self.tabStates = tabStates
        self.permissionStore = permissionStore
        self.contentModes = contentModes
        self.pageZooms = pageZooms
        self.contentRules = contentRules
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        thumbnails = ThumbnailService(directory: thumbnailDirectory ?? caches.appending(path: "Thumbnails"))
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloads = DownloadCoordinator(
            directory: downloadDirectory ?? documents.appending(path: EngineChoices.downloadsFolderName)
        )
        downloads.pool = self
        let center = NotificationCenter.default
        let observe: (Notification.Name, @escaping @Sendable @MainActor (WebViewPool) -> Void) -> any NSObjectProtocol = { name, act in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { act(self) } }
            }
        }
        lifecycleObservers = [
            observe(UIApplication.didReceiveMemoryWarningNotification) { $0.handleMemoryWarning() },
            observe(UIApplication.willResignActiveNotification) { $0.applicationWillResignActive() },
            observe(UIApplication.didBecomeActiveNotification) { $0.applicationDidBecomeActive() },
        ]
    }

    isolated deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Configuration

    private static func makeBaseConfiguration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = EngineChoices.applicationNameForUserAgent
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        // Like Safari: muted video autoplays, sound waits for a tap.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        // Pinch zoom works on every page, as in Safari.
        configuration.ignoresViewportScaleLimits = true

        let preferences = configuration.preferences
        preferences.isElementFullscreenEnabled = true
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
        controller.addUserScript(UserScripts.pressedElement)
        // Its message handler is added by the tab's `Slot`, which receives the reports.
        controller.addUserScript(UserScripts.media)
        return controller
    }

    private func makeWebView(configuration: WKWebViewConfiguration, controller: WKUserContentController) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.allowsBackForwardNavigationGestures = true
        // The system find bar for "Find on Page" (`Tab.beginFind()`).
        webView.isFindInteractionEnabled = true
        contentRules?.apply(to: controller, forMainFrameURL: nil)
        return webView
    }

    /// A web view for a link preview: no engine scripts, no delegates. The caller applies and
    /// releases the content rules on the returned controller.
    func makePreviewWebView() -> (WKWebView, WKUserContentController) {
        let configuration = baseConfiguration.copy() as! WKWebViewConfiguration
        let controller = WKUserContentController()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        return (webView, controller)
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
        if slot.needsReload, isAppActive {
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
        // Protected until WebKit says whether media is playing; then the limits apply again.
        slot.media = .unknown
        Task { [weak self, weak slot] in
            await slot?.refreshMediaPlayback()
            self?.enforceTiers()
        }
        scheduleSave(slot)
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
            let id = tab.id
            enqueueStateWork { await tabStates.delete([id]) }
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
        // No sessionStorage fetch: it would wake every suspended process at the worst moment.
        for slot in slots.values where slot.container == nil && !slot.isBusy(in: self) {
            discard(slot, fetchingSessionStorage: false)
        }
    }

    /// Saves every tab with a web view, so a kill in the background loses nothing. Runs on
    /// `willResignActive` inside a background task.
    public func saveAllTabs() async {
        let background = BackgroundWork.begin("Plain.saveTabs")
        defer { background?.end() }
        for slot in slots.values {
            slot.pendingSave?.cancel()
            await save(slot, fetchingSessionStorage: true)
        }
        await stateWrites?.value
    }

    private func applicationWillResignActive() {
        isAppActive = false
        Task { await saveAllTabs() }
    }

    private func applicationDidBecomeActive() {
        isAppActive = true
        // Visible pages whose process died while the app was in the background.
        for slot in slots.values where slot.needsReload && slot.container != nil {
            slot.needsReload = false
            if let tab = slot.tab { reloadAfterCrash(slot, tab: tab) }
        }
    }

    /// How many tabs hold a web view, for tests and debugging.
    var liveWebViewCount: Int { slots.count }

    // MARK: - Commands from Tab

    func load(_ url: URL, in tab: Tab) {
        perform(in: tab) { $0.load(URLRequest(url: url)) }
    }

    /// Reloads; a discarded tab's restore is its reload.
    func reload(_ tab: Tab) {
        guard tab.pool === self else { return }
        guard slots[tab.id] != nil else {
            ensureSlot(for: tab)
            enforceTiers()
            return
        }
        tab.set(\.isAwaitingResubmit, false)
        perform(in: tab) { webView in
            if webView.url == nil, let url = tab.url {
                webView.load(URLRequest(url: url))
            } else {
                webView.reload()
            }
        }
    }

    /// Runs `work` on the tab's web view, creating and restoring it if the tab was discarded, and
    /// after any pending restore, so a command lands on top of the restored history.
    func perform(in tab: Tab, _ work: @escaping (WKWebView) -> Void) {
        guard tab.pool === self else { return }
        let isNew = slots[tab.id] == nil
        let slot = ensureSlot(for: tab)
        slot.whenRestored(work)
        if isNew { enforceTiers() }
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

    /// Applies a zoom now and remembers it for the tab's site (100% forgets it). A discarded tab
    /// gets it when its page commits again.
    func setPageZoom(_ zoom: Double, for tab: Tab) {
        guard tab.pool === self else { return }
        if let site = NavigationRules.siteKey(for: tab.url) {
            pageZooms.setPageZoom(zoom == PageZoom.actualSize ? nil : zoom, forSite: site)
        }
        tab.set(\.pageZoom, zoom)
        if let webView = slots[tab.id]?.webView, webView.pageZoom != zoom { webView.pageZoom = zoom }
        Signposts.signposter.emitEvent(Signposts.pageZoom, "\(PageZoom.percent(zoom))")
    }

    /// The site's remembered zoom, applied when a main-frame page commits, so the first paint of
    /// a new page already has it. WebKit's `pageZoom` outlives navigations; this resets it on a
    /// site without a remembered zoom.
    func applyRememberedZoom(to webView: WKWebView, in tab: Tab) {
        let site = NavigationRules.siteKey(for: webView.url)
        let zoom = site.flatMap(pageZooms.pageZoom(forSite:)).map(PageZoom.nearestStep(to:)) ?? PageZoom.actualSize
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        tab.set(\.pageZoom, zoom)
    }

    /// Shows the system find bar on the tab's page. Only for a tab on screen.
    func beginFind(in tab: Tab) {
        guard let slot = slots[tab.id], slot.container != nil else { return }
        Signposts.signposter.emitEvent(Signposts.findOnPage)
        slot.webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// Downloads `url` with the tab's cookies through `DownloadCoordinator`, as if the page had
    /// served it as an attachment. "Download Linked File" and "Save PDF to Files".
    func startDownload(_ url: URL, from tab: Tab) {
        perform(in: tab) { [weak self, weak tab] webView in
            webView.startDownload(using: URLRequest(url: url)) { download in
                self?.downloads.adopt(download, from: tab)
            }
        }
    }

    func restorationState(for tab: Tab) async -> TabRestorationState {
        guard let slot = slots[tab.id] else {
            return tab.restoration
                ?? TabRestorationState(url: tab.url, title: tab.title, interactionState: nil, sessionStorage: nil)
        }
        if let pending = slot.pendingRestore { return pending }
        let session = await fetchSessionStorage(slot.webView)
        return currentState(of: slot, tab: tab, sessionStorage: session)
    }

    /// The tab's state now. Read after any sessionStorage round trip to the WebContent process:
    /// by then its latest scroll position has reached the history item.
    private func currentState(of slot: Slot, tab: Tab, sessionStorage: Data?) -> TabRestorationState {
        if let pending = slot.pendingRestore { return pending }
        return TabRestorationState(
            url: tab.url, title: tab.title, interactionState: slot.webView.interactionState as? Data,
            sessionStorage: sessionStorage ?? slot.lastSessionStorage, isFormResult: tab.isFormResult
        )
    }

    /// sessionStorage, or nil after `EngineChoices.webKitReplyTimeout`: a frozen or killed
    /// WebContent process may never answer.
    private func fetchSessionStorage(_ webView: WKWebView) async -> Data? {
        guard webView.url != nil else { return nil }
        return await withWebKitTimeout(fallback: nil) { done in
            webView.fetchData(of: .sessionStorage) { data, _ in done(data) }
        }
    }

    // MARK: - Saving for relaunch

    /// Saves the tab a second after its last main-frame load or detach, so a burst of loads
    /// writes once. `interactionState` is UI-process data: reading it wakes nothing.
    func scheduleSave(_ slot: Slot) {
        guard tabStates != nil else { return }
        slot.pendingSave?.cancel()
        slot.pendingSave = Task { [weak self, weak slot] in
            try? await Task.sleep(for: EngineChoices.saveDebounce)
            guard !Task.isCancelled, let self, let slot else { return }
            await self.save(slot, fetchingSessionStorage: false)
        }
    }

    private func save(_ slot: Slot, fetchingSessionStorage: Bool) async {
        guard let tabStates, let tab = slot.tab, slots[tab.id] === slot else { return }
        let session = fetchingSessionStorage ? await fetchSessionStorage(slot.webView) : nil
        // Closed or discarded meanwhile: a write now would bring its file back.
        guard slots[tab.id] === slot else { return }
        if let session { slot.lastSessionStorage = session }
        let state = currentState(of: slot, tab: tab, sessionStorage: session)
        let id = tab.id
        enqueueStateWork {
            guard let data = try? await Self.encode(state) else { return }
            try? await tabStates.write(data, for: id)
        }
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
        slot.pendingRestore = state
        slot.lastSessionStorage = state.sessionStorage
        let webView = slot.webView
        Task { [weak self, weak slot] in
            if let session = state.sessionStorage {
                await withWebKitTimeout(fallback: ()) { done in webView.restoreData(session) { _ in done(()) } }
            }
            // A page that was the result of a form would be sent again: ask first.
            // Only the shell's explicit yes sends a form again.
            var resubmit = !state.isFormResult
            if state.isFormResult, let self, let slot, let tab = slot.tab, let host = self.host {
                resubmit = await Signposts.prompt("resubmit") { await host.pool(self, shouldResubmitFormIn: tab) }
            }
            guard let slot, slot.pendingRestore != nil else { return }
            Self.apply(state, to: webView, slot: slot, resubmit: resubmit)
            slot.pendingRestore = nil
            slot.runPendingAfterRestore()
        }
    }

    private static func apply(_ state: TabRestorationState, to webView: WKWebView, slot: Slot, resubmit: Bool) {
        if let interaction = state.interactionState {
            webView.interactionState = interaction
            if !resubmit {
                // History and URL come back; the form is not sent until the user reloads.
                webView.stopLoading()
                slot.tab?.set(\.isAwaitingResubmit, true)
                slot.endRestoreInterval()
                return
            }
        }
        // `interactionState` that fails to decode is dropped without an error: load the URL.
        if webView.url == nil {
            if let url = state.url {
                webView.load(URLRequest(url: url))
            } else {
                slot.endRestoreInterval()
            }
        }
    }

    /// Applies the tier limits: attached tabs are live; of the rest, the most recently used keep
    /// their web view (suspended by WebKit) up to `EngineChoices.maxWebViews` in all, and the
    /// others are discarded. Busy tabs (media, capture, fullscreen, downloads) are always kept.
    func enforceTiers() {
        var kept = 0
        var hidden: [Slot] = []
        for slot in slots.values {
            if slot.container != nil {
                kept += 1
                slot.tab?.set(\.tier, .live)
            } else {
                hidden.append(slot)
            }
        }
        hidden.sort { $0.lastUse > $1.lastUse }
        for slot in hidden {
            if kept < EngineChoices.maxWebViews || slot.isBusy(in: self) {
                kept += 1
                slot.tab?.set(\.tier, .suspended)
            } else {
                discard(slot, fetchingSessionStorage: true)
            }
        }
    }

    /// Saves the tab's history, scroll and sessionStorage, then releases its web view. The state
    /// read is asynchronous; attaching the tab meanwhile cancels the discard.
    private func discard(_ slot: Slot, fetchingSessionStorage: Bool) {
        guard !slot.isDiscarding, slot.container == nil, let tab = slot.tab else { return }
        slot.isDiscarding = true
        slot.pendingSave?.cancel()
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabDiscard, id: signposter.makeSignpostID())
        let webView = slot.webView
        let finish: (Data?) -> Void = { [weak self, weak slot, weak tab] session in
            defer { signposter.endInterval(Signposts.tabDiscard, interval) }
            guard let self, let slot, let tab, slot.isDiscarding, self.slots[tab.id] === slot else { return }
            // It may have started playing or downloading meanwhile.
            guard !slot.isBusy(in: self) else {
                slot.isDiscarding = false
                return
            }
            // A restore still in flight has not applied its state yet: `currentState` keeps that
            // state, not the empty web view's.
            let state = self.currentState(of: slot, tab: tab, sessionStorage: session)
            self.slots[tab.id] = nil
            self.tearDown(slot)
            tab.restoration = state
            tab.set(\.tier, .discarded)
            tab.set(\.isLoading, false)
            tab.setProgress(0)
            if let tabStates = self.tabStates {
                let id = tab.id
                self.enqueueStateWork {
                    guard let data = try? await Self.encode(state) else { return }
                    try? await tabStates.write(data, for: id)
                }
            }
        }
        if !fetchingSessionStorage || slot.pendingRestore != nil || webView.url == nil {
            finish(nil)
        } else {
            Task { [weak slot] in
                let session = await fetchSessionStorage(webView)
                // Ask again right before releasing: playback may have started since the detach.
                await slot?.refreshMediaPlayback()
                finish(session)
            }
        }
    }

    private func enqueueStateWork(_ work: @escaping @Sendable () async -> Void) {
        let previous = stateWrites
        stateWrites = Task {
            await previous?.value
            await work()
        }
    }

    @concurrent
    private nonisolated static func encode(_ state: TabRestorationState) async throws -> Data {
        try state.encoded()
    }

    private func tearDown(_ slot: Slot) {
        slot.pendingSave?.cancel()
        slot.invalidate()
        let webView = slot.webView
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        contentRules?.release(slot.controller)
        slot.controller.removeAllUserScripts()
        slot.controller.removeAllScriptMessageHandlers()
        // No web view, no media: a restored page starts silent.
        slot.tab?.resetMediaState()
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

    /// `window.close()`: only a tab a page opened may close itself (a page the user opened from
    /// the address bar may not, even with one history entry).
    func childRequestsClose(_ tab: Tab) {
        guard tab.openerID != nil else { return }
        host?.pool(self, tabRequestsClose: tab)
    }

    /// Dialogs only for the tab on screen, and at most `dialogLimit` per window.
    func mayShowDialog(for tab: Tab) -> Bool {
        isAttached(tab) && dialogLimiter.allow(tab.id)
    }

    func openExternally(_ url: URL, from tab: Tab) {
        guard isAttached(tab), let host, externalLimiter.allow(tab.id) else { return }
        Task { _ = await Signposts.prompt("external") { await host.tab(tab, openExternally: url) } }
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

    /// A WebContent process ended. iOS kills suspended ones under memory pressure all the time;
    /// those are not crashes. A hidden tab becomes discarded (its history and scroll are still in
    /// the UI process) and restores in place on attach. A visible tab reloads now, or when the app
    /// is active again; only those reloads count toward the crash-loop limit.
    func webContentProcessDidTerminate(_ tab: Tab) {
        Signposts.signposter.emitEvent(Signposts.tabCrash)
        guard let slot = slots[tab.id] else { return }
        slot.clearMediaReports()
        if slot.container == nil {
            // If it is kept anyway (still busy), it reloads when shown. A dead process plays nothing.
            slot.needsReload = true
            slot.media = .idle
            slot.isDiscarding = false
            discard(slot, fetchingSessionStorage: false)
        } else if isAppActive {
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
        let key = unknown.map(\.rawValue).joined(separator: ",") + " " + site
        if let pending = pendingPermissionAsks[key] { return await pending.value }
        let store = permissionStore
        let ask = Task {
            let allowed = await Signposts.prompt("permission") {
                await host.tab(tab, allow: unknown, forSite: site)
            }
            for permission in unknown {
                await store.setAllowed(allowed, permission, forSite: site)
            }
            return allowed
        }
        pendingPermissionAsks[key] = ask
        let allowed = await ask.value
        pendingPermissionAsks[key] = nil
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
            let proceed = await Signposts.prompt("certificate") {
                await host.tab(tab, shouldProceedPast: certificateError)
            }
            guard proceed, let trust, tab.pool === self else {
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
        /// The state being restored until its `interactionState` is applied.
        var pendingRestore: TabRestorationState?
        var isRestoring: Bool { pendingRestore != nil }
        var needsReload = false
        var restoreInterval: OSSignpostIntervalState?
        /// The last sessionStorage read or restored, reused by saves that don't fetch it.
        var lastSessionStorage: Data?
        var pendingSave: Task<Void, Never>?
        enum MediaState { case idle, unknown, playing }
        /// Whether the page's media was playing when last asked (on detach and before a discard).
        /// Unknown until WebKit answers, and protected meanwhile.
        var media = MediaState.idle
        /// Set when the current main-frame navigation is a form submission (POST).
        var pendingNavigationIsFormSubmission = false
        /// Set from the main-frame response: the page being loaded is a PDF.
        var pendingNavigationIsPDF = false
        /// What each frame's media script last reported, by the frame's own id.
        private var frameMedia: [String: (playing: Bool, pictureInPicture: Bool)] = [:]
        private var afterRestore: [(WKWebView) -> Void] = []
        private var observations: [NSKeyValueObservation] = []

        init(tab: Tab, webView: WKWebView, controller: WKUserContentController, pool: WebViewPool) {
            self.tab = tab
            self.webView = webView
            self.controller = controller
            handler = TabWebViewHandler(tab: tab, pool: pool)
            webView.navigationDelegate = handler
            webView.uiDelegate = handler
            controller.add(
                MediaMessageHandler(slot: self), contentWorld: UserScripts.world, name: UserScripts.mediaHandlerName
            )
            observe()
        }

        /// A frame's media script reported (`UserScripts.mediaSource`).
        func receiveMediaReport(frame id: String, playing: Bool, pictureInPicture: Bool) {
            if playing || pictureInPicture {
                frameMedia[id] = (playing, pictureInPicture)
            } else {
                frameMedia[id] = nil
            }
            publishMedia()
            // The scripts can't see every player (`new Audio()` never added to the page, media in
            // a shadow root), so each report also asks WebKit, which knows them all. One IPC per
            // play or pause.
            Task { [weak self] in await self?.refreshMediaPlayback() }
        }

        /// A new main-frame document committed (the old frames are gone) or the process died.
        func clearMediaReports() {
            frameMedia = [:]
            media = .idle
            publishMedia()
        }

        private func publishMedia() {
            guard let tab else { return }
            let playing = media == .playing || frameMedia.values.contains { $0.playing }
            tab.set(\.isPlayingMedia, playing)
            tab.set(\.isInPictureInPicture, frameMedia.values.contains { $0.pictureInPicture })
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
                webView.observe(\.fullscreenState, options: .new) { [weak self] webView, _ in
                    MainActor.assumeIsolated {
                        self?.tab?.set(\.isFullscreen, webView.fullscreenState != .notInFullscreen)
                    }
                },
                webView.observe(\.cameraCaptureState, options: .new) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.publishCapture() }
                },
                webView.observe(\.microphoneCaptureState, options: .new) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.publishCapture() }
                },
            ]
        }

        private func publishCapture() {
            tab?.set(\.isCapturingMedia, webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none)
        }

        func invalidate() {
            observations.forEach { $0.invalidate() }
            observations = []
            endRestoreInterval()
        }

        /// Media playing (picture in picture included), camera or microphone on, fullscreen, or a
        /// download from this tab running: never discard it.
        func isBusy(in pool: WebViewPool) -> Bool {
            media != .idle || !frameMedia.isEmpty
                || webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
                || webView.fullscreenState != .notInFullscreen
                || (tab.map { pool.downloads.hasActiveDownload(fromTab: $0.id) } ?? false)
        }

        /// A frozen process that never answers counts as not playing.
        func refreshMediaPlayback() async {
            let webView = self.webView
            let state = await withWebKitTimeout(fallback: WKMediaPlaybackState.none) { done in
                webView.requestMediaPlaybackState(completionHandler: done)
            }
            media = state == .playing ? .playing : .idle
            publishMedia()
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

    /// Receives the media script's reports. The controller keeps it strongly, so it holds the slot
    /// weakly; the pool removes it when the web view goes away.
    final class MediaMessageHandler: NSObject, WKScriptMessageHandler {
        private weak var slot: Slot?

        init(slot: Slot) {
            self.slot = slot
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let id = body["id"] as? String else { return }
            slot?.receiveMediaReport(
                frame: id, playing: body["playing"] as? Bool ?? false, pictureInPicture: body["pip"] as? Bool ?? false
            )
        }
    }
}
#endif
