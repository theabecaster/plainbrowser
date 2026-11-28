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
    /// Called on a memory warning, before hidden tabs are discarded: the shell drops what it keeps
    /// for them (swipe previews).
    public var onMemoryWarning: (() -> Void)?

    /// The size of a page pane when the tab is not attached: the shell sets it to its main pane's
    /// size. Attached tabs use their container's bounds. Desktop or mobile is decided from it when
    /// a navigation starts; a page on screen follows a later size change only through
    /// `panesDidChange()` (`WebViewPool+ContentMode`).
    public var defaultPaneSize = CGSize(width: 390, height: 844)

    /// The app's light or dark colors as the window shows them (Settings > Appearance, or iOS
    /// with System). Every web view gets it, so `prefers-color-scheme` is right for pages that
    /// load off screen (a background tab, the warm web view) and the first frame of a tab coming
    /// on screen. Pages on screen follow their window anyway; this keeps the hidden ones with them.
    /// `.unspecified` leaves every web view to its window.
    public var interfaceStyle: UIUserInterfaceStyle = .unspecified {
        didSet {
            guard interfaceStyle != oldValue else { return }
            for slot in slots.values { applyInterfaceStyle(to: slot.webView, site: NavigationRules.siteKey(for: slot.tab?.url), isPrivate: slot.tab?.isPrivate ?? false) }
            if let warm { applyInterfaceStyle(to: warm.webView) }
        }
    }

    /// A trait override, not `overrideUserInterfaceStyle`: a web view outside a window resolves
    /// only overrides set this way (measured: a detached web view with
    /// `overrideUserInterfaceStyle = .dark` still matched `prefers-color-scheme: light`).
    ///
    /// A site whose page appearance is Dark or Light gets that style instead (its own dark or
    /// light design, through `prefers-color-scheme`), on its web view alone: Plain's own windows and
    /// chrome keep their colors.
    func applyInterfaceStyle(to webView: WKWebView, site: String? = nil, isPrivate: Bool = false) {
        let style = pageStyle(site: site, isPrivate: isPrivate)
        if style == .unspecified {
            webView.traitOverrides.remove(UITraitUserInterfaceStyle.self)
        } else if webView.traitOverrides.contains(UITraitUserInterfaceStyle.self), webView.traitOverrides.userInterfaceStyle == style {
            return
        } else {
            webView.traitOverrides.userInterfaceStyle = style
        }
        webView.updateTraitsIfNeeded()
    }

    /// The style a page of `site` is drawn in: Dark or Light by its page appearance, otherwise
    /// the colors Plain shows.
    private func pageStyle(site: String?, isPrivate: Bool) -> UIUserInterfaceStyle {
        guard let site else { return interfaceStyle }
        switch pageAppearanceChoices(isPrivate: isPrivate).appearance(for: site) {
        case .dark: return .dark
        case .light: return .light
        case .off: return interfaceStyle
        }
    }

    private func applyBaseInterfaceStyle(to webView: WKWebView) {
        if interfaceStyle == .unspecified {
            webView.traitOverrides.remove(UITraitUserInterfaceStyle.self)
        } else {
            webView.traitOverrides.userInterfaceStyle = interfaceStyle
        }
        webView.updateTraitsIfNeeded()
    }

    public let downloads: DownloadCoordinator
    public let thumbnails: ThumbnailService
    /// Site icons for the tab lists (`FaviconService`).
    public let favicons: FaviconService

    /// Made when the first web view is (the warm-up after the first frame): WebKit's
    /// preferences and the data store cost the launch's first frame several ms otherwise.
    private lazy var baseConfiguration = Self.makeBaseConfiguration(dataStore: dataStore)
    private let tabStates: TabStateStore?
    private let permissionStore: any SitePermissionStore
    private let contentModes: any SiteContentModeStore
    private let pageZooms: any SitePageZoomStore
    private let darkPages: any PageAppearanceStore
    let contentRules: (any UserContentRules)?
    private let pageScripts: (any PageScripts)?
    /// Translate Page's engine, from the shell. Without one, pages are never offered translation.
    let translator: (any PageTranslator)?
    /// A translation failed after it started (the page is back to its own text): the shell says so.
    public var onTranslationFailed: ((Tab) -> Void)?
    /// False until Apple grants the web-browser entitlement: pages then get `SignInScripts`'
    /// passkey fallback (`FixedChoices.passkeysEnabled`).
    let passkeysEnabled: Bool
    /// The passkey fallback and its relay, made once per pool (their event name is random).
    private let signInScripts: SignInScripts?
    /// Sites already told that passkeys can't work yet, this launch: one toast per site, not one
    /// per attempt. Private tabs keep theirs apart and drop them with the private session.
    private var passkeyNoticeSites: Set<String> = []
    private var privatePasskeyNoticeSites: Set<String> = []
    /// Personal's website data store, made on first use (the warm-up), not in the launch's first
    /// frame.
    lazy var dataStore: WKWebsiteDataStore = makeDataStore()
    private let makeDataStore: () -> WKWebsiteDataStore
    /// Where Copy Link and Copy Image write. Tests use a private one: reading the general
    /// pasteboard needs the user's permission. An isolated run gets a private one too
    /// (`UIPasteboard.plain`).
    var pasteboard = UIPasteboard.plain
    let trustExceptions = ServerTrustExceptions()

    private var slots: [UUID: Slot] = [:]
    /// Desktop or mobile checks after a pane changes size (`WebViewPool+ContentMode`).
    let modeChecks = ContentModeCoordinator()
    /// Private tabs' website data store: one non-persistent store shared by every private tab, made
    /// with the first one and dropped by `endPrivateSession()`, so the next private tab starts with
    /// no cookies or storage.
    private var privateDataStore: WKWebsiteDataStore?
    /// Where a profile's store comes from (every profile but Personal, whose store is
    /// `dataStore`). Tests pass throwaway stores.
    private let profileStore: (ProfileID) -> WKWebsiteDataStore
    /// Each profile's store, made with its first web view this launch.
    private var profileStores: [ProfileID: WKWebsiteDataStore] = [:]
    /// What private tabs answer and choose per site, kept in memory for the private session only.
    private var privateSiteChoices: SiteChoices?
    /// Private tabs' dark pages choices, for the private session only.
    private var privatePageAppearanceStore: LayeredPageAppearanceStore?
    private var warm: (webView: WKWebView, controller: WKUserContentController)?
    /// A rewarm is waiting for the app to be idle.
    private var rewarmScheduled = false
    /// Memory warnings received: a rewarm scheduled before the latest one never runs.
    private var memoryWarnings = 0
    /// Between `keyboardWill…` and `keyboardDid…`: the keyboard is rising or falling.
    private var isKeyboardMoving = false
    /// Hidden web views lent out (`makeHiddenWebView`), with their controllers, so their content
    /// rules are released when they are.
    var hiddenWebViews: [ObjectIdentifier: WKUserContentController] = [:]
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
    /// What iOS lets Plain use (camera, microphone, location, Photos, cellular data), read after
    /// the first frame and on each return to the app.
    public let systemAccess = SystemAccessMonitor()
    /// The switched-off features whose requests pages are watched for (`AccessRequestWatch`);
    /// empty while everything is on, so pages get no script of Plain's in their world.
    private(set) var accessWatch: Set<SystemFeature> = []
    private var systemAccessStarted = false
    /// Remembered permission answers per site (`rememberedPermissions(for:)`).
    private var siteAnswers: [String: [SitePermission: Bool]] = [:]
    /// Permissions each site asked for while iOS had them off for Plain, so Site Settings can show
    /// their row (Off in Settings). In memory only: nothing was answered, so nothing is kept.
    private var askedWhileOff: [String: Set<SitePermission>] = [:]
    /// Bumped when the private session ends, so a private read still on its way is dropped.
    private var privateSessionGeneration = 0
    /// False while the app is in the background or inactive. Tests never leave the active state.
    private(set) var isAppActive = true

    /// - Parameters:
    ///   - dataStore: one store for every tab, so cookies and logins are shared. A private-tabs
    ///     pool passes `.nonPersistent()`.
    ///   - tabStates: where discarded tabs' state is written; nil keeps it in memory only.
    ///   - permissionStore: remembered camera, microphone, location and motion answers.
    ///   - contentModes: remembered desktop/mobile choices from the page menu.
    ///   - contentRules: content blocking, applied to each web view's own controller.
    ///   - pageScripts: user scripts added to each tab's own controller (Reader's check).
    ///   - thumbnailDirectory: where thumbnails are written. Defaults to Caches/Thumbnails, or a
    ///     temporary folder in an isolated test run (its pruning must never reach the owner's).
    ///   - downloadDirectory: where downloads go. Defaults to Documents/Downloads (Files-visible),
    ///     or a temporary folder in an isolated test run.
    ///   - pageZooms: remembered page zoom per site.
    ///   - passkeysEnabled: whether the app has the web-browser entitlement, so WebKit can use
    ///     passkeys. Tests pass both.
    ///   - darkPages: the default page appearance and each site's own.
    ///   - translator: Translate Page's engine (Apple's Translation framework, from the shell).
    ///   - profileStore: the website data store of each profile but Personal (whose store is
    ///     `dataStore`): its own, so profiles never share cookies or logins.
    ///   - iconDatabases: each profile's database, where its site icons are stored; nil keeps
    ///     icons in memory only.
    public init(
        dataStore: @autoclosure @escaping () -> WKWebsiteDataStore = AppWebsiteData.store,
        profileStore: @escaping (ProfileID) -> WKWebsiteDataStore = { AppWebsiteData.store(forProfile: $0) },
        tabStates: TabStateStore? = nil,
        permissionStore: any SitePermissionStore = InMemorySitePermissionStore(),
        contentModes: any SiteContentModeStore = InMemorySiteContentModeStore(),
        contentRules: (any UserContentRules)? = nil,
        pageScripts: (any PageScripts)? = nil,
        thumbnailDirectory: URL? = nil,
        downloadDirectory: URL? = nil,
        pageZooms: any SitePageZoomStore = InMemorySitePageZoomStore(),
        passkeysEnabled: Bool = FixedChoices.passkeysEnabled,
        darkPages: any PageAppearanceStore = InMemoryPageAppearanceStore(),
        translator: (any PageTranslator)? = nil,
        iconDatabases: FaviconService.Databases? = nil
    ) {
        favicons = FaviconService(databases: iconDatabases)
        self.translator = translator
        self.passkeysEnabled = passkeysEnabled
        signInScripts = passkeysEnabled ? nil : SignInScripts()
        makeDataStore = dataStore
        self.profileStore = profileStore
        self.tabStates = tabStates
        self.permissionStore = permissionStore
        self.contentModes = contentModes
        self.pageZooms = pageZooms
        self.darkPages = darkPages
        self.contentRules = contentRules
        self.pageScripts = pageScripts
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        thumbnails = ThumbnailService(
            directory: thumbnailDirectory ?? TestIsolation.folder("Thumbnails") ?? caches.appending(path: "Thumbnails")
        )
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloads = DownloadCoordinator(
            directory: downloadDirectory ?? TestIsolation.folder(EngineChoices.downloadsFolderName)
                ?? documents.appending(path: EngineChoices.downloadsFolderName)
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
            // A rewarm waits out the keyboard's rise or fall (`rewarm`).
            observe(UIResponder.keyboardWillShowNotification) { $0.isKeyboardMoving = true },
            observe(UIResponder.keyboardWillHideNotification) { $0.isKeyboardMoving = true },
            observe(UIResponder.keyboardDidShowNotification) { $0.isKeyboardMoving = false },
            observe(UIResponder.keyboardDidHideNotification) { $0.isKeyboardMoving = false },
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
        // As in Safari: element fullscreen (the Fullscreen API) only off the iPhone. On an iPhone,
        // the Duo included, sites' players fall back to the video's own fullscreen, the native
        // player (EngineChoices.allowsElementFullscreen).
        preferences.isElementFullscreenEnabled = EngineChoices.allowsElementFullscreen(on: UIDevice.current.userInterfaceIdiom)
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
    private func makeConfiguration(
        isPrivate: Bool = false, profile: ProfileID = Profile.defaultID
    ) -> (WKWebViewConfiguration, WKUserContentController) {
        let configuration = baseConfiguration.copy() as! WKWebViewConfiguration
        useStore(of: isPrivate, profile: profile, in: configuration)
        let controller = makeController(isPrivate: isPrivate)
        configuration.userContentController = controller
        return (configuration, controller)
    }

    private func makeController(isPrivate: Bool) -> WKUserContentController {
        let controller = WKUserContentController()
        installScripts(in: controller, isPrivate: isPrivate)
        return controller
    }

    /// The engine's scripts, the shell's page scripts, and dark pages with the current list of
    /// sites where it is off.
    private func installScripts(in controller: WKUserContentController, isPrivate: Bool) {
        controller.addUserScript(UserScripts.preconnect)
        controller.addUserScript(UserScripts.pressedElement)
        controller.addUserScript(UserScripts.subframePress)
        // Its message handler is added by the tab's `Slot`, which receives the reports, like dark pages'.
        controller.addUserScript(UserScripts.media)
        if let signInScripts {
            controller.addUserScript(signInScripts.passkeyFallback)
            controller.addUserScript(signInScripts.passkeyRelay)
        }
        pageScripts?.install(in: controller)
        controller.addUserScript(darkPagesScript(isPrivate: isPrivate))
        controller.addUserScript(DarkPages.frameScript)
        if translator != nil { controller.addUserScript(PageTranslation.languageScript) }
        if !accessWatch.isEmpty { controller.addUserScript(AccessRequestWatch.script) }
    }

    /// Dark pages for the tabs of one kind, built from its choices once per change of them.
    private func darkPagesScript(isPrivate: Bool) -> WKUserScript {
        let choices = pageAppearanceChoices(isPrivate: isPrivate)
        if let cached = darkPagesScripts[isPrivate], cached.choices == choices { return cached.script }
        let script = DarkPages.userScript(choices: choices)
        darkPagesScripts[isPrivate] = (choices, script)
        return script
    }

    /// The switch and the sites' choices for one kind of tab (private tabs: the session's own
    /// site choices over the regular ones).
    public func pageAppearanceChoices(isPrivate: Bool) -> PageAppearanceChoices {
        (isPrivate ? privatePageAppearance() : darkPages).choices
    }

    /// The engine for a same-origin frame that asked for it (`DarkPages.frameScript`).
    func darkPagesSource(isPrivate: Bool) -> String {
        darkPagesScript(isPrivate: isPrivate).source
    }

    /// The dark-pages script per kind of tab (regular, private), with the choices it was built from.
    private var darkPagesScripts: [Bool: (choices: PageAppearanceChoices, script: WKUserScript)] = [:]

    /// Bumped by every change of Dark Pages' choices; each web view remembers the one its page
    /// was told (`Slot.darkPagesRevision`), so a tab off screen catches up as it comes on screen.
    private var darkPagesRevision = 0

    /// Dark Pages' choices changed (the switch, a site's choice, or the stored copy read after
    /// launch): every web view's next page gets them, and the pages on screen take them now,
    /// without a reload. Returns once the pages on screen have drawn the change (for the
    /// crossfade); pages off screen take it when they come on screen.
    @discardableResult
    public func darkPagesChoicesDidChange() async -> Bool {
        // Every window's pool hears every change, and the acting pool asks too: a policy already
        // applied is not applied twice.
        let current = [false: pageAppearanceChoices(isPrivate: false), true: pageAppearanceChoices(isPrivate: true)]
        if current != appliedPageAppearanceChoices {
            for slot in slots.values {
                applyInterfaceStyle(to: slot.webView, site: NavigationRules.siteKey(for: slot.tab?.url), isPrivate: slot.tab?.isPrivate ?? false)
            }
            appliedPageAppearanceChoices = current
            rebuildDarkPagesScripts()
            darkPagesRevision += 1
            // Every pane on screen at once, each answering for itself; a caller that comes later
            // for the same choices waits for these same answers.
            let updates = slots.values.filter { $0.container != nil }.map { slot in
                Task { await self.applyDarkPagesChoice(to: slot, waiting: true) != nil }
            }
            darkPagesApplying = Task {
                var answered = true
                for update in updates {
                    if await !update.value { answered = false }
                }
                return answered
            }
        }
        return await darkPagesApplying?.value ?? true
    }

    /// The choices the scripts were last built from, per kind of tab.
    private var appliedPageAppearanceChoices: [Bool: PageAppearanceChoices] = [:]
    /// The pages on screen taking the newest choices, until they answered.
    private var darkPagesApplying: Task<Bool, Never>?

    /// Swaps the dark-pages script in every controller for one built from the current choices.
    private func rebuildDarkPagesScripts() {
        darkPagesScripts = [:]
        var controllers: [(WKUserContentController, Bool)] = slots.values.map { ($0.controller, $0.tab?.isPrivate ?? false) }
        if let warm { controllers.append((warm.controller, false)) }
        // WebKit removes user scripts only all at once: keep every other script (the shell's
        // page scripts registered message handlers that must not be added twice) and swap ours.
        for (controller, isPrivate) in controllers {
            let others = controller.userScripts.filter { !DarkPages.isDarkPagesScript($0) }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
            controller.addUserScript(darkPagesScript(isPrivate: isPrivate))
        }
    }

    /// Tells `slot`'s page the current choice for its site. `waiting`: answers once the page drew
    /// it, with its document's token (nil without an engine or a site).
    @discardableResult
    private func applyDarkPagesChoice(to slot: Slot, waiting: Bool) async -> String? {
        slot.darkPagesRevision = darkPagesRevision
        guard let tab = slot.tab, let site = NavigationRules.siteKey(for: tab.url) else { return nil }
        let choices = pageAppearanceChoices(isPrivate: tab.isPrivate)
        let applies = choices.darkens(site), siteOff = choices.hasOwnChoice(site) && !applies
        guard waiting else {
            slot.webView.evaluateJavaScript(
                DarkPages.setChoiceSource(applies: applies, siteOff: siteOff), in: nil, in: UserScripts.world
            ) { _ in }
            return nil
        }
        let result = try? await slot.webView.callAsyncJavaScript(
            DarkPages.setChoiceBody(applies: applies, siteOff: siteOff), arguments: [:], in: nil, contentWorld: UserScripts.world
        )
        // An answer from the page this tab shows now, not one that went away meanwhile.
        guard let document = result as? String, slot.tab?.darkPagesDocument == document else { return nil }
        return document
    }

    /// A tab coming on screen catches up with changes made while it was off screen.
    private func catchUpDarkPages(_ slot: Slot) {
        guard slot.darkPagesRevision != darkPagesRevision else { return }
        Task { await applyDarkPagesChoice(to: slot, waiting: false) }
    }

    private func makeWebView(configuration: WKWebViewConfiguration, controller: WKUserContentController) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        applyBaseInterfaceStyle(to: webView)
        webView.allowsBackForwardNavigationGestures = true
        // The system find bar for "Find on Page" (`Tab.beginFind()`).
        webView.isFindInteractionEnabled = true
        contentRules?.apply(to: controller, forMainFrameURL: nil)
        return webView
    }

    /// A web view for a link preview: no engine scripts but dark pages (a light-only page
    /// previews dark in a dark app, as it will open), no delegates. The caller applies and
    /// releases the content rules on the returned controller.
    func makePreviewWebView(isPrivate: Bool = false, profile: ProfileID = Profile.defaultID) -> (WKWebView, WKUserContentController) {
        let configuration = baseConfiguration.copy() as! WKWebViewConfiguration
        useStore(of: isPrivate, profile: profile, in: configuration)
        let controller = WKUserContentController()
        controller.addUserScript(darkPagesScript(isPrivate: isPrivate))
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        applyBaseInterfaceStyle(to: webView)
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
        startSystemAccess()
        guard warm == nil else { return }
        let state = Signposts.signposter.beginInterval(Signposts.webViewWarmUp)
        let (configuration, controller) = makeConfiguration()
        let webView = makeWebView(configuration: configuration, controller: controller)
        webView.loadHTMLString("", baseURL: nil)
        warm = (webView, controller)
        Signposts.signposter.endInterval(Signposts.webViewWarmUp, state)
    }

    /// The warm web view was taken: another is made once the app is idle (`EngineChoices.rewarmDelay`,
    /// default run loop mode only, never while the keyboard moves), so the next tab that needs one
    /// finds it ready. Not in the background, and not again after a memory warning dropped it (only
    /// a later take rewarms).
    private func scheduleRewarm() {
        guard !rewarmScheduled else { return }
        rewarmScheduled = true
        waitToRewarm(EngineChoices.rewarmDelay, generation: memoryWarnings, retries: 0)
    }

    private func waitToRewarm(_ delay: Duration, generation: Int, retries: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated { self?.rewarm(generation: generation, retries: retries) }
            }
        }
    }

    /// A memory warning since the take (`generation` behind) cancels it; so does the app not being
    /// active (in the background, or covered by the app switcher or a system sheet). While the
    /// keyboard rises or falls it waits a little more (at most `EngineChoices.rewarmRetries` times,
    /// should a keyboard notification never come), so the web view is not made in that motion.
    private func rewarm(generation: Int, retries: Int) {
        guard warm == nil, generation == memoryWarnings, UIApplication.shared.applicationState == .active else {
            rewarmScheduled = false
            return
        }
        if isKeyboardMoving, retries < EngineChoices.rewarmRetries {
            return waitToRewarm(EngineChoices.rewarmRetry, generation: generation, retries: retries + 1)
        }
        rewarmScheduled = false
        warmUp()
    }

    /// Takes the warmed web view, or makes a new one. Only Personal's tabs take the warm one: it
    /// uses Personal's data store.
    private func takeWebView(isPrivate: Bool, profile: ProfileID) -> (WKWebView, WKUserContentController) {
        if !isPrivate, profile == Profile.defaultID, let warm {
            self.warm = nil
            scheduleRewarm()
            return warm
        }
        let (configuration, controller) = makeConfiguration(isPrivate: isPrivate, profile: profile)
        return (makeWebView(configuration: configuration, controller: controller), controller)
    }

    /// A web view that is not a tab, for a page the app makes itself (the reader view). It shares
    /// the tabs' data store and identity, gets no content rules, page scripts or tab handler, and
    /// `configure` runs on its configuration first (custom schemes, JavaScript off). The caller
    /// shows it while its page is up and releases it after; it never becomes a tab.
    public func makeAuxiliaryWebView(
        isPrivate: Bool = false, profile: ProfileID = Profile.defaultID, configure: (WKWebViewConfiguration) -> Void
    ) -> WKWebView {
        let configuration = baseConfiguration.copy() as! WKWebViewConfiguration
        useStore(of: isPrivate, profile: profile, in: configuration)
        configuration.userContentController = WKUserContentController()
        configure(configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }

    /// The tab's web view, for engine-layer helpers that run scripts in its page (Reader's
    /// `article(in:)` and `isAvailable(in:)`). Pass it straight to the helper: never keep it, add
    /// it to a view or change it. Nil when the tab has no web view (discarded).
    public func webView(for tab: Tab) -> WKWebView? {
        slots[tab.id]?.webView
    }

    // MARK: - Tabs

    /// A new tab, without a web view until it is attached or loads something. Pass `restoring` to
    /// bring back a tab from a previous launch: it restores history, scroll and sessionStorage on
    /// first attach.
    public func makeTab(
        id: UUID = UUID(), restoring state: TabRestorationState? = nil, isPrivate: Bool = false,
        profile: ProfileID = Profile.defaultID
    ) -> Tab {
        Tab(id: id, openerID: nil, isPrivate: isPrivate, profileID: profile, pool: self, restoring: state)
    }

    /// A tab saved earlier (a relaunch, Reopen Closed Tab, the archive) that shows `url` and
    /// `title` until it is opened. Its history, scroll and sessionStorage come from its state file
    /// in `tabStates`, read and decoded off the main thread when it first gets a web view; without
    /// a readable file, `url` loads.
    public func makeSavedTab(id: UUID, url: URL?, title: String, profile: ProfileID = Profile.defaultID) -> Tab {
        let state = TabRestorationState(url: url, title: title, interactionState: nil, sessionStorage: nil)
        let tab = Tab(id: id, openerID: nil, profileID: profile, pool: self, restoring: state)
        tab.readsSavedState = tabStates != nil
        return tab
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
            cancelSwitch(slot)
            webView.frame = container.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(webView)
        }
        catchUpDarkPages(slot)
        if slot.needsReload, isAppActive {
            slot.needsReload = false
            reloadAfterCrash(slot, tab: tab)
        } else if webView.url == nil, !webView.isLoading, !slot.isRestoring, let url = tab.url {
            // The WebContent process died while hidden and WebKit never told us.
            webView.load(URLRequest(url: url))
        }
        enforceTiers()
        // A tab coming on screen in the other mode (a background tab after a fold) switches too.
        scheduleContentModeCheck(after: FixedChoices.contentModeAttachDelay)
        signposter.endInterval(Signposts.tabAttach, interval)
    }

    /// Takes `tab` off screen: stores a thumbnail and applies the tier limits. It stays live until
    /// newer tabs push it down.
    public func detach(_ tab: Tab) {
        guard let slot = slots[tab.id], slot.container != nil else { return }
        thumbnails.capture(slot.webView, for: tab)
        cancelSwitch(slot)
        forgetPlace(of: slot)
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
    ///
    /// - Parameter keepingSavedState: keeps the tab's state file and thumbnail on disk, with its
    ///   latest history and scroll written first, so Reopen Closed Tab and the archive bring it
    ///   back where it was (`makeSavedTab`). Storage deletes the file once no row names the tab.
    ///   Private tabs keep nothing.
    public func close(_ tab: Tab, keepingSavedState: Bool = false) {
        let keep = keepingSavedState && !tab.isPrivate && tabStates != nil
        if let slot = slots.removeValue(forKey: tab.id) {
            // A saved file still being read holds more than the web view does: leave it as it is.
            if keep, !tab.readsSavedState, let tabStates {
                let state = currentState(of: slot, tab: tab, sessionStorage: nil)
                let id = tab.id
                enqueueStateWork {
                    guard let data = try? await Self.encode(state) else { return }
                    try? await tabStates.write(data, for: id)
                }
            }
            tearDown(slot)
        }
        tab.restoration = nil
        tab.tier = .discarded
        tab.pool = nil
        if keep {
            thumbnails.forget(tab.id)
        } else {
            thumbnails.remove(tab.id)
        }
        popupLimiter.reset(tab.id)
        dialogLimiter.reset(tab.id)
        externalLimiter.reset(tab.id)
        crashLimiter.reset(tab.id)
        if !keep, !tab.isPrivate, let tabStates {
            let id = tab.id
            enqueueStateWork { await tabStates.delete([id]) }
        }
        enforceTiers()
    }

    /// Ends the private session once no private tab is left: the private data store (cookies,
    /// caches, storage) and the per-site answers given in private tabs are dropped. Call it after
    /// closing the last private tab.
    public func endPrivateSession() {
        guard let store = privateDataStore else { return }
        privateDataStore = nil
        privateSiteChoices = nil
        privatePasskeyNoticeSites = []
        privatePageAppearanceStore = nil
        // Private answers go with the session; a read still on its way is dropped.
        siteAnswers = siteAnswers.filter { !$0.key.hasPrefix(Self.privateAnswersPrefix) }
        askedWhileOff = askedWhileOff.filter { !$0.key.hasPrefix(Self.privateAnswersPrefix) }
        privateSessionGeneration += 1
        darkPagesScripts[true] = nil
        favicons.endPrivateSession()
        Task { await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
    }

    /// A picture of the attached tab's page at `width` points and
    /// `EngineChoices.swipeSnapshotPixelsPerPoint`, for a full-screen preview (the bar swipe's
    /// neighbour). The snapshot starts at once, so call it before taking the tab off screen.
    /// `completion` gets nil when the tab is not on screen or the page does not answer within
    /// `timeout`.
    public func snapshot(
        of tab: Tab, width: CGFloat, timeout: Duration = EngineChoices.webKitReplyTimeout,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard let slot = slots[tab.id], slot.container != nil, slot.webView.url != nil, width > 0 else {
            return completion(nil)
        }
        let webView = slot.webView
        let configuration = WKSnapshotConfiguration()
        // WebKit multiplies `snapshotWidth` by the screen scale.
        let scale = max(1, webView.traitCollection.displayScale)
        configuration.snapshotWidth = NSNumber(value: Double(width * EngineChoices.swipeSnapshotPixelsPerPoint / scale))
        configuration.afterScreenUpdates = false
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabSnapshot, id: signposter.makeSignpostID(), "full")
        callWithWebKitTimeout(fallback: nil, timeout: timeout) { done in
            webView.takeSnapshot(with: configuration) { image, _ in done(image) }
        } completion: { (image: UIImage?) in
            signposter.endInterval(Signposts.tabSnapshot, interval)
            completion(image)
        }
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

    /// How much of the top of the tab's web view a bar covers (its `obscuredContentInsets.top`):
    /// thumbnails leave it out, so the gallery's zoom does too. Zero without a web view.
    public func obscuredTop(for tab: Tab) -> CGFloat {
        slots[tab.id]?.webView.obscuredContentInsets.top ?? 0
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
        if webView.minimumViewportInset != minimumViewport || webView.maximumViewportInset != maximumViewport {
            webView.setMinimumViewportInset(minimumViewport, maximumViewportInset: maximumViewport)
        }
    }

    /// Discards every tab that is not on screen (Firefox's fix for watchdog kills). Called on
    /// `UIApplication.didReceiveMemoryWarningNotification`.
    public func handleMemoryWarning() {
        warm = nil
        memoryWarnings += 1
        onMemoryWarning?()
        thumbnails.dropMemoryCache()
        favicons.dropMemoryCache()
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
        for slot in slots.values where slot.tab?.isPrivate == false {
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

    // MARK: - Sign-in

    /// A page in `tab` asked for a passkey and was refused (`SignInScripts`). Tells the shell
    /// until it has told the user once for the site this launch. The site is the tab's page, also
    /// when the request came from one of its frames: that is the site the user is signing in to.
    func passkeyRequestFailed(in tab: Tab) {
        guard !passkeysEnabled, let site = NavigationRules.siteKey(for: tab.url) else { return }
        let told = tab.isPrivate ? privatePasskeyNoticeSites.contains(site) : passkeyNoticeSites.contains(site)
        guard !told else {
            Signposts.signposter.emitEvent(Signposts.passkeyUnavailable, "already told")
            return
        }
        let shown = host?.tab(tab, couldNotUsePasskeysOn: site) ?? false
        Signposts.signposter.emitEvent(Signposts.passkeyUnavailable, "\(shown ? "told" : "not shown", privacy: .public)")
        guard shown else { return }
        if tab.isPrivate {
            privatePasskeyNoticeSites.insert(site)
        } else {
            passkeyNoticeSites.insert(site)
        }
    }

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

    /// `Tab.reloadFromOrigin`: after any restore, so the restored page is the one asked for again.
    func reloadFromOrigin(_ tab: Tab) {
        guard tab.pool === self else { return }
        tab.set(\.isAwaitingResubmit, false)
        perform(in: tab) { webView in
            if webView.url == nil, let url = tab.url {
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
            } else {
                webView.reloadFromOrigin()
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

    /// Sets the page appearance of the tab's site (the control in the pill, Site Settings), or
    /// clears it (nil: the site follows the default); remembered like the other per-site choices
    /// (a private tab's for its session only). Applies to the pages on screen at once, without a
    /// reload; returns once they drew it.
    @discardableResult
    func setPageAppearance(_ appearance: PageAppearance?, for tab: Tab, source: String = "menu") async -> Bool {
        guard tab.pool === self, let site = NavigationRules.siteKey(for: tab.url) else { return false }
        return await setPageAppearance(appearance, forSite: site, isPrivate: tab.isPrivate, source: source)
    }

    /// The same for a site named by the caller (an action that may run after the tab moved on).
    @discardableResult
    public func setPageAppearance(_ appearance: PageAppearance?, forSite site: String, isPrivate: Bool, source: String) async -> Bool {
        let store = isPrivate ? privatePageAppearance() : darkPages
        store.setAppearance(appearance, forSite: site)
        Signposts.signposter.emitEvent(
            Signposts.darkPagesToggle, "\(source, privacy: .public) \(appearance?.rawValue ?? "default", privacy: .public)"
        )
        // Private tabs read the regular choices too, so a regular change reaches them as well.
        return await darkPagesChoicesDidChange()
    }

    /// A page reports the choice its script holds. A page kept from before a change (the
    /// back-forward cache, or one that loaded while the change was on its way) gets the current one.
    func reconcileDarkPages(applies: Bool, siteOff: Bool, in tab: Tab) {
        guard let site = NavigationRules.siteKey(for: tab.url), let slot = slots[tab.id] else { return }
        let choices = pageAppearanceChoices(isPrivate: tab.isPrivate)
        guard choices.darkens(site) != applies || (choices.hasOwnChoice(site) && !choices.darkens(site)) != siteOff else { return }
        Task { await applyDarkPagesChoice(to: slot, waiting: false) }
    }

    /// The page's address changed without a new document (a single-page app): a page dark pages
    /// doesn't apply to checks itself again.
    func darkPagesAddressChanged(in slot: Slot) {
        guard let tab = slot.tab, tab.darkPages != .darkened, tab.darkPages != .inactive || !tab.isLoading else { return }
        slot.webView.evaluateJavaScript(DarkPages.recheckSource, in: nil, in: UserScripts.world) { _ in }
    }

    func setContentModeOverride(_ mode: ContentMode?, for tab: Tab) {
        guard let site = NavigationRules.siteKey(for: tab.url) else { return }
        // A choice that matches what the pane would pick anyway is no override: the site goes back
        // to the automatic choice, so it follows the pane again (Duo inner vs outer screen).
        let automatic = NavigationRules.contentMode(forPaneSize: paneSize(of: tab))
        siteChoices(for: tab).contentModes.setContentMode(mode == automatic ? nil : mode, forSite: site)
        reload(tab)
    }

    /// Applies a zoom now and remembers it for the tab's site (100% forgets it). A discarded tab
    /// gets it when its page commits again.
    func setPageZoom(_ zoom: Double, for tab: Tab) {
        guard tab.pool === self else { return }
        if let site = NavigationRules.siteKey(for: tab.url) {
            siteChoices(for: tab).pageZooms.setPageZoom(zoom == PageZoom.actualSize ? nil : zoom, forSite: site)
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
        let zooms = siteChoices(for: tab).pageZooms
        let zoom = site.flatMap(zooms.pageZoom(forSite:)).map(PageZoom.nearestStep(to:)) ?? PageZoom.actualSize
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

    private func paneSize(of tab: Tab) -> CGSize {
        slots[tab.id]?.container?.bounds.size ?? defaultPaneSize
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
        guard tabStates != nil, slot.tab?.isPrivate == false else { return }
        slot.pendingSave?.cancel()
        slot.pendingSave = Task { [weak self, weak slot] in
            try? await Task.sleep(for: EngineChoices.saveDebounce)
            guard !Task.isCancelled, let self, let slot else { return }
            await self.save(slot, fetchingSessionStorage: false)
        }
    }

    private func save(_ slot: Slot, fetchingSessionStorage: Bool) async {
        // A tab whose saved file is still being read must not overwrite it with less.
        guard let tabStates, let tab = slot.tab, slots[tab.id] === slot, !tab.isPrivate, !tab.readsSavedState
        else { return }
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
        let (webView, controller) = takeWebView(isPrivate: tab.isPrivate, profile: tab.profileID)
        let slot = Slot(tab: tab, webView: webView, controller: controller, pool: self)
        slot.lastUse = tick()
        slots[tab.id] = slot
        tab.set(\.tier, .live)
        if let state = tab.restoration {
            tab.restoration = nil
            restore(state, into: slot, readingSavedFile: tab.readsSavedState ? tabStates : nil)
        }
        return slot
    }

    /// Brings a discarded tab back: sessionStorage first (it must be in place before the page
    /// loads), then `interactionState`, which loads the current history item. With
    /// `readingSavedFile`, the state comes from the tab's file (`makeSavedTab`), read off the main
    /// thread first; `fallback` (the address) stands in until then and when there is no file.
    private func restore(_ fallback: TabRestorationState, into slot: Slot, readingSavedFile file: TabStateStore? = nil) {
        let signposter = Signposts.signposter
        slot.restoreInterval = signposter.beginInterval(Signposts.tabRestore, id: signposter.makeSignpostID())
        slot.pendingRestore = fallback
        slot.lastSessionStorage = fallback.sessionStorage
        let webView = slot.webView
        let id = slot.tab?.id
        Task { [weak self, weak slot] in
            var state = fallback
            if let file, let id {
                // A close that just wrote this tab's latest state (Reopen right after) lands first.
                await self?.stateWrites?.value
                if let saved = await Self.readSavedState(id, from: file) { state = saved }
                guard let slot, slot.pendingRestore != nil else { return }
                slot.pendingRestore = state
                slot.lastSessionStorage = state.sessionStorage
                slot.tab?.readsSavedState = false
                if state.isFormResult { slot.tab?.isFormResult = true }
            }
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
            // The restored page is not a new visit: history already has it.
            slot.markCurrentItemVisited()
            slot.pendingRestore = nil
            slot.runPendingAfterRestore()
        }
    }

    private static func apply(_ state: TabRestorationState, to webView: WKWebView, slot: Slot, resubmit: Bool) {
        // The warm web view's empty warm-up page may still be loading (its WebContent process can
        // take a second to start): if it commits after the restore, the tab shows a blank page
        // over its restored history. Stop it first.
        if webView.isLoading { webView.stopLoading() }
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
            if let tabStates = self.tabStates, !tab.isPrivate, !tab.readsSavedState {
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

    @concurrent
    private nonisolated static func readSavedState(_ id: UUID, from store: TabStateStore) async -> TabRestorationState? {
        guard let data = try? await store.read(for: id) else { return nil }
        return try? TabRestorationState(encoded: data)
    }

    /// The per-site stores a tab reads and writes: the persistent ones, or for a private tab
    /// in-memory ones for this private session (reading falls back to the persistent choices).
    private func siteChoices(for tab: Tab) -> SiteChoices {
        guard tab.isPrivate else {
            return SiteChoices(contentModes: contentModes, pageZooms: pageZooms, permissions: permissionStore)
        }
        if let privateSiteChoices { return privateSiteChoices }
        let choices = SiteChoices(
            contentModes: LayeredContentModeStore(base: contentModes),
            pageZooms: LayeredPageZoomStore(base: pageZooms),
            permissions: InMemorySitePermissionStore()
        )
        privateSiteChoices = choices
        return choices
    }

    /// Dark pages choices in private tabs: they read the regular list and keep their own changes
    /// for the private session.
    private func privatePageAppearance() -> any PageAppearanceStore {
        if let privatePageAppearanceStore { return privatePageAppearanceStore }
        let store = LayeredPageAppearanceStore(base: darkPages)
        privatePageAppearanceStore = store
        return store
    }

    private func privateStore() -> WKWebsiteDataStore {
        if let privateDataStore { return privateDataStore }
        let store = WKWebsiteDataStore.nonPersistent()
        privateDataStore = store
        return store
    }

    /// The website data store a tab's pages use: the private session's, Personal's (`dataStore`)
    /// or its profile's own.
    func websiteDataStore(isPrivate: Bool, profile: ProfileID) -> WKWebsiteDataStore {
        if isPrivate { return privateStore() }
        if profile == Profile.defaultID { return dataStore }
        if let store = profileStores[profile] { return store }
        let store = profileStore(profile)
        profileStores[profile] = store
        return store
    }

    /// The store `tab`'s pages use.
    public func websiteDataStore(for tab: Tab) -> WKWebsiteDataStore {
        websiteDataStore(isPrivate: tab.isPrivate, profile: tab.profileID)
    }

    /// Points a configuration copied from the base (Personal's store) at another store when the
    /// web view is private or another profile's.
    private func useStore(of isPrivate: Bool, profile: ProfileID, in configuration: WKWebViewConfiguration) {
        guard isPrivate || profile != Profile.defaultID else { return }
        configuration.websiteDataStore = websiteDataStore(isPrivate: isPrivate, profile: profile)
    }

    /// A deleted profile's store is let go; the caller closed its tabs first and then removes
    /// the store's data (`AppWebsiteData.removeProfileData`).
    public func forgetProfile(_ profile: ProfileID) {
        profileStores[profile] = nil
        favicons.forget(profile: profile)
    }

    private func tearDown(_ slot: Slot) {
        let tab = slot.tab
        slot.pendingSave?.cancel()
        cancelSwitch(slot)
        forgetPlace(of: slot)
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
        tab?.resetMediaState()
    }

    // MARK: - Site Settings' permissions

    /// The remembered permission answers of the sites tabs show, read when a page commits, so the
    /// page sheet's Site Settings lists them at once (a menu is built without waiting).
    private func answersKey(for tab: Tab) -> String? {
        guard let url = tab.url, let site = Self.site(of: url) else { return nil }
        return Self.answersKey(site, isPrivate: tab.isPrivate)
    }

    private static func answersKey(_ site: String, isPrivate: Bool) -> String {
        (isPrivate ? privateAnswersPrefix : "") + site
    }

    private static let privateAnswersPrefix = "private "

    /// What the user answered for the site `tab` shows: nothing for a permission never asked.
    public func rememberedPermissions(for tab: Tab) -> [SitePermission: Bool] {
        answersKey(for: tab).flatMap { siteAnswers[$0] } ?? [:]
    }

    /// The permissions the site `tab` shows asked for while iOS had them off for Plain.
    public func permissionsAskedWhileOff(for tab: Tab) -> Set<SitePermission> {
        answersKey(for: tab).flatMap { askedWhileOff[$0] } ?? []
    }

    /// Notes that `site` asked for `features` while they were off for Plain.
    private func noteAskedWhileOff(_ features: [SystemFeature], site: String, isPrivate: Bool) {
        let permissions = SitePermission.allCases.filter { permission in
            permission.systemFeature.map { features.contains($0) } == true
        }
        askedWhileOff[Self.answersKey(site, isPrivate: isPrivate), default: []].formUnion(permissions)
    }

    /// The site `url` committed in `tab`: reads its answers (one query, off the main thread).
    func loadRememberedPermissions(for tab: Tab, url: URL?) {
        guard let url, let site = Self.site(of: url) else { return }
        let key = Self.answersKey(site, isPrivate: tab.isPrivate)
        let store = siteChoices(for: tab).permissions
        let generation = privateSessionGeneration
        Task { [weak self] in
            let answers = await store.answers(forSite: site)
            guard let self, !tab.isPrivate || generation == privateSessionGeneration else { return }
            siteAnswers[key] = answers
        }
    }

    /// Site Settings changed a permission for the site `tab` shows. A permission taken back
    /// applies from the next page on (`Tab.reload()` by the caller).
    public func setPermission(_ permission: SitePermission, allowed: Bool, for tab: Tab) {
        guard let url = tab.url, let site = Self.site(of: url) else { return }
        siteAnswers[Self.answersKey(site, isPrivate: tab.isPrivate), default: [:]][permission] = allowed
        let store = siteChoices(for: tab).permissions
        Task { await store.setAllowed(allowed, permission, forSite: site) }
    }

    // MARK: - Switched-off features (docs/research/permissions-states.md)

    private func startSystemAccess() {
        guard !systemAccessStarted else { return }
        systemAccessStarted = true
        systemAccess.onChange = { [weak self] changed in self?.systemAccessDidChange(changed) }
        systemAccess.start()
    }

    /// What iOS allows changed: pages are watched for requests of exactly the features that are
    /// off now (from their next page on), and the shell updates what it says.
    private func systemAccessDidChange(_ changed: Set<SystemFeature>) {
        let watched = AccessRequestWatch.watched(by: systemAccess)
        let wasWatching = !accessWatch.isEmpty
        accessWatch = watched
        if watched.isEmpty == wasWatching {
            var controllers = slots.values.map(\.controller)
            if let warm { controllers.append(warm.controller) }
            // WebKit removes user scripts only all at once: keep every other script and swap ours.
            for controller in controllers {
                let others = controller.userScripts.filter { !AccessRequestWatch.isWatchScript($0) }
                controller.removeAllUserScripts()
                others.forEach(controller.addUserScript)
                if !watched.isEmpty { controller.addUserScript(AccessRequestWatch.script) }
            }
            for slot in slots.values {
                slot.setWatchesAccess(!watched.isEmpty)
                // A user script runs from the next document on: the pages already open are
                // watched from now (the script leaves what it already wrapped alone).
                if !watched.isEmpty { slot.webView.evaluateJavaScript(AccessRequestWatch.source, in: nil, in: .page) { _ in } }
                // (Frames already loaded inside those pages are watched from their next load.)
            }
        }
        host?.pool(self, systemAccessDidChange: changed)
    }

    /// A page asked for features iOS has off for Plain (`AccessRequestWatch`). WebKit has already
    /// denied it; the shell says why. Only the tab on screen is heard, as only it may ask.
    func pageAskedForSwitchedOff(_ features: [SystemFeature], in tab: Tab) {
        let blocked = features.filter { systemAccess.access($0).isBlocked }
        guard !blocked.isEmpty, isAttached(tab), let host, let url = tab.url, let site = Self.site(of: url) else { return }
        noteAskedWhileOff(blocked, site: site, isPrivate: tab.isPrivate)
        host.tab(tab, wasDenied: blocked, forSite: site)
    }

    /// `https://example.com`, with the port only when it isn't the scheme's default, as
    /// `TabWebViewHandler.site(of:)` names a security origin.
    static func site(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host(), !host.isEmpty else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    // MARK: - Events from the tab handler

    func slot(for tab: Tab) -> Slot? {
        slots[tab.id]
    }

    /// The slots whose page is on screen.
    func attachedSlots() -> [Slot] {
        slots.values.filter { $0.container != nil }
    }

    /// `createWebViewWith`: a popup, `window.open` or `target=_blank`. The new web view must use
    /// the configuration WebKit passes in, or `window.opener` breaks. It gets its own controller.
    func openChild(configuration: WKWebViewConfiguration, from opener: Tab) -> WKWebView? {
        guard let host, popupLimiter.allow(opener.id) else { return nil }
        let controller = makeController(isPrivate: opener.isPrivate)
        configuration.userContentController = controller
        let webView = makeWebView(configuration: configuration, controller: controller)
        // WebKit's configuration carries the opener's data store: a private opener's child is private.
        let child = Tab(
            id: UUID(), openerID: opener.id, isPrivate: opener.isPrivate, profileID: opener.profileID, pool: self, restoring: nil
        )
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
        if let site = NavigationRules.siteKey(for: url),
           let mode = siteChoices(for: tab).contentModes.contentMode(forSite: site) {
            return mode
        }
        return NavigationRules.contentMode(forPaneSize: paneSize(of: tab))
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
        // Off for Plain in iOS: no question of Plain's could help. WebKit usually refuses these
        // before asking (a simulator's stand-in cameras skip that check); either way the page is
        // refused, nothing is remembered, and the shell says why.
        let blocked = permissions.compactMap(\.systemFeature).filter { systemAccess.access($0).isBlocked }
        if !blocked.isEmpty {
            noteAskedWhileOff(blocked, site: site, isPrivate: tab.isPrivate)
            if isAttached(tab), let host { host.tab(tab, wasDenied: blocked, forSite: site) }
            return false
        }
        // A private tab's answers last for its private session and never reach disk.
        let permissionStore = siteChoices(for: tab).permissions
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
        let key = unknown.map(\.rawValue).joined(separator: ",") + " " + site + (tab.isPrivate ? " private" : "")
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
        let generation = privateSessionGeneration
        let allowed = await ask.value
        pendingPermissionAsks[key] = nil
        // A private answer that arrives after its session ended is not kept.
        if !tab.isPrivate || generation == privateSessionGeneration {
            for permission in unknown { siteAnswers[Self.answersKey(site, isPrivate: tab.isPrivate), default: [:]][permission] = allowed }
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
        /// Desktop or mobile: the mode in flight and a switch in progress.
        var contentMode = SlotContentMode()
        /// Translate Page on the current document.
        var translation = SlotTranslation()
        /// What each frame's media script last reported, by the frame's own id.
        private var frameMedia: [String: (playing: Bool, pictureInPicture: Bool)] = [:]
        private var afterRestore: [(WKWebView) -> Void] = []
        /// The back-forward item last reported through `Tab.onVisit`.
        private weak var visitedItem: WKBackForwardListItem?
        private var observations: [NSKeyValueObservation] = []

        init(tab: Tab, webView: WKWebView, controller: WKUserContentController, pool: WebViewPool) {
            self.tab = tab
            self.webView = webView
            self.controller = controller
            handler = TabWebViewHandler(tab: tab, pool: pool)
            webView.navigationDelegate = handler
            webView.uiDelegate = handler
            let messages = EngineMessageHandler(slot: self)
            controller.add(messages, contentWorld: UserScripts.world, name: UserScripts.mediaHandlerName)
            controller.add(messages, contentWorld: UserScripts.world, name: UserScripts.subframePressHandlerName)
            controller.add(messages, contentWorld: UserScripts.world, name: SignInScripts.passkeyHandlerName)
            controller.add(messages, contentWorld: UserScripts.world, name: DarkPages.handlerName)
            controller.addScriptMessageHandler(
                TranslationMessageHandler(slot: self), contentWorld: PageTranslation.world, name: PageTranslation.handlerName
            )
            setWatchesAccess(!pool.accessWatch.isEmpty)
            observe()
        }

        /// Whether the page world's `AccessRequestWatch` handler is on this tab's controller: only
        /// while a feature a page can ask for is off for Plain.
        private(set) var watchesAccess = false

        func setWatchesAccess(_ watches: Bool) {
            guard watches != watchesAccess, let tab else { return }
            watchesAccess = watches
            if watches {
                controller.add(AccessRequestWatch.Handler(tab: tab), contentWorld: .page, name: AccessRequestWatch.handlerName)
            } else {
                controller.removeScriptMessageHandler(forName: AccessRequestWatch.handlerName, contentWorld: .page)
            }
        }

        /// When a finger last went down inside an iframe, in milliseconds since 1970 (the page's
        /// `Date.now()`). A main-frame press older than this is not the one a menu is for.
        var lastSubframePress: Double = 0

        /// Bumped whenever media state is reset (new document, crash, teardown), so a WebKit
        /// playback answer requested before it is dropped instead of overwriting the reset.
        private var mediaGeneration = 0

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

        /// The choices revision this page was last told (`WebViewPool.darkPagesRevision`).
        var darkPagesRevision = 0

        /// The page's dark-pages script reported (`document`: its token; nil when the shell resets
        /// the state for a new document). A darkened page's own background is light, so the area
        /// past its edges (overscroll) takes the darkened color instead of the page's.
        func receiveDarkPagesState(_ state: DarkPagesState, document: String? = nil) {
            tab?.set(\.darkPagesDocument, document)
            tab?.set(\.darkPages, state)
            if document == nil { tab?.set(\.isLightless, false) }
            let darkens = state == .darkened
            guard darkens != darkensOverscroll else { return }
            darkensOverscroll = darkens
            webView.underPageBackgroundColor = darkens ? DarkPages.overscrollColor : nil
        }

        /// The overscroll area shows the darkened color (`receiveDarkPagesState`).
        private var darkensOverscroll = false

        /// A new main-frame document committed (the old frames are gone) or the process died.
        func clearMediaReports() {
            mediaGeneration += 1
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
                        guard let self, let tab = self.tab, let url = webView.url else { return }
                        let sameDocument = tab.url != nil && tab.url != url && !webView.isLoading
                        tab.set(\.url, url)
                        if sameDocument { tab.pool?.darkPagesAddressChanged(in: self) }
                        self.handler.updateSecurity(of: webView)
                    }
                },
                webView.observe(\.title, options: .new) { [weak self] webView, _ in
                    MainActor.assumeIsolated {
                        guard webView.url != nil else { return }
                        self?.tab?.set(\.title, webView.title ?? "")
                        self?.reportVisitTitle()
                    }
                },
                webView.observe(\.isLoading, options: .new) { [weak self] webView, _ in
                    MainActor.assumeIsolated {
                        self?.tab?.set(\.isLoading, webView.isLoading)
                        if !webView.isLoading { self?.reportVisit() }
                    }
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

        /// A load ended: report the page once per back-forward item (`Tab.onVisit`). A load that
        /// failed or stopped before committing ends on the item already reported; no current item
        /// means nothing ever committed. A restore in flight is not a visit.
        private func reportVisit() {
            guard !isRestoring, let tab, let url = webView.url, let item = webView.backForwardList.currentItem,
                  item !== visitedItem
            else { return }
            visitedItem = item
            tab.onVisit?(url, webView.title)
        }

        func markCurrentItemVisited() {
            visitedItem = webView.backForwardList.currentItem
        }

        /// Titles rename only the page last reported, never an earlier visit to the same address.
        private func reportVisitTitle() {
            guard let tab, let url = webView.url, let title = webView.title, !title.isEmpty,
                  let item = webView.backForwardList.currentItem, item === visitedItem
            else { return }
            tab.onVisitTitleChange?(url, title)
        }

        func invalidate() {
            observations.forEach { $0.invalidate() }
            observations = []
            endRestoreInterval()
            // The tab may get a new slot; nothing this one asked for may reach it.
            mediaGeneration += 1
            tab = nil
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
            let generation = mediaGeneration
            let state = await withWebKitTimeout(fallback: WKMediaPlaybackState.none) { done in
                webView.requestMediaPlaybackState(completionHandler: done)
            }
            guard generation == mediaGeneration else { return }
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

    /// Receives the media and iframe-press reports. The controller keeps it strongly, so it holds the slot
    /// weakly; the pool removes it when the web view goes away.
    final class EngineMessageHandler: NSObject, WKScriptMessageHandler {
        private weak var slot: Slot?

        init(slot: Slot) {
            self.slot = slot
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == UserScripts.subframePressHandlerName {
                if let time = message.body as? Double { slot?.lastSubframePress = time }
                if message.body as? String == "typed" { slot?.contentMode.subframeTyped = true }
                return
            }
            if message.name == SignInScripts.passkeyHandlerName {
                if let tab = slot?.tab { tab.pool?.passkeyRequestFailed(in: tab) }
                return
            }
            if message.name == DarkPages.handlerName {
                if !message.frameInfo.isMainFrame {
                    // A same-origin frame asks for the engine; it runs in that frame alone.
                    guard let body = message.body as? [String: Any], body[DarkPages.frameRequest] as? Bool == true,
                          let tab = slot?.tab, let pool = tab.pool, let webView = message.webView else { return }
                    webView.evaluateJavaScript(
                        pool.darkPagesSource(isPrivate: tab.isPrivate), in: message.frameInfo, in: UserScripts.world
                    ) { _ in }
                    return
                }
                guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                      let raw = body["state"] as? String, let state = DarkPagesState(rawValue: raw) else { return }
                // A report from a document that already left. A same-site page runs in the same
                // process, whose messages arrive in order: the old page's before the new one's
                // commit, which resets the state. A cross-site navigation runs in another process,
                // so its last words can arrive after the new page committed: dropped here.
                if let host = message.webView?.url?.host(), host != message.frameInfo.securityOrigin.host { return }
                slot?.receiveDarkPagesState(state, document: body["doc"] as? String)
                slot?.tab?.set(\.isLightless, body["lightless"] as? Bool ?? false)
                if let tab = slot?.tab, let applies = body["applies"] as? Bool, let siteOff = body["siteOff"] as? Bool {
                    tab.pool?.reconcileDarkPages(applies: applies, siteOff: siteOff, in: tab)
                }
                return
            }
            guard let body = message.body as? [String: Any], let id = body["id"] as? String else { return }
            slot?.receiveMediaReport(
                frame: id, playing: body["playing"] as? Bool ?? false, pictureInPicture: body["pip"] as? Bool ?? false
            )
        }
    }
}
#endif
