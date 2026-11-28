// Cookie banner handling (DuckDuckGo autoconsent in Plain's content world). The page tests need
// WebKit with a window, so they run on an iOS simulator only; the rule split runs everywhere.
@testable import ContentBlocking
import Foundation
import Testing
import WebKit
#if os(iOS)
import UIKit
#endif

@Suite struct CookieBannerRulesTests {
    static func rules() throws -> CookieBannerRules {
        let directory = try #require(CookieBanners.bundledDirectory)
        return try CookieBannerRules(data: Data(contentsOf: directory.appending(path: "rules.json")))
    }

    @Test func splitsGenericAndSiteRules() throws {
        let rules = try Self.rules()
        #expect(!rules.generic.isEmpty)
        // Every pattern but a handful is plain ICU.
        #expect(rules.specific.count > 850)
        // A site rule reaches its site's main frame only.
        let acetool = rules.specificRules(for: "https://www.acetool.com/products", mainFrame: true)
        #expect(acetool.count == 1)
        #expect(rules.specificRules(for: "https://unrelated.example/", mainFrame: true).isEmpty)
    }

    @Test func onlyTargetedFramesGetTheEngine() throws {
        let rules = try Self.rules()
        #expect(rules.subframeNeedsEngine("https://cdn.privacy-mgmt.com/index.html?message_id=123&consentUUID=x"))
        #expect(rules.subframeNeedsEngine("https://cf.clym-widget.net/latest/frame.html"))
        #expect(!rules.subframeNeedsEngine("https://ads.example/frame.html"))
        #expect(!rules.subframeNeedsEngine("https://www.youtube.com/embed/abc"))
    }

    @Test func matchingAPageIsCheap() throws {
        let rules = try Self.rules()
        let clock = ContinuousClock()
        let urls = (0..<50).map { "https://news\($0).example/article/\($0)?ref=home" }
        let elapsed = clock.measure {
            for url in urls { _ = rules.specificRules(for: url, mainFrame: true) }
        }
        print("[plain-measure] cookie banner rule match per main frame: \(elapsed / urls.count)")
        #expect(elapsed / urls.count < .milliseconds(20))
    }

    /// Addresses near every rule's host: on it, on subdomains, on hosts that only end with its
    /// text, on hosts that go on past it, with ports, credentials, queries and both schemes.
    static func probeAddresses(_ rules: CookieBannerRules) -> [String] {
        var hosts: Set<String> = ["unrelated.example", "localhost", "127.0.0.1"]
        for rule in rules.specific {
            for key in HostKeys.keys(for: rule.pattern) ?? [] {
                hosts.formUnion([key, "www.\(key)", "m.\(key)", "a.b.\(key)", "x\(key)", "\(key).evil", "user@\(key)", "u@x.\(key)"])
            }
            // Unindexed patterns: their literal runs, as hosts.
            let literal = rule.pattern.replacingOccurrences(of: "\\.", with: ".")
                .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
                .filter { $0.contains(".") }
            hosts.formUnion(literal.flatMap { ["\($0)", "www.\($0)", "q.\($0)"] })
        }
        var addresses: [String] = []
        for host in hosts.sorted() {
            for scheme in ["https://", "http://"] {
                addresses += [scheme + host + "/", scheme + host + "/path/page?q=1#f", scheme + host, scheme + host + ":8443/", scheme + host + "?x=/y"]
            }
        }
        return addresses + ["", "about:blank", "data:text/html,x", "https://", "https:///", "ftp://deezer.com/"]
    }

    /// The host index finds exactly what checking every pattern finds, for main frames and
    /// subframes, on addresses around every rule.
    @Test func hostIndexMatchesTheFullCheck() throws {
        let rules = try Self.rules()
        // The index reads almost every pattern; the rest are checked for every address.
        #expect(rules.indexedCount > 830)
        var checked = 0
        var matched = 0
        for address in Self.probeAddresses(rules) {
            for main in [true, false] {
                let indexed = rules.specificRules(for: address, mainFrame: main)
                #expect(indexed == rules.scannedRules(for: address, mainFrame: main), "\(address) main \(main)")
                checked += 1
                if !indexed.isEmpty { matched += 1 }
            }
        }
        print("[plain-measure] cookie banner index: \(rules.indexedCount)/\(rules.specific.count) patterns indexed, \(checked) checks, \(matched) with rules")
        #expect(matched > 1_000)
    }

