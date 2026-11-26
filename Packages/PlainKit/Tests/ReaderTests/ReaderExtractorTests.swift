// Readability extraction on saved pages. WebKit, so these run on an iOS simulator only
// (`xcodebuild test -scheme PlainKit-Package -destination ... -only-testing:ReaderTests`).
#if os(iOS)
import Foundation
@testable import Reader
import Testing
import WebKit

@MainActor
@Suite(.serialized) struct ReaderExtractorTests {
    let server = FixtureServer()
    let waiter = LoadWaiter()

    private func load(_ name: String) async throws -> WKWebView {
        let webView = try await server.makeWebView()
        try await waiter.load(URLRequest(url: FixtureServer.url(name)), in: webView)
        return webView
    }

    @Test(arguments: FixtureServer.articles)
    func extractsArticles(_ name: String) async throws {
        let webView = try await load(name)
        let extractor = ReaderExtractor()

        let clock = ContinuousClock()
        let start = clock.now
        let article = try #require(try await extractor.article(in: webView))
        let cold = milliseconds(clock.now - start)

        let expected = try FixtureServer.expected(name)
        #expect(article.title == expected.title)
        if let byline = expected.byline {
            #expect(ReaderRenderer.clean(article.byline) == ReaderRenderer.clean(byline))
        }
        #expect(article.textLength > 1_000)
        #expect(article.contentHTML.contains("<p"))
        #expect(!article.contentHTML.contains("<script"))
        #expect(article.url == FixtureServer.url(name))

        // A second document, same extractor: Readability is installed again in the new page.
        let again = try await load(name)
        let warmStart = clock.now
        let second = try await extractor.article(in: again)
        let warm = milliseconds(clock.now - warmStart)
        #expect(second == article.with(url: again.url))

        let elements = try await webView.evaluateJavaScript("document.getElementsByTagName('*').length") as? Int ?? 0
        print("reader.extract \(name): first \(format(cold)), next page \(format(warm)), "
            + "\(elements) elements, \(article.textLength) chars")
    }

    @Test func returnsNilOnANonArticlePage() async throws {
        let webView = try await load(FixtureServer.nonArticle)
        let extractor = ReaderExtractor()
        let clock = ContinuousClock()
        let start = clock.now
        let article = try await extractor.article(in: webView)
        print("reader.extract \(FixtureServer.nonArticle): nil in \(format(milliseconds(clock.now - start)))")
        #expect(article == nil)
    }

    /// Only the small readerable check runs at document end; full Readability waits for a request.
    @Test(arguments: FixtureServer.articles + [FixtureServer.nonArticle])
    func reportsAvailabilityWithoutFullReadability(_ name: String) async throws {
        let extractor = ReaderExtractor()
        var reports: [Bool] = []
        extractor.onAvailability = { _, available in reports.append(available) }
        let webView = try await server.makeWebView(extractor: extractor)
        try await waiter.load(URLRequest(url: FixtureServer.url(name)), in: webView)
        // The report is a script message; it can land just after didFinish.
        for _ in 0..<100 where reports.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(reports == [name != FixtureServer.nonArticle])
        #expect(extractor.isAvailable(in: webView) == (name != FixtureServer.nonArticle))
        let world = WKContentWorld.world(name: ReaderWorld.contentWorldName)
        let types = try await webView.evaluateJavaScript(
            "typeof isProbablyReaderable + ' ' + typeof Readability", in: nil, contentWorld: world) as? String
        #expect(types == "function undefined")

        guard name != FixtureServer.nonArticle else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let article = try await extractor.article(in: webView)
        let first = milliseconds(clock.now - start)
        let again = clock.now
        let kept = try await extractor.article(in: webView)
        let keptMs = milliseconds(clock.now - again)
        print("reader.extract \(name) on open: \(format(first)), kept \(format(keptMs))")
        #expect(article != nil)
        #expect(kept == article)
        #expect(keptMs < 5)
    }

    /// Readability is not a sanitizer: active markup is stripped before the article leaves the page.
    @Test func stripsActiveMarkup() async throws {
        let webView = try await load("hostile")
        let article = try #require(try await ReaderExtractor().article(in: webView))
        let html = article.contentHTML.lowercased()
        for banned in ["<meta", "<base", "<iframe", "<object", "<embed", "<form", "<input", "<button",
                       "<animate", "<foreignobject", "onerror", "style=", "javascript:", "formaction"] {
            #expect(!html.contains(banned), "\(banned) survived")
        }
        #expect(html.contains("https://example.com/ok"))
        #expect(html.contains("data:image/png"))
        #expect(html.contains("after the trap"))
    }

    /// A reload of the same URL is a new document, so the kept article is dropped.
    @Test func reloadDropsTheKeptArticle() async throws {
        let extractor = ReaderExtractor()
        var reports = 0
        extractor.onAvailability = { _, _ in reports += 1 }
        let webView = try await server.makeWebView(extractor: extractor)
        try await waiter.load(URLRequest(url: FixtureServer.url("v8-blog")), in: webView)
        for _ in 0..<100 where reports == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let first = try #require(try await extractor.article(in: webView))

        // Change the live page, then reload: the reload must parse the reloaded document.
        _ = try await webView.evaluateJavaScript("document.title = 'changed'; true")
        #expect(try await extractor.article(in: webView) == first)
        try await waiter.run(in: webView) { webView.reload() }
        for _ in 0..<100 where reports < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reports == 2)
        #expect(extractor.isAvailable(in: webView) == true)
        let types = try await webView.evaluateJavaScript(
            "typeof Readability", in: nil, contentWorld: .world(name: ReaderWorld.contentWorldName)) as? String
        #expect(types == "undefined", "a reload starts without full Readability")
        #expect(try await extractor.article(in: webView) == first)
    }

    /// Readability lives in the reader world: the page's own scripts cannot see it.
    @Test func runsOutsideThePageWorld() async throws {
        let webView = try await load("v8-blog")
        let extractor = ReaderExtractor()
        _ = try await extractor.article(in: webView)

        let inPage = try await webView.evaluateJavaScript(
            "typeof Readability + ' ' + typeof isProbablyReaderable") as? String
        #expect(inPage == "undefined undefined")
        let inReader = try await webView.evaluateJavaScript(
            "typeof Readability", in: nil, contentWorld: .world(name: ReaderWorld.contentWorldName)) as? String
        #expect(inReader == "function")
    }

    /// A page that redefines globals in its own world cannot break extraction.
    @Test func ignoresPageTampering() async throws {
        let webView = try await load("v8-blog")
        _ = try await webView.evaluateJavaScript(
            "window.Readability = function() { throw 1 }; window.isProbablyReaderable = () => false; true")
        let article = try await ReaderExtractor().article(in: webView)
        #expect(article != nil)
    }
}

extension ReaderArticle {
    func with(url: URL?) -> ReaderArticle {
        var copy = self
        copy.url = url
        return copy
    }
}
#endif
