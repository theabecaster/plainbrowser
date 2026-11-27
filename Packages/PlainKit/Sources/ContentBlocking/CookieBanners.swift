import BrowserCore
import Foundation
import os
import PerfSignposts
import WebKit

/// The sites where the user turned cookie banner handling off, remembered automatically like the
/// other per-site choices. Read on every page's first message, so it answers from memory: load
/// the stored list after launch and write changes behind it.
public protocol SiteCookieBannersStore: AnyObject {
    var offSites: Set<String> { get }
    func setCookieBannersOff(_ off: Bool, forSite site: String)
}

/// Choices kept in memory: the default until Storage provides a persistent store, and the store
/// for private tabs (layered over the persistent one).
public final class InMemorySiteCookieBannersStore: SiteCookieBannersStore {
    public private(set) var offSites: Set<String> = []
    private let base: (any SiteCookieBannersStore)?
    private var own: [String: Bool] = [:]

    /// - Parameter base: read through it, with this store's own choices on top (private tabs).
    public init(base: (any SiteCookieBannersStore)? = nil) {
        self.base = base
        offSites = base?.offSites ?? []
    }

    private func recompute() {
        var sites = base?.offSites ?? []
        for (site, off) in own {
            if off { sites.insert(site) } else { sites.remove(site) }
        }
        offSites = sites
    }

    public func setCookieBannersOff(_ off: Bool, forSite site: String) {
        own[site] = off
        recompute()
    }

    /// The base store changed (private tabs see regular choices they have not overridden).
    func baseDidChange() {
        recompute()
    }
}

/// Answers cookie consent banners on every page, rejecting where the banner allows it
/// (`FixedChoices.cookieBannersHandled`). Research and the choice of engine:
/// docs/research/cookie-banners.md and docs/decisions.md.
///
/// The engine is DuckDuckGo's autoconsent (MPL-2.0), built by tools/autoconsent into
/// `Resources/CookieBanners`. It runs in Plain's own content world, so pages can't see it:
/// - **Main frames** get the engine at document start. It asks for its config and rules (`init`);
///   the reply carries the generic rules plus the site-specific rules whose address pattern
///   matches the page, matched here off the main thread, so a page never parses rules it can't use.
/// - **Subframes** get a one-line script that reports the frame's address. Only a frame a rule
///   targets (a consent dialog in an iframe, such as Sourcepoint's) gets the engine, injected into
///   that frame alone; ad and video frames cost nothing.
/// - **Eval steps** (a few rules call a consent manager's own JavaScript API, for example
///   `OneTrust.RejectAll()`) run in the asking frame's page world, wrapped so they only ever return
///   a Boolean.
/// - **Per-site off** answers `init` with the engine disabled; nothing is clicked or hidden.
/// - **Loop guard:** a site whose banner comes back after every answer (a page that reloads
///   itself on consent) is left alone in that tab for the rest of the launch after
///   `FixedChoices.cookieBannerLoopLimit` answers in `cookieBannerLoopWindow`.
///
/// The EasyList Cookie List in the content-blocking lists still hides banners this engine has no
/// rule for (and some it does: a banner hidden by the list is not visible, so it is left
/// unanswered, which for consent means "no").
@MainActor
public final class CookieBanners {
    /// The message handler both scripts post to.
    static let handlerName = "plainCookieBanners"
    /// Plain's world for the engine: separate from the page and from the engine's other scripts.
    static let world = WKContentWorld.world(name: "PlainCookieBanners")

    /// Called when a frame's banner was answered (true: rejected or dismissed by the rules) or the
    /// engine gave up on it (false), with the page's web view. For tests and logs.
    public var onAnswered: ((WKWebView, Bool) -> Void)?
    /// Every message the engine sends, by type, for tests.
    var onMessage: ((String, [String: Any]) -> Void)?