    @Test func hostKeysReadOnlyTheProvableShape() {
        #expect(HostKeys.keys(for: "^https?://(www\\.)?deezer\\.com/") == ["deezer.com"])
        #expect(HostKeys.keys(for: "^https://(m|mbasic)\\.facebook\\.com/") == ["m.facebook.com", "mbasic.facebook.com"])
        #expect(HostKeys.keys(for: "^https?://(\\w+\\.)?(fellow|fll)\\.pl/") == ["fellow.pl", "fll.pl"])
        #expect(HostKeys.keys(for: "^https?://(www\\.)?lt\\.example(/|$)") == ["lt.example"])
        // Alternatives at the top level: every one indexed, or none.
        #expect(HostKeys.keys(for: "^https?://(www\\.)?galaxus\\.de/|^https?://(www\\.)?galaxus\\.fr/") == ["galaxus.de", "galaxus.fr"])
        #expect(HostKeys.keys(for: "^https?://a\\.example/|^https://[a-z]*\\.b\\.example/") == nil)
        // A terminator that is optional lets the host go on; an inline flag reaches the next
        // alternative (both confirmed against ICU in review).
        #expect(HostKeys.keys(for: "^https://example\\.com/?") == nil)
        #expect(HostKeys.keys(for: "^https://a\\.com/(?i)|^https://b\\.com/") == nil)
        #expect(HostKeys.keys(for: "^https?://(www\\.)?x\\.example(/|$)?") == nil)
        // Not provable: an unescaped dot, a host that may go on, a quantified or repeated part,
        // a character class in the host, a subdomain group not in the list.
        #expect(HostKeys.keys(for: "^https://(www\\.)?(m\\.)?imdb.com/") == nil)
        #expect(HostKeys.keys(for: "^https?://(www\\.)?deezer\\.com") == nil)
        #expect(HostKeys.keys(for: "^https://(\\w+\\.)?xhamster\\d*\\.com/") == nil)
        #expect(HostKeys.keys(for: "^https://[a-z]*\\.pinterest\\.com/") == nil)
        #expect(HostKeys.keys(for: "^https://(?!www\\.)[\\w-]+\\.mercado(libre|livre|pago)\\.[a-z.]+/") == nil)
        #expect(HostKeys.hostSuffixes(of: "https://a.b.deezer.com:443/x.y") == ["a.b.deezer.com:443", "b.deezer.com:443", "deezer.com:443", "com:443"])
        #expect(HostKeys.hostSuffixes(of: "no scheme").isEmpty)
    }

    /// Time per main frame against the number of rules, with and without the index: the full check
    /// grows with the rules, the index with the address's labels and its few candidates. The rules
    /// are the bundled ones plus `n - 1` copies of the indexed ones, each copy on a host of its own
    /// (`site<copy>x<rule>.example`), so the copies add sites, never candidates for the addresses
    /// measured; the 35 the index can't read stay 35, as they would with more sites in the file.
    @Test func ruleMatchScalesWithTheAddressNotTheRules() throws {
        let directory = try #require(CookieBanners.bundledDirectory)
        let data = try Data(contentsOf: directory.appending(path: "rules.json"))
        let file = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let specific = try #require(file["specific"] as? [[String: Any]])
        let urls = (0..<40).map { "https://news\($0).example/article/\($0)?ref=home" }
            + ["https://www.deezer.com/en/", "https://www.acetool.com/products", "https://a.b.bcferries.com/x"]
        var lines: [String] = []
        for copies in [1, 4, 16] {
            var entries: [[String: Any]] = []
            for copy in 0..<copies {
                for (index, entry) in specific.enumerated() {
                    guard copy > 0 else { entries.append(entry); continue }
                    guard HostKeys.keys(for: entry["p"] as? String ?? "") != nil else { continue }
                    var renamed = entry
                    renamed["p"] = "^https?://(www\\.)?site\(copy)x\(index)\\.example/"
                    entries.append(renamed)
                }
            }
            var scaled = file
            scaled["specific"] = entries
            let rules = try CookieBannerRules(data: JSONSerialization.data(withJSONObject: scaled))
            // Warm: each pattern compiled once by the full check, so both sides time matching only.
            for url in urls { _ = rules.scannedRules(for: url, mainFrame: true) }
            let clock = ContinuousClock()
            let rounds = 5
            let indexed = clock.measure { for _ in 0..<rounds { for url in urls { _ = rules.specificRules(for: url, mainFrame: true) } } }
            let scanned = clock.measure { for _ in 0..<rounds { for url in urls { _ = rules.scannedRules(for: url, mainFrame: true) } } }
            let per = Double(rounds * urls.count)
            func us(_ d: Duration) -> String { String(format: "%.1f µs", (Double(d.components.attoseconds) / 1e12 + Double(d.components.seconds) * 1e6) / per) }
            lines.append("rules \(rules.specific.count): indexed \(us(indexed)), full check \(us(scanned)) per frame")
            for url in urls { #expect(rules.specificRules(for: url, mainFrame: true) == rules.scannedRules(for: url, mainFrame: true)) }
        }
        print("[plain-measure] cookie banner match vs rules:\n  " + lines.joined(separator: "\n  "))
    }
}

#if os(iOS)
/// A page in a window (the engine checks visibility, which needs layout), loaded from an HTML
/// string with an https base address, so no server is needed.
@MainActor
final class CookiePage: NSObject, WKNavigationDelegate {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let webView: WKWebView
    let banners: CookieBanners?
    private var finished: CheckedContinuation<Void, Never>?

