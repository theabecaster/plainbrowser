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

    /// A long article with no banner, for the cost per page.
    static let article: String = {
        var body = ""
        for i in 0..<2_000 { body += "<p>Paragraph \(i) with <a href='#\(i)'>a link</a> and some words to wrap.</p>" }
        return "<!doctype html><html><head><meta charset='utf-8'><title>A</title></head><body>\(body)</body></html>"
    }()
}

@MainActor
@Suite(.serialized) struct CookieBannerPageTests {
    @Test func rejectsAOneTrustBanner() async throws {
        let page = await CookiePage(banners: CookieBanners())
        var answered: Bool?
        page.banners?.onAnswered = { _, result in answered = result }
        let start = ContinuousClock.now
        page.banners?.onMessage = { type, body in
            print("[plain-measure] cookie banner message \(type) \(body["cmp"] ?? "") at \(ContinuousClock.now - start)")
        }
        await page.load(CookiePage.oneTrust)
        let deadline = ContinuousClock.now + .seconds(15)
        while await page.value("document.body.dataset.consent") == "none", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        print("[plain-measure] cookie banner rejected after \(ContinuousClock.now - start)")
        #expect(await page.value("document.body.dataset.consent") == "rejected")
        #expect(await page.value("getComputedStyle(document.getElementById('onetrust-banner-sdk')).display") == "none")
        try await Task.sleep(for: .milliseconds(200))
        #expect(answered == true)
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

    /// What the engine adds to a page without a banner: load time of a long article, with and
    /// without it (median of 5 each).
    @Test func costPerPage() async throws {
        func median(_ banners: CookieBanners?) async -> Duration {
            var samples: [Duration] = []
            let page = await CookiePage(banners: banners)
            for _ in 0..<5 {
                let start = ContinuousClock.now
                await page.load(CookiePage.article, site: "news.example")
                samples.append(ContinuousClock.now - start)
            }
            return samples.sorted()[2]
        }
        let off = await median(nil)
        let on = await median(CookieBanners())
        print("[plain-measure] long article load, without the engine \(off), with it \(on)")
    }
}
#endif