    private let store: any SiteCookieBannersStore
    private var privateStore: InMemorySiteCookieBannersStore?
    private let resourceDirectory: URL?
    private let logger = Logger(subsystem: Signposts.subsystem, category: "cookieBanners")
    private var resources: Resources?
    private var prepareTask: Task<Void, Never>?
    /// `prepare()` finished (with or without the resources).
    private var isPrepared = false
    /// Controllers made before the resources were read; they get the scripts when they are.
    private let waiting = NSHashTable<WKUserContentController>.weakObjects()
    /// Controllers that already have the scripts and the handler (a handler can be added once).
    private let installed = NSHashTable<WKUserContentController>.weakObjects()
    /// Recent answers per web view and site, for the loop guard (a page that reloads itself after
    /// each answer), and the sites that tripped it in that web view; gone with the web view.
    private let loops = NSMapTable<WKWebView, LoopState>.weakToStrongObjects()

    private final class LoopState {
        var answers: [String: [ContinuousClock.Instant]] = [:]
        var looping: Set<String> = []
    }
    private lazy var handler = MessageHandler(owner: self)

    struct Resources: Sendable {
        let engine: String
        let rules: CookieBannerRules
    }

    /// The engine for main frames, made once from `resources`.
    private var mainScript: WKUserScript?

    /// - Parameters:
    ///   - store: the sites where the user turned it off (private tabs layer their own on top).
    ///   - resourceDirectory: where `autoconsent.js` and `rules.json` are; the bundle by default.
    public init(store: any SiteCookieBannersStore = InMemorySiteCookieBannersStore(), resourceDirectory: URL? = nil) {
        self.store = store
        self.resourceDirectory = resourceDirectory
    }

    /// The engine and rules built by tools/autoconsent, in the package's resources.
    nonisolated static var bundledDirectory: URL? {
        Bundle.module.resourceURL?.appending(path: "CookieBanners")
    }

    /// Reads the engine and its rules off the main thread (about 0.7 MB), then installs the scripts
    /// in every controller made meanwhile. Call once after the first frame.
    public func prepare() async {
        if prepareTask == nil {
            let directory = resourceDirectory ?? Self.bundledDirectory
            prepareTask = Task { [weak self] in
                let interval = Signposts.signposter.beginInterval(Signposts.cookieBannersPrepare)
                let loaded = await Task.detached(priority: .utility) { () -> Resources? in
                    guard let directory, FixedChoices.cookieBannersHandled else { return nil }
                    return try? Resources(
                        engine: String(contentsOf: directory.appending(path: "autoconsent.js"), encoding: .utf8),
                        rules: CookieBannerRules(data: Data(contentsOf: directory.appending(path: "rules.json")))
                    )
                }.value
                Signposts.signposter.endInterval(Signposts.cookieBannersPrepare, interval)
                guard let self else { return }
                self.isPrepared = true
                if loaded == nil { self.logger.error("cookie banner resources missing") }
                self.resources = loaded
                self.mainScript = loaded.map {
                    WKUserScript(source: $0.engine, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world)
                }
                for controller in self.waiting.allObjects { self.install(in: controller) }
                self.waiting.removeAllObjects()
            }
        }
        await prepareTask?.value
    }