    /// - Parameter banners: nil for a web view without the engine.
    init(banners: CookieBanners?) async {
        self.banners = banners
        await banners?.prepare()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        banners?.install(in: controller)
        configuration.userContentController = controller
        webView = WKWebView(frame: window.bounds, configuration: configuration)
        super.init()
        window.addSubview(webView)
        window.isHidden = false
        webView.navigationDelegate = self
    }

    func load(_ html: String, site: String = "shop.example") async {
        await withCheckedContinuation { continuation in
            finished = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://\(site)/"))
        }
    }

    func value(_ script: String) async -> String? {
        try? await webView.evaluateJavaScript(script) as? String
    }

    func number(_ script: String) async -> Double {
        ((try? await webView.evaluateJavaScript(script)) as? NSNumber)?.doubleValue ?? -1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished?.resume()
        finished = nil
    }

    /// A OneTrust banner as the SDK renders it: Reject All records "rejected", Accept All
    /// "accepted"; either removes the banner.
    static let oneTrust = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>Shop</title></head>
        <body data-consent="none"><h1>Shop</h1><p>Products</p>
        <div id="onetrust-consent-sdk"><div id="onetrust-banner-sdk" style="position:fixed;bottom:0;left:0;right:0;
          padding:20px;background:#fff;border-top:1px solid #ccc">
          <p>We use cookies to improve your experience.</p>
          <button id="onetrust-accept-btn-handler">Accept All</button>
          <button id="onetrust-reject-all-handler">Reject All</button>
          <button id="onetrust-pc-btn-handler">Cookie Settings</button>
        </div></div>
        <script>
          const done = (answer) => { document.body.dataset.consent = answer;
            document.getElementById('onetrust-banner-sdk').style.display = 'none'; };
          document.getElementById('onetrust-reject-all-handler').onclick = () => done('rejected');
          document.getElementById('onetrust-accept-btn-handler').onclick = () => done('accepted');
        </script></body></html>
        """

    /// The OneTrust page with a sampler that counts the frames in which the banner shows before it
    /// is answered (`__visibleFrames`), from the first frame on.
    static let oneTrustSampled = oneTrust.replacingOccurrences(of: "</body>", with: """
        <script>
          window.__visibleFrames = 0; window.__frames = 0;
          (function tick() {
            const b = document.getElementById('onetrust-banner-sdk');
            const cs = b && getComputedStyle(b);
            if (cs && cs.display !== 'none' && parseFloat(cs.opacity) > 0.05 && document.body.dataset.consent === 'none') window.__visibleFrames++;
            window.__frames++;
            if (document.body.dataset.consent === 'none' && window.__frames < 600) requestAnimationFrame(tick);
          })();
        </script></body>
        """)

    /// A Cookiebot-style banner a script adds after the page loaded (as a hosted consent manager
    /// does once its script arrives): the probe's later look finds it.
    static let lateBanner = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>Late</title></head>
        <body data-consent="none"><h1>Late</h1><p>Products</p>
        <script>
          addEventListener('load', () => setTimeout(() => {
            document.body.insertAdjacentHTML('beforeend', `
              <div id="onetrust-consent-sdk"><div id="onetrust-banner-sdk" style="position:fixed;bottom:0;left:0;right:0;
                padding:20px;background:#fff">
                <p>We use cookies.</p>
                <button id="onetrust-accept-btn-handler">Accept All</button>
                <button id="onetrust-reject-all-handler">Reject All</button>
              </div></div>`);
            const done = (answer) => { document.body.dataset.consent = answer;
              document.getElementById('onetrust-banner-sdk').style.display = 'none'; };
            document.getElementById('onetrust-reject-all-handler').onclick = () => done('rejected');
            document.getElementById('onetrust-accept-btn-handler').onclick = () => done('accepted');
          }, 600));
        </script></body></html>
        """

