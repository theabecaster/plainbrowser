// The reader page: template, escaping, and loading from the plain-reader scheme. Screenshots
// are written when READER_SHOTS_DIR is set (pass it to xcodebuild as TEST_RUNNER_READER_SHOTS_DIR).
#if os(iOS)
import Foundation
@testable import Reader
import Testing
import WebKit

@MainActor
@Suite(.serialized) struct ReaderRendererTests {
    let server = FixtureServer()
    let waiter = LoadWaiter()

    @Test func escapesTextAndKeepsContent() async throws {
        let article = ReaderArticle(
            title: "Fish & <Chips> {{content}}",
            byline: "  By\n   Ana \"A\" Ruiz ",
            siteName: "The <Site>",
            contentHTML: "<p>Body {{title}}</p>",
            textLength: 9,
            lang: "en\" onload=\"x",
            dir: "RTL",
            url: URL(string: "https://www.example.com/a")
        )
        let page = try await ReaderRenderer().page(for: article)
        #expect(page.contains("<h1>Fish &amp; &lt;Chips&gt; {{content}}</h1>"))
        #expect(page.contains(#"<span class="site">The &lt;Site&gt;</span> · By Ana &quot;A&quot; Ruiz"#))
        #expect(page.contains("<p>Body {{title}}</p>"))
        #expect(page.contains(#"<html lang="" dir="rtl">"#))
        #expect(page.contains("Content-Security-Policy"))
    }

    @Test func fallsBackToTheHostAndDropsADuplicateByline() async throws {
        let article = ReaderArticle(
            title: "T", byline: "example.com", contentHTML: "<p>x</p>", textLength: 1,
            url: URL(string: "https://www.example.com/a"))
        let page = try await ReaderRenderer().page(for: article)
        #expect(page.contains(#"<p class="meta"><span class="site">example.com</span></p>"#))
    }

    /// The page and its stylesheet load from the scheme handler, with page JavaScript off.
    @Test func loadsFromTheSchemeWithoutTheNetwork() async throws {
        let article = try #require(try await extract("v8-blog"))
        let (webView, handler) = readerWebView(width: 402, height: 874)

        let clock = ContinuousClock()
        let start = clock.now
        try await waiter.run(in: webView) { try await handler.show(article, in: webView) }
        let first = milliseconds(clock.now - start)
        let again = clock.now
        try await waiter.run(in: webView) { try await handler.show(article, in: webView) }
        print("reader.show v8-blog: first (new web content process) \(format(first)), "
            + "next \(format(milliseconds(clock.now - again)))")

        #expect(webView.url?.scheme == ReaderRenderer.scheme)
        let checks = try await webView.evaluateJavaScript("""
            [document.title,
             getComputedStyle(document.querySelector('article')).maxWidth,
             document.querySelectorAll('pre').length,
             document.styleSheets.length]
            """) as? [Any] ?? []
        #expect(checks.first as? String == article.title)
        #expect((checks[1] as? String)?.hasSuffix("px") == true, "stylesheet applied: \(checks)")
        #expect((checks[2] as? Int ?? 0) > 0)
        #expect(checks[3] as? Int == 1)
        #expect(!webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)

        // The paper tile comes from the scheme too, at 320 px, and sits under the page.
        let paper = try await webView.callAsyncJavaScript("""
            const image = new Image();
            image.src = 'plain-reader://reader/paper-day.png';
            await image.decode();
            return [image.naturalWidth, getComputedStyle(document.documentElement).backgroundImage];
            """, contentWorld: .page) as? [Any] ?? []
        #expect(paper.first as? Int == 320, "paper tile: \(paper)")
        #expect((paper.last as? String)?.contains("paper-") == true, "paper under the page: \(paper)")
    }

    /// A cancelled show loads nothing; the next one loads.
    @Test func cancelledShowLoadsNothing() async throws {
        let (webView, handler) = readerWebView(width: 402, height: 874)
        let older = ReaderArticle(title: "Older", contentHTML: "<p>old</p>", textLength: 3)
        let newer = ReaderArticle(title: "Newer", contentHTML: "<p>new</p>", textLength: 3)
        let cancelled = Task { try await handler.show(older, in: webView) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(webView.url == nil)

        try await waiter.run(in: webView) { try await handler.show(newer, in: webView) }
        #expect(try await webView.evaluateJavaScript("document.title") as? String == "Newer")
    }

    @Test func cspBlocksBaseFormsAndScripts() {
        let csp = ReaderRenderer.contentSecurityPolicy
        for directive in ["default-src 'none'", "base-uri 'none'", "form-action 'none'"] {
            #expect(csp.contains(directive))
        }
        #expect(!csp.contains("script-src"))
        #expect(ReaderRenderer.isReaderURL(URL(string: "plain-reader://article/x")))
        #expect(!ReaderRenderer.isReaderURL(URL(string: "https://example.com")))
    }

    /// Writes rendered reader pages and the stylesheet to READER_SHOTS_DIR, for screenshots in
    /// a simulator browser: a test bundle has no window server, so it cannot snapshot a web view.
    @Test func writesPagesForScreenshots() async throws {
        guard let folder = ProcessInfo.processInfo.environment["READER_SHOTS_DIR"] else { return }
        let base = URL(fileURLWithPath: folder)
        try await ReaderResources.stylesheet().write(to: base.appending(path: "reader.css"))
        try await ReaderResources.paperTile(.day).write(to: base.appending(path: "paper-day.png"))
        try await ReaderResources.paperTile(.night).write(to: base.appending(path: "paper-night.png"))
        for name in ["ars-1", "v8-blog", "dropbox-blog", "wikipedia"] {
            let article = try #require(try await extract(name))
            let page = try await ReaderRenderer().page(for: article)
                .replacingOccurrences(of: "\(ReaderRenderer.scheme)://reader/reader.css", with: "reader.css")
                .replacingOccurrences(of: "style-src \(ReaderRenderer.scheme):", with: "style-src 'self'")
                .replacingOccurrences(of: "img-src \(ReaderRenderer.scheme):", with: "img-src 'self'")
            try Data(page.utf8).write(to: base.appending(path: "\(name).html"))
        }
    }

    private func extract(_ name: String) async throws -> ReaderArticle? {
        let webView = try await server.makeWebView()
        try await waiter.load(URLRequest(url: FixtureServer.url(name)), in: webView)
        return try await ReaderExtractor().article(in: webView)
    }

    private func readerWebView(width: CGFloat, height: CGFloat) -> (WKWebView, ReaderSchemeHandler) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let handler = ReaderSchemeHandler.install(in: configuration)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        return (webView, handler)
    }
}
#endif
