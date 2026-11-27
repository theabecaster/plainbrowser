#if canImport(UIKit)
@testable import BrowserCore
import Foundation
@testable import Intelligence
import Reader
import Testing
import WebEngine
import WebKit

/// Browse for Me's hidden views against saved pages from a local server: the results page's
/// organic links (a saved DuckDuckGo lite page), the challenge page, an article read with its
/// JavaScript off, and that nothing is left behind: no view, no cookie in the tabs' store.
@MainActor @Suite(.serialized) struct HiddenBrowsingTests {
    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    static let route: @Sendable (TestServer.Request) -> TestServer.Response = { request in
        switch request.path {
        case "/lite": .data(fixture("ddg-lite"), type: "text/html; charset=utf-8")
        case "/challenge": .data(fixture("challenge"), type: "text/html; charset=utf-8")
        case "/article":
            .data(fixture("article"), type: "text/html; charset=utf-8", headers: ["Set-Cookie": "session=abc; Path=/"])
        case "/file.pdf": .data(Data("%PDF-1.4".utf8), type: "application/pdf")
        case "/slow":
            {
                Thread.sleep(forTimeInterval: 3)
                return .html("<p>late</p>")
            }()
        default: .notFound
        }
    }

    let server: TestServer
    let pool: WebViewPool
    let tabsStore = WKWebsiteDataStore.nonPersistent()

    init() async throws {
        server = try await TestServer(route: Self.route)
        pool = WebViewPool(dataStore: tabsStore)
    }

    func litePage() -> BrowseForMe.ResultsPage {
        var page = BrowseForMe.resultsPages(for: "webkit performance", engine: .duckDuckGo)[0]
        page.url = server.url("/lite")
        return page
    }

    @Test func theLitePagesOrganicResultsInOrder() async throws {
        let browsing = HiddenBrowsing(pool: pool)
        let page = litePage()
        let links = try await browsing.links(on: page)
        #expect(pool.hiddenWebViewCount == 0)
        // Both sponsored rows are marked; the y.js link is an ad either way.
        #expect(links.filter(\.isAd).map(\.title) == ["Sponsored: Fast Shoes", "Shoes on sale"])
        let results = BrowseForMe.organicResults(links, engineHosts: page.engineHosts, limit: 20)
        #expect(results.count >= 5)
        #expect(results.first?.url.absoluteString == "https://webkit.org/performance/")
        #expect(results.first?.title == "Performance Testing - WebKit")
        #expect(!results.contains { $0.url.host() == "shoes.example" })
        // One page per site.
        #expect(Set(results.map { BrowseForMe.siteName($0.url) }).count == results.count)
    }

    @Test func aChallengePageIsNotResults() async throws {
        let browsing = HiddenBrowsing(pool: pool)
        var page = litePage()
        page.url = server.url("/challenge")
        await #expect(throws: BrowseReadError.blocked) { try await browsing.links(on: page) }
        #expect(pool.hiddenWebViewCount == 0)
    }

    @Test func anArticleIsReadWithItsScriptsOff() async throws {
        let browsing = HiddenBrowsing(pool: pool)
        let text = try #require(try await browsing.text(of: server.url("/article")))
        #expect(text.isArticle)
        #expect(text.title.contains("How tides work"))
        #expect(text.text.contains("Tides rise and fall twice a day"))
        #expect(text.text.contains("number 29"))
        #expect(!text.text.contains("Subscribe"))
        #expect(!text.text.contains("Copyright"))
        #expect(text.text.count >= FixedChoices.browseMinimumText)
        #expect(pool.hiddenWebViewCount == 0)
        // The page's cookie never reached the tabs' store.
        let cookies = await tabsStore.httpCookieStore.allCookies()
        #expect(cookies.isEmpty)
    }

    @Test func notAPageIsSkipped() async throws {
        let browsing = HiddenBrowsing(pool: pool)
        await #expect(throws: (any Error).self) { try await browsing.text(of: server.url("/file.pdf")) }
        #expect(pool.hiddenWebViewCount == 0)
    }

    @Test func cancellingAReadReturnsAtOnceAndReleasesTheView() async throws {
        let browsing = HiddenBrowsing(pool: pool)
        let url = server.url("/slow")
        let read = Task { try await browsing.text(of: url) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(pool.hiddenWebViewCount == 1)
        let clock = ContinuousClock()
        let start = clock.now
        read.cancel()
        _ = try? await read.value
        #expect(clock.now - start < .milliseconds(300))
        #expect(pool.hiddenWebViewCount == 0)
    }

    @Test func aWholeRunAgainstTheSavedPagesLeavesNothing() async throws {
        let browsing = HiddenBrowsing(pool: pool)
        let page = litePage()
        let links = try await browsing.links(on: page)
        // The saved results point at the real web; read the article fixture in their place.
        let results = BrowseForMe.organicResults(links, engineHosts: page.engineHosts)
        try #require(results.count >= 3)
        let texts = try await withThrowingTaskGroup(of: ReaderText?.self) { group in
            for _ in 0..<3 { group.addTask { @MainActor in try await browsing.text(of: server.url("/article")) } }
            var texts: [ReaderText?] = []
            for try await text in group { texts.append(text) }
            return texts
        }
        #expect(texts.compactMap { $0 }.count == 3)
        #expect(pool.hiddenWebViewCount == 0)
    }
}
#endif