    /// A long article with no banner, for the cost per page.
    static let article: String = {
        var body = ""
        for i in 0..<2_000 { body += "<p>Paragraph \(i) with <a href='#\(i)'>a link</a> and some words to wrap.</p>" }
        // The page's first script notes when it ran: what runs at document start delays it.
        return "<!doctype html><html><head><meta charset='utf-8'><title>A</title>"
            + "<script>window.firstScript = performance.now()</script></head><body>\(body)</body></html>"
    }()
}

@MainActor
@Suite(.serialized) struct CookieBannerPageTests {
    @Test func rejectsAOneTrustBanner() async throws {
        let page = await CookiePage(banners: CookieBanners())
        var answered: Bool?
        page.banners?.onAnswered = { _, result in answered = result }
        let start = ContinuousClock.now
        var detected: Duration?
        page.banners?.onMessage = { type, _ in
            if type == "init", detected == nil { detected = ContinuousClock.now - start }
        }
        await page.load(CookiePage.oneTrust)
        let loaded = ContinuousClock.now - start
        let deadline = ContinuousClock.now + .seconds(15)
        while await page.value("document.body.dataset.consent") == "none", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        print("[plain-measure] cookie banner: loaded after \(loaded), engine started after \(detected ?? .zero), rejected after \(ContinuousClock.now - start)")
        #expect(await page.value("document.body.dataset.consent") == "rejected")
        #expect(await page.value("getComputedStyle(document.getElementById('onetrust-banner-sdk')).display") == "none")
        try await Task.sleep(for: .milliseconds(200))
        #expect(answered == true)
    }

    /// A known consent manager's banner found by the probe (no site rule, so the engine comes only
    /// after DOMContentLoaded) is hidden from the first frame until it is answered: no flash.
    @Test func aLateEngineBannerNeverFlashes() async throws {
        let page = await CookiePage(banners: CookieBanners())
        let start = ContinuousClock.now
        await page.load(CookiePage.oneTrustSampled)
        let deadline = ContinuousClock.now + .seconds(15)
        while await page.value("document.body.dataset.consent") == "none", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let answered = ContinuousClock.now - start
        let visible = await page.number("window.__visibleFrames")
        let frames = await page.number("window.__frames")
        print("[plain-measure] cookie banner flash: visible in \(Int(visible)) of \(Int(frames)) frames before it was answered (\(answered))")
        #expect(await page.value("document.body.dataset.consent") == "rejected")
        #expect(visible == 0, "the banner showed in \(visible) frames")
    }

    /// A banner the engine can't answer (turned off for the site) shows at once, never hidden.
    @Test func aBannerLeftAloneIsNotHidden() async throws {
        let banners = CookieBanners()
        banners.setOff(true, for: URL(string: "https://shop.example/"), isPrivate: false)
        let page = await CookiePage(banners: banners)
        await page.load(CookiePage.oneTrustSampled)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await page.value("getComputedStyle(document.getElementById('onetrust-banner-sdk')).opacity") == "1")
    }

    /// A page with no sign of a consent manager never gets the engine: nothing to parse.
    @Test func aPageWithoutABannerNeverLoadsTheEngine() async throws {
        let page = await CookiePage(banners: CookieBanners())
        var messages: [String] = []
        page.banners?.onMessage = { type, _ in messages.append(type) }
        await page.load(CookiePage.article, site: "news.example")
        try await Task.sleep(for: .seconds(2))
        #expect(messages == ["page"], "only the probe's first word: \(messages)")
        #expect(await page.value("typeof globalThis.__plainCookieBanners") == "undefined", "no engine in the page")
    }

