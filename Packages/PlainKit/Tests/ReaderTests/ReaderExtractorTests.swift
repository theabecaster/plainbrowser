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

        extractor.prefetch(in: webView)
        #expect(try await extractor.article(in: webView) == nil)
    }

    /// Prefetch at `didFinish` does the work ahead, so the request itself is near instant.
    @Test func prefetchMakesTheRequestCheap() async throws {
        let webView = try await load("ars-1")
        let extractor = ReaderExtractor()
        extractor.prefetch(in: webView)
        try await Task.sleep(for: .milliseconds(500))

        let clock = ContinuousClock()
        let start = clock.now
        let article = try await extractor.article(in: webView)
        let ms = milliseconds(clock.now - start)
        print("reader.extract ars-1 after prefetch: \(format(ms))")
        #expect(article != nil)
        #expect(ms < 5)
    }

    /// A page over the element limit skips the parse at prefetch, and the request still works.
    @Test func largePagesWaitForTheRequest() async throws {
        let webView = try await load("wikipedia")
        _ = try await webView.evaluateJavaScript("""
            const box = document.createElement('div');
            for (let i = 0; i < 5000; i++) box.appendChild(document.createElement('span'));
            document.body.appendChild(box); true
            """)
        let elements = try await webView.evaluateJavaScript("document.getElementsByTagName('*').length") as? Int ?? 0
        #expect(elements > ReaderExtractor.prefetchElementLimit)
        let extractor = ReaderExtractor()
        extractor.prefetch(in: webView)
        #expect(try await extractor.article(in: webView)?.title == "Mozilla - Wikipedia")
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