    /// Adds the scripts and the handler to a tab's controller. Cheap and synchronous; a controller
    /// made before `prepare()` finished gets them when it does.
    public func install(in controller: WKUserContentController) {
        guard !installed.contains(controller) else { return }
        guard let mainScript else {
            if !isPrepared { waiting.add(controller) }
            return
        }
        installed.add(controller)
        controller.addScriptMessageHandler(handler, contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(mainScript)
        controller.addUserScript(Self.frameScript)
    }

    /// Reports a subframe's address, so the engine goes only into frames a rule targets.
    static let frameScript = WKUserScript(
        source: """
            (() => {
              if (window === window.top || !/^https?:$/.test(location.protocol)) return;
              const h = globalThis.webkit && webkit.messageHandlers && webkit.messageHandlers.\(handlerName);
              if (h) h.postMessage({ type: 'frame', url: location.href }).catch(() => {});
            })();
            """,
        injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world
    )

    // MARK: Per site

    /// Whether the user turned it off for `url`'s site (a private tab's own choice first).
    public func isOff(for url: URL?, isPrivate: Bool) -> Bool {
        let sites = isPrivate ? privateSites().offSites : store.offSites
        return SiteKey.host(url?.host(), isIn: sites)
    }

    /// The page menu's switch: remembered for the site (for the private session only in a private
    /// tab). Reload the page to apply it.
    public func setOff(_ off: Bool, for url: URL?, isPrivate: Bool) {
        guard let site = SiteKey.site(forHost: url?.host()) else { return }
        Signposts.signposter.emitEvent(Signposts.cookieBannersToggle, "\(off ? "off" : "on")")
        if isPrivate {
            privateSites().setCookieBannersOff(off, forSite: site)
        } else {
            store.setCookieBannersOff(off, forSite: site)
            privateStore?.baseDidChange()
            if !off {
                for case let webView as WKWebView in loops.keyEnumerator().allObjects {
                    loops.object(forKey: webView)?.looping.remove(site)
                }
            }
        }
    }

    /// The regular list arrived from Storage after launch: private tabs read through it.
    public func storedSitesDidLoad() {
        privateStore?.baseDidChange()
    }

    /// Private tabs' choices go with the private session.
    public func endPrivateSession() {
        privateStore = nil
    }

    private func privateSites() -> InMemorySiteCookieBannersStore {
        if let privateStore { return privateStore }
        let layered = InMemorySiteCookieBannersStore(base: store)
        privateStore = layered
        return layered
    }

    // MARK: Messages

    /// The engine's config: reject automatically, hide known banners while they are judged (so
    /// they don't flash), no heuristic guessing (a wrong click is worse than a visible banner).
    private static func config(enabled: Bool) -> [String: Any] {
        [
            "enabled": enabled,
            "autoAction": "optOut",
            "disabledCmps": [String](),
            "enablePrehide": true,
            "enableCosmeticRules": true,
            "enableGeneratedRules": true,
            "enableHeuristicDetection": false,
            "heuristicMode": "off",
            "detectRetries": FixedChoices.cookieBannerDetectRetries,
            "isMainWorld": false,
            "prehideTimeout": FixedChoices.cookieBannerPrehideTimeout,
            "logs": ["lifecycle": false, "rulesteps": false, "detectionsteps": false, "evals": false,
                     "errors": false, "messages": false, "waits": false],
        ]
    }

    fileprivate func receive(_ message: WKScriptMessage) async -> Any? {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let webView = message.webView, let resources else { return nil }
        let frame = message.frameInfo
        onMessage?(type, body)
        switch type {
        case "init":
            let isMain = frame.isMainFrame
            // The page's site decides. A main frame reports its own address (`location.href`,
            // read in Plain's world, so the page can't fake it), which is right even before the
            // web view's `url` catches up and for pages loaded from a string.
            let page = isMain ? ((body["url"] as? String).flatMap(URL.init(string:)) ?? webView.url) : webView.url
            let isPrivate = !webView.configuration.websiteDataStore.isPersistent
            let site = SiteKey.site(forHost: page?.host())
            let loop = site.map { loops.object(forKey: webView)?.looping.contains($0) ?? false } ?? false
            let enabled = !isOff(for: page, isPrivate: isPrivate) && !loop
            var reply: [String: Any] = ["type": "initResp", "config": Self.config(enabled: enabled)]
            guard enabled else { return reply }
            let address = (body["url"] as? String) ?? frame.request.url?.absoluteString ?? ""
            let rules = resources.rules
            let specific = await Task.detached(priority: .userInitiated) {
                rules.specificRules(for: address, mainFrame: isMain)
            }.value
            if isMain { reply["generic"] = rules.generic }
            reply["specific"] = specific
            return reply
        case "frame":
            guard let address = body["url"] as? String, !frame.isMainFrame,
                  !isOff(for: webView.url, isPrivate: !webView.configuration.websiteDataStore.isPersistent)
            else { return nil }
            let rules = resources.rules
            let targeted = await Task.detached(priority: .userInitiated) { rules.subframeNeedsEngine(address) }.value
            if targeted {
                _ = await Self.evaluate(resources.engine, in: webView, frame: frame, world: Self.world)
            }
            return nil
        case "eval":
            guard let id = body["id"] as? String, let code = body["code"] as? String else { return nil }
            let wrapped = "(() => { try { return !!(\(code)); } catch (e) { return false; } })()"
            let result = await Self.evaluate(wrapped, in: webView, frame: frame, world: .page)
            return ["type": "evalResp", "id": id, "result": result ?? false]
        case "optOutResult":
            let succeeded = body["result"] as? Bool ?? false
            Signposts.signposter.emitEvent(Signposts.cookieBannerAnswered, "\(succeeded ? "rejected" : "failed")")
            if succeeded { noteAnswer(on: webView.url, in: webView) }
            onAnswered?(webView, succeeded)
            return nil
        case "autoconsentDone":
            // A cosmetic rule only hid the banner; an opt-out already reported through optOutResult.
            if body["isCosmetic"] as? Bool == true { onAnswered?(webView, true) }
            return nil
        default:
            return nil
        }
    }

    /// Runs `source` in one frame and returns its Boolean result (nil for anything else or an error).
    private static func evaluate(_ source: String, in webView: WKWebView, frame: WKFrameInfo, world: WKContentWorld) async -> Bool? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(source, in: frame, in: world) { result in
                continuation.resume(returning: (try? result.get()) as? Bool)
            }
        }
    }

    /// The loop guard: the same site answered again and again in one tab in a short time.
    private func noteAnswer(on url: URL?, in webView: WKWebView) {
        guard let site = SiteKey.site(forHost: url?.host()) else { return }
        let state = loops.object(forKey: webView) ?? LoopState()
        loops.setObject(state, forKey: webView)
        let now = ContinuousClock.now
        var answers = (state.answers[site] ?? []).filter { now - $0 < FixedChoices.cookieBannerLoopWindow }
        answers.append(now)
        state.answers[site] = answers
        if answers.count >= FixedChoices.cookieBannerLoopLimit {
            state.looping.insert(site)
            logger.notice("cookie banner keeps coming back; leaving the site alone this launch")
        }
    }

    /// The controller keeps its handler strongly; the handler holds its owner weakly.
    private final class MessageHandler: NSObject, WKScriptMessageHandlerWithReply {
        weak var owner: CookieBanners?

        init(owner: CookieBanners) {
            self.owner = owner
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) async -> (Any?, String?) {
            (await owner?.receive(message), nil)
        }
    }
}