    /// A banner a script adds after load is still found and rejected.
    @Test func rejectsABannerAddedAfterLoad() async throws {
        let page = await CookiePage(banners: CookieBanners())
        var reasons: [String] = []
        page.banners?.onMessage = { type, body in
            if type == "engine", let reason = body["reason"] as? String { reasons.append(reason) }
        }
        await page.load(CookiePage.lateBanner)
        let deadline = ContinuousClock.now + .seconds(15)
        while await page.value("document.body.dataset.consent") == "none", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await page.value("document.body.dataset.consent") == "rejected")
        #expect(reasons == ["page"])
    }

    /// A site with a rule of its own gets the engine as the page starts, without waiting for a sign.
    @Test func aSiteRuleStartsTheEngineAtOnce() async throws {
        let page = await CookiePage(banners: CookieBanners())
        var reasons: [String] = []
        page.banners?.onMessage = { type, body in
            if type == "engine", let reason = body["reason"] as? String { reasons.append(reason) }
        }
        await page.load(CookiePage.article, site: "www.acetool.com")
        try await Task.sleep(for: .milliseconds(500))
        #expect(reasons == ["site rule"])
    }

    @Test func perSiteOffLeavesTheBanner() async throws {
        let store = InMemorySiteCookieBannersStore()
        let banners = CookieBanners(store: store)
        banners.setOff(true, for: URL(string: "https://shop.example/"), isPrivate: false)
        #expect(store.offSites == ["shop.example"])
        let page = await CookiePage(banners: banners)
        await page.load(CookiePage.oneTrust)
        try await Task.sleep(for: .seconds(3))
        #expect(await page.value("document.body.dataset.consent") == "none")
        #expect(await page.value("getComputedStyle(document.getElementById('onetrust-banner-sdk')).display") == "block")
    }

    @Test func privateChoicesStayInThePrivateSession() {
        let store = InMemorySiteCookieBannersStore()
        let banners = CookieBanners(store: store)
        let url = URL(string: "https://www.shop.example/a")
        let other = URL(string: "https://other.example/")
        banners.setOff(true, for: other, isPrivate: false)
        #expect(banners.isOff(for: other, isPrivate: true), "the first private tab reads the regular choices")
        banners.setOff(true, for: url, isPrivate: true)
        #expect(banners.isOff(for: url, isPrivate: true))
        #expect(!banners.isOff(for: url, isPrivate: false))
        #expect(store.offSites == ["other.example"])
        banners.endPrivateSession()
        #expect(!banners.isOff(for: url, isPrivate: true))
        banners.setOff(true, for: url, isPrivate: false)
        #expect(banners.isOff(for: url, isPrivate: true), "private tabs read the regular choice")
    }

    /// What cookie banner handling adds to a page without a banner, on a long article, with and
    /// without it:
    /// - back to back: five loads in a row in one web view, until `didFinish` (median), the way a
    ///   reader goes from page to page; work the engine leaves running delays the next load;
    /// - fresh: a new web view each time, as a new tab or a new site's process, where scripts are
    ///   parsed cold: when the page's own first script runs, in the page's clock (median of 9).
    @Test func costPerPage() async throws {
        let banners = CookieBanners()
        await banners.prepare()
        func median(_ samples: [Duration]) -> Duration { samples.sorted()[samples.count / 2] }
        func backToBack(_ banners: CookieBanners?) async -> Duration {
            let page = await CookiePage(banners: banners)
            var samples: [Duration] = []
            for _ in 0..<5 {
                let start = ContinuousClock.now
                await page.load(CookiePage.article, site: "news.example")
                samples.append(ContinuousClock.now - start)
            }
            return median(samples)
        }
        let off = await backToBack(nil)
        let on = await backToBack(banners)
        var freshOff: [Double] = []
        var freshOn: [Double] = []
        for _ in 0..<9 {
            for (handled, page) in [(false, await CookiePage(banners: nil)), (true, await CookiePage(banners: banners))] {
                await page.load(CookiePage.article, site: "news.example")
                let first = await page.number("window.firstScript")
                if handled { freshOn.append(first) } else { freshOff.append(first) }
            }
        }
        let first = { (samples: [Double]) in String(format: "%.0f ms", samples.sorted()[samples.count / 2]) }
        print("[plain-measure] long article back to back: without cookie banner handling \(off), with it \(on); "
            + "fresh web view, first script at \(first(freshOff)) without, \(first(freshOn)) with")
    }
}
#endif
