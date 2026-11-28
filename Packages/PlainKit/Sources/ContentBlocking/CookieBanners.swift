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
/// - **Main frames** get a small probe at document start, not the 129 KB engine: parsing the engine
///   on every page cost a long article 20–50 ms of load. The probe reports the page's address; a
///   site with a rule of its own gets the engine at once. Otherwise the probe watches for signs of
///   a consent manager (its script or frame host among the page's resources, or one of the common
///   banner containers in the document, checked at DOMContentLoaded, at load and twice after) until
///   `FixedChoices.cookieBannerWatchMilliseconds` after load; the engine goes into the page only
///   when one shows. Pages without a banner never load the engine; the EasyList Cookie List still hides the
///   long tail the probe doesn't know.
/// - **The engine** asks for its config and rules (`init`); the reply carries the generic rules
///   plus the site-specific rules whose address pattern matches the page, matched here off the
///   main thread, so a page never parses rules it can't use.
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

    /// The probe for main frames, made once the resources are read.
    private var probeScript: WKUserScript?

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
                self.probeScript = loaded.map { _ in Self.probe }
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
        guard let probeScript else {
            if !isPrepared { waiting.add(controller) }
            return
        }
        installed.add(controller)
        controller.addScriptMessageHandler(handler, contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(probeScript)
        controller.addUserScript(Self.frameScript)
    }

    /// Consent managers' script and frame hosts (a page's resource from one of these, or a
    /// subdomain, means a banner is likely). The common ones by reach: OneTrust and CookiePro,
    /// Cookiebot, Didomi, Usercentrics, TrustArc, Quantcast and the IAB's consensu.org, Sourcepoint,
    /// consentmanager, Google's Funding Choices, iubenda, Termly, Osano, CookieYes, Axeptio, Civic,
    /// CookieFirst, Sirdata, Commanders Act, Ketch, Crownpeak, LiveRamp, Cookie Information,
    /// CookieHub, Cookie-Script, Clym.
    static let consentHosts = [
        "cookielaw.org", "onetrust.com", "cookiepro.com", "cookiebot.com", "privacy-center.org",
        "usercentrics.eu", "trustarc.com", "truste.com", "consensu.org", "quantcast.com",
        "privacy-mgmt.com", "sp-prod.net", "consentmanager.net", "fundingchoicesmessages.google.com",
        "iubenda.com", "termly.io", "osano.com", "cookieyes.com", "cdn-cookieyes.com", "axept.io",
        "civiccomputing.com", "cookiefirst.com", "consentframework.com", "commander1.com",
        "ketchcdn.com", "ketchjs.com", "evidon.com", "privacymanager.io", "cookieinformation.com",
        "cookiehub.net", "cookie-script.com", "clym-widget.net", "clym-sdk.net",
    ]

    /// Banner containers of consent managers the engine has rules for: the hosted managers above
    /// when a site serves them itself, and the common self-hosted plugins (Complianz, Borlabs,
    /// CookieYes, Cookie Notice, GDPR Cookie Compliance, Cookie Law Info, Klaro, Shopify). The
    /// probe hides these from the first frame until the engine has answered (`prehideCSS`).
    static let managerSelectors = [
        "#onetrust-consent-sdk", "#onetrust-banner-sdk", "#CybotCookiebotDialog", "#didomi-host",
        "#usercentrics-root", "#usercentrics-cmp-ui", "#truste-consent-track", "#consent_blackbar",
        ".qc-cmp2-container", "[id^='sp_message_container']", "#cmpbox", "#cmpwrapper", ".fc-consent-root",
        "#iubenda-cs-banner", "#termly-code-snippet-support", ".osano-cm-window", ".cky-consent-container",
        "#axeptio_overlay", "#cookiefirst-root", "#cookiescript_injected",
        "#cookie-law-info-bar", "#cookie-notice", "#cmplz-cookiebanner-container", ".cmplz-cookiebanner",
        "#BorlabsCookieBox", "#moove_gdpr_cookie_info_bar", "#klaro", "#shopify-pc__banner",
    ]

    /// Banner containers the probe looks for: the consent managers above, Civic's and CookieHub's
    /// short ids (too plain to hide ahead), and a few generic names (never hidden ahead: the
    /// engine may have no rule for them). Ids and classes only, so the
    /// check stays well under a millisecond on a long page.
    static let bannerSelectors = managerSelectors + [
        "#ccc", "#ch2", "#cookie-banner", "#cookieBanner", "#cookie-consent", "#cookieConsent", "#cookiebanner",
        ".cookie-banner", ".cookie-consent", ".cookieconsent", ".cc-window", "#gdpr-cookie-message",
    ]

    /// How the probe hides a known consent manager's banner until the engine has answered it:
    /// the engine's own prehide style (transparent, behind the page, no touches), so the engine
    /// still finds the banner and clicks through it.
    static let prehideCSS = managerSelectors.joined(separator: ",")
        + " { opacity: 0 !important; z-index: -1 !important; pointer-events: none !important; }"

    /// The main frame's probe: reports the page (a site rule starts the engine at once), then
    /// watches for a consent manager and asks for the engine when it sees one.
    ///
    /// From document start it also hides the banners of the consent managers the engine knows
    /// (`prehideCSS`, one constructed style sheet, never a DOM node). The engine comes only after
    /// the probe has seen a sign (DOMContentLoaded at the earliest) and has its own prehide only
    /// from then on, so without this a known banner showed for up to a second before it was
    /// rejected. The sheet goes when the engine has answered (the app calls
    /// `__plainCookieUnhide`), `FixedChoices.cookieBannerPrehideTimeout` after the engine started
    /// (as the engine's own prehide does), at once on a site turned off, and when the watch ends
    /// without a sign.
    static let probe = WKUserScript(
        source: """
            (() => {
              if (window !== window.top || !/^https?:$/.test(location.protocol)) return;
              const h = globalThis.webkit && webkit.messageHandlers && webkit.messageHandlers.\(handlerName);
              if (!h || globalThis.__plainCookieProbe) return;
              globalThis.__plainCookieProbe = true;
              const hosts = \(jsArray(consentHosts));
              const selector = \(jsString(bannerSelectors.joined(separator: ",")));
              const hide = new CSSStyleSheet();
              hide.replaceSync(\(jsString(prehideCSS)));
              document.adoptedStyleSheets = [...document.adoptedStyleSheets, hide];
              let hideTimer = 0;
              const unhide = () => {
                clearTimeout(hideTimer);
                const list = document.adoptedStyleSheets;
                if (list.includes(hide)) document.adoptedStyleSheets = list.filter((s) => s !== hide);
              };
              globalThis.__plainCookieUnhide = unhide;
              const started = () => { clearTimeout(hideTimer); hideTimer = setTimeout(unhide, \(FixedChoices.cookieBannerPrehideTimeout)); };
              // A deadline from the start: a page whose load never ends (a hanging request) is
              // never probed after DOMContentLoaded, and nothing may stay hidden for good.
              hideTimer = setTimeout(unhide, \(FixedChoices.cookieBannerWatchMilliseconds));
              // `answered`: the app replied to the page message, so the engine was not started
              // for a site rule; a sign seen before that waits for the reply (one start a page).
              let done = false, answered = false, seen = null, observer = null;
              const stop = () => { done = true; if (observer) observer.disconnect(); };
              const fire = (reason) => {
                if (done) return;
                if (!answered) { seen = seen || reason; return; }
                stop();
                started();
                h.postMessage({ type: 'probe', url: location.href, reason }).catch(() => {});
              };
              const known = (name) => {
                let host;
                try { host = new URL(name).hostname; } catch (e) { return false; }
                return hosts.some((s) => host === s || host.endsWith('.' + s));
              };
              const look = () => { if (!done && document.querySelector(selector)) fire('page'); };
              h.postMessage({ type: 'page', url: location.href }).then((reply) => {
                if (reply && reply.stop) {
                  if (reply.engine) started(); else unhide();
                  return stop();
                }
                answered = true;
                if (seen) fire(seen);
              }, () => { answered = true; if (seen) fire(seen); });
              try {
                observer = new PerformanceObserver((list) => {
                  if (list.getEntries().some((entry) => known(entry.name))) fire('host');
                });
                observer.observe({ type: 'resource', buffered: true });
              } catch (e) {}
              document.addEventListener('DOMContentLoaded', look, { once: true });
              addEventListener('load', () => {
                look();
                setTimeout(look, \(FixedChoices.cookieBannerWatchMilliseconds / 3));
                setTimeout(() => { look(); if (!done) { stop(); unhide(); } }, \(FixedChoices.cookieBannerWatchMilliseconds));
              }, { once: true });
            })();
            """,
        injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world
    )

    private static func jsString(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static func jsArray(_ strings: [String]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: strings)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
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
        case "page":
            // The probe's first word: a site turned off stops it, a site with its own rule gets
            // the engine now (near document start, so its banner is hidden before it shows).
            guard frame.isMainFrame else { return nil }
            let page = (body["url"] as? String).flatMap(URL.init(string:)) ?? webView.url
            let isPrivate = !webView.configuration.websiteDataStore.isPersistent
            let site = SiteKey.site(forHost: page?.host())
            let loop = site.map { loops.object(forKey: webView)?.looping.contains($0) ?? false } ?? false
            if isOff(for: page, isPrivate: isPrivate) || loop { return ["stop": true] }
            let address = page?.absoluteString ?? ""
            let rules = resources.rules
            let hasSiteRule = await Task.detached(priority: .userInitiated) {
                !rules.specificRules(for: address, mainFrame: true).isEmpty
            }.value
            guard hasSiteRule else { return nil }
            startEngine(in: webView, frame: frame, reason: "site rule")
            return ["stop": true, "engine": true]
        case "probe":
            guard frame.isMainFrame else { return nil }
            startEngine(in: webView, frame: frame, reason: (body["reason"] as? String) ?? "page")
            return nil
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
            unhide(in: webView, frame: frame)
            let succeeded = body["result"] as? Bool ?? false
            Signposts.signposter.emitEvent(Signposts.cookieBannerAnswered, "\(succeeded ? "rejected" : "failed")")
            if succeeded { noteAnswer(on: webView.url, in: webView) }
            onAnswered?(webView, succeeded)
            return nil
        case "autoconsentDone", "autoconsentError":
            unhide(in: webView, frame: frame)
            guard type == "autoconsentDone" else { return nil }
            // A cosmetic rule only hid the banner; an opt-out already reported through optOutResult.
            if body["isCosmetic"] as? Bool == true { onAnswered?(webView, true) }
            return nil
        case "report":
            // The engine found no consent manager after all: its banner, if any, shows as made.
            if (body["state"] as? [String: Any])?["lifecycle"] as? String == "nothingDetected" {
                unhide(in: webView, frame: frame)
            }
            return nil
        default:
            return nil
        }
    }

    /// Takes the probe's early hiding off a main frame once the engine has answered there.
    private func unhide(in webView: WKWebView, frame: WKFrameInfo) {
        guard frame.isMainFrame else { return }
        webView.evaluateJavaScript("globalThis.__plainCookieUnhide && globalThis.__plainCookieUnhide(); 0", in: frame, in: Self.world) { _ in }
    }

    /// Puts the engine into the page's main frame, once the probe has seen a reason.
    private func startEngine(in webView: WKWebView, frame: WKFrameInfo, reason: String) {
        guard let resources else { return }
        Signposts.signposter.emitEvent(Signposts.cookieBannerEngine, "\(reason, privacy: .public)")
        onMessage?("engine", ["reason": reason])
        webView.evaluateJavaScript(resources.engine, in: frame, in: Self.world) { _ in }
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
        state.answers = state.answers.compactMapValues { times in
            let recent = times.filter { now - $0 < FixedChoices.cookieBannerLoopWindow }
            return recent.isEmpty ? nil : recent
        }
        var answers = state.answers[site] ?? []
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
///
/// A frame's address is checked against a host index, not against every pattern: almost every
/// pattern is `^https?://`, an optional subdomain group, a literal host and `/`
/// (`HostKeys.keys(for:)`), so only rules keyed by one of the address's host suffixes, plus the
/// few patterns the index can't read, run their regular expression. That is O(labels + k) per
/// frame instead of O(rules), and each pattern is compiled the first time it runs, so the ICU
/// programs of the ~880 sites the user never visits are never built (docs/research/perf-pass-3.md).
struct CookieBannerRules: Sendable {
    struct Specific: Sendable {
        let pattern: String
        let main: Bool
        let frame: Bool
        let json: String
    }

    let version: String
    /// The generic main-frame ruleset as JSON, sent as is.
    let generic: String
    let specific: [Specific]
    /// Rule indexes by the literal host they need (`deezer.com`): a matching address's host is that
    /// host or ends with `.` and it.
    private let byHost: [String: [Int]]
    /// Rules whose pattern the index can't read: checked for every address.
    private let unindexed: [Int]
    private let compiled: CompiledPatterns

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
        specific = file.specific.map { Specific(pattern: $0.p, main: $0.m, frame: $0.f, json: $0.r) }
        var byHost: [String: [Int]] = [:]
        var unindexed: [Int] = []
        for (index, rule) in specific.enumerated() {
            guard let keys = HostKeys.keys(for: rule.pattern) else {
                unindexed.append(index)
                continue
            }
            for key in keys { byHost[key, default: []].append(index) }
        }
        self.byHost = byHost
        self.unindexed = unindexed
        compiled = CompiledPatterns(count: specific.count)
    }

    /// The rulesets whose pattern matches `url` and that run in this kind of frame, in file order.
    func specificRules(for url: String, mainFrame: Bool) -> [String] {
        // ICU's `$` also matches before a final line break, which the host suffixes don't model:
        // such an address (never a real page's) takes the full check.
        if url.contains(where: \.isNewline) { return scannedRules(for: url, mainFrame: mainFrame) }
        var candidates = Set(unindexed)
        for suffix in HostKeys.hostSuffixes(of: url) {
            if let rules = byHost[String(suffix)] { candidates.formUnion(rules) }
        }
        return matches(url, among: candidates.sorted(), mainFrame: mainFrame)
    }

    /// Every pattern against `url`, without the index: the reference `specificRules` must equal.
    func scannedRules(for url: String, mainFrame: Bool) -> [String] {
        matches(url, among: Array(specific.indices), mainFrame: mainFrame)
    }

    /// How many patterns the index reads (the rest are checked for every address), for the tests.
    var indexedCount: Int { specific.count - unindexed.count }

    private func matches(_ url: String, among indexes: [Int], mainFrame: Bool) -> [String] {
        let range = NSRange(url.startIndex..., in: url)
        return indexes.compactMap { index in
            let rule = specific[index]
            guard mainFrame ? rule.main : rule.frame,
                  let regex = compiled.regex(index, pattern: rule.pattern),
                  regex.firstMatch(in: url, range: range) != nil
            else { return nil }
            return rule.json
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

/// Each rule's ICU program, built the first time an address reaches its pattern. autoconsent's
/// patterns are JavaScript regular expressions; the few ICU can't read never match (their sites
/// get the generic rules and the cosmetic list), as when they were skipped at load.
///
/// `@unchecked Sendable`: every access to the arrays is under the lock. `NSRegularExpression` is
/// immutable and documented thread-safe, so a built one is used outside it.
private final class CompiledPatterns: @unchecked Sendable {
    private let lock = NSLock()
    private var regexes: [NSRegularExpression?]
    private var tried: [Bool]

    init(count: Int) {
        regexes = Array(repeating: nil, count: count)
        tried = Array(repeating: false, count: count)
    }

    func regex(_ index: Int, pattern: String) -> NSRegularExpression? {
        lock.withLock {
            if !tried[index] {
                tried[index] = true
                regexes[index] = try? NSRegularExpression(pattern: pattern)
            }
            return regexes[index]
        }
    }
}

/// The literal hosts a cookie banner rule's pattern needs, for `CookieBannerRules`' index.
///
/// A pattern is indexed only in this shape: a scheme (`^https?://`, `^https://`, `^http://`), at
/// most one optional subdomain group from `subdomainGroups`, then a host made of literal
/// characters, `\.` and groups of literal alternatives (`(nfl|49ers)`), then `/`, `(/|$)` or `$`,
/// not quantified; no inline flags or lookarounds anywhere (`(?i)` would reach other alternatives).
/// Each subdomain group matches nothing or a run that ends in `.` and holds no `/`, and the host
/// holds no `/` either, so in an address the pattern matches, the text from `://` to the first `/`
/// is that run and one spelling of the host: the host is that text or a suffix of it after a
/// `.`. `hostSuffixes(of:)` lists exactly those suffixes, so looking each one up finds every rule
/// that can match, and the rule's own pattern still decides. Anything else is not indexed and is
/// checked against every address.
enum HostKeys {
    static let schemes = ["^https?://", "^https://", "^http://"]
    /// The optional subdomain groups in autoconsent's rules, with their quantifiers.
    static let subdomainGroups: [String] = [
        "(www\\.)?", "(?:www\\.)?", "(www\\.|)?", "(www\\.|m\\.)?",
        "(\\w+\\.)?", "(\\w+\\.)*", "(\\w+\\.)+",
        "([\\w-]+\\.)?", "([\\w-]+\\.)*",
        "([a-z0-9-]+\\.)?", "(?:[a-z0-9-]+\\.)?", "([a-z0-9-]+\\.)*",
        "([a-z]*\\.)?", "([a-z]+\\.)?", "([a-z0-9.-]*\\.)?", "([.a-zA-Z0-9-]+\\.)?",
        "(?:[^/]+\\.)?",
    ]
    /// A host with more spellings than this is left to the full check.
    static let maxKeys = 64

    /// The host's spellings (`["deezer.com"]`), or nil when the pattern is not in the indexed shape.
    /// A pattern that is several alternatives at its top level (`^…\.de/|^…\.fr/`) is indexed only
    /// when every one is, under all of their hosts.
    static func keys(for pattern: String) -> [String]? {
        guard !hasSpecialGroups(pattern) else { return nil }
        let alternatives = topLevelAlternatives(of: pattern)
        var keys: [String] = []
        for alternative in alternatives {
            guard let some = branchKeys(alternative) else { return nil }
            keys += some
        }
        return keys
    }

    /// `pattern` split at each `|` outside parentheses and character classes.
    static func topLevelAlternatives(of pattern: String) -> [Substring] {
        var alternatives: [Substring] = []
        var depth = 0, inClass = false, escaped = false
        var start = pattern.startIndex
        for index in pattern.indices {
            let c = pattern[index]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if inClass {
                inClass = c != "]"
            } else if c == "[" {
                inClass = true
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
            } else if c == "|", depth == 0 {
                alternatives.append(pattern[start..<index])
                start = pattern.index(after: index)
            }
        }
        return alternatives + [pattern[start...]]
    }

    private static func branchKeys(_ pattern: Substring) -> [String]? {
        var rest = pattern
        guard let scheme = schemes.first(where: { rest.hasPrefix($0) }) else { return nil }
        rest = rest.dropFirst(scheme.count)
        if let group = subdomainGroups.first(where: { rest.hasPrefix($0) }) { rest = rest.dropFirst(group.count) }
        var keys = [""]
        while !isHostEnd(rest) {
            if rest.hasPrefix("\\.") {
                keys = keys.map { $0 + "." }
                rest = rest.dropFirst(2)
            } else if let c = rest.first, isHostCharacter(c) {
                keys = keys.map { $0 + String(c) }
                rest = rest.dropFirst()
            } else if rest.first == "(" {
                var body = rest.dropFirst()
                if body.hasPrefix("?:") { body = body.dropFirst(2) }
                guard let close = body.firstIndex(of: ")") else { return nil }
                let after = body[body.index(after: close)...]
                // A quantified group is optional or repeated: not a literal part of the host.
                if let next = after.first, "?*+{".contains(next) { return nil }
                var spellings: [String] = []
                for alternative in body[..<close].split(separator: "|", omittingEmptySubsequences: false) {
                    guard let literal = literal(alternative), !literal.isEmpty else { return nil }
                    spellings.append(literal)
                }
                keys = keys.flatMap { key in spellings.map { key + $0 } }
                guard keys.count <= maxKeys else { return nil }
                rest = after
            } else {
                return nil
            }
        }
        // The host must end there for certain: a `/` or `(/|$)` that is itself optional or repeated
        // (`\.com/?`) lets the host go on (`example.com.evil/`).
        let terminator = rest.hasPrefix("(/|$)") ? rest.dropFirst(5) : rest.dropFirst()
        if let next = terminator.first, "?*+{".contains(next) { return nil }
        guard keys.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".") }) else { return nil }
        return keys
    }

    /// Whether `pattern` has a group that is not a plain `(…)` or `(?:…)`: inline flags (`(?i)`,
    /// which also reach later alternatives), lookarounds, named groups. Such a pattern is not indexed.
    static func hasSpecialGroups(_ pattern: String) -> Bool {
        var rest = Substring(pattern)
        while let open = rest.range(of: "(?") {
            rest = rest[open.upperBound...]
            if rest.first != ":" { return true }
        }
        return false
    }

    /// The text from `://` to the first `/` (or the end), and each of its suffixes after a `.`.
    static func hostSuffixes(of url: String) -> [Substring] {
        let utf8 = url.utf8
        guard let scheme = url.range(of: "://") else { return [] }
        let start = scheme.upperBound
        let end = utf8[start...].firstIndex(of: UInt8(ascii: "/")) ?? url.endIndex
        var suffixes = [url[start..<end]]
        var index = start
        while let dot = utf8[index..<end].firstIndex(of: UInt8(ascii: ".")) {
            index = utf8.index(after: dot)
            suffixes.append(url[index..<end])
        }
        return suffixes
    }

    private static func isHostEnd(_ rest: Substring) -> Bool {
        rest.first == "/" || rest == "$" || rest.hasPrefix("(/|$)")
    }

    private static func isHostCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-")
    }

    /// `alternative` as plain text (`\.` read as `.`), or nil when it holds anything else.
    private static func literal(_ alternative: Substring) -> String? {
        var text = ""
        var rest = alternative
        while let c = rest.first {
            if rest.hasPrefix("\\.") {
                text += "."
                rest = rest.dropFirst(2)
            } else if isHostCharacter(c) {
                text.append(c)
                rest = rest.dropFirst()
            } else {
                return nil
            }
        }
        return text
    }
}