/// autoconsent's rules, split by tools/autoconsent: `generic` for every main frame, and one
/// self-contained ruleset per site-specific rule with the address pattern that selects it.
/// Immutable after loading; matching runs off the main thread.
struct CookieBannerRules: Sendable {
    struct Specific: @unchecked Sendable {
        /// `NSRegularExpression` is immutable and documented thread-safe.
        let pattern: NSRegularExpression
        let main: Bool
        let frame: Bool
        let json: String
    }

    let version: String
    /// The generic main-frame ruleset as JSON, sent as is.
    let generic: String
    let specific: [Specific]

    init(data: Data) throws {
        struct File: Decodable {
            struct Entry: Decodable {
                let p: String
                let m: Bool
                let f: Bool
                let r: String
            }

            let version: String
            let generic: String
            let specific: [Entry]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        version = file.version
        generic = file.generic
        // autoconsent's patterns are JavaScript regular expressions; the few ICU can't read are
        // skipped (their sites get the generic rules and the cosmetic list).
        specific = file.specific.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.p) else { return nil }
            return Specific(pattern: regex, main: entry.m, frame: entry.f, json: entry.r)
        }
    }

    /// The rulesets whose pattern matches `url` and that run in this kind of frame.
    func specificRules(for url: String, mainFrame: Bool) -> [String] {
        let range = NSRange(url.startIndex..., in: url)
        return specific.compactMap { rule in
            guard mainFrame ? rule.main : rule.frame else { return nil }
            return rule.pattern.firstMatch(in: url, range: range) == nil ? nil : rule.json
        }
    }

    /// A subframe gets the engine when a rule targets it, or when it is a Sourcepoint consent
    /// dialog (the engine's built-in `Sourcepoint-frame`, which matches by path and query).
    func subframeNeedsEngine(_ url: String) -> Bool {
        if !specificRules(for: url, mainFrame: false).isEmpty { return true }
        guard let components = URLComponents(string: url) else { return false }
        let query = Set((components.queryItems ?? []).map(\.name))
        if components.host == "ccpa-notice.sp-prod.net" || components.host == "ccpa-pm.sp-prod.net" { return true }
        let paths: Set<String> = ["/index.html", "/privacy-manager/index.html", "/ccpa_pm/index.html", "/us_pm/index.html"]
        return paths.contains(components.path) && !query.isDisjoint(with: ["message_id", "requestUUID", "consentUUID"])
    }
}
