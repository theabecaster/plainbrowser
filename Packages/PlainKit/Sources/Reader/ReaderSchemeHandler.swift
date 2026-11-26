import Foundation
import os
import PerfSignposts
import WebKit

/// Serves the reader page and its stylesheet from the `plain-reader:` scheme, with no network.
///
/// Set it up on the reader web view's configuration with `install(in:)` before the pool creates
/// that web view, then call `show(_:in:)` with an article.
@MainActor public final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    /// How many rendered pages to keep, so back and forward in the reader view still load.
    private static let keptPages = 4

    private let renderer = ReaderRenderer()
    private var pages: [String: Data] = [:]
    private var pageOrder: [String] = []
    private var stylesheet: Data?

    public override init() {}

    /// Registers a new handler on `configuration` and turns page JavaScript off: the reader page
    /// needs none, and the article HTML came from another site.
    @discardableResult
    public static func install(in configuration: WKWebViewConfiguration) -> ReaderSchemeHandler {
        let handler = ReaderSchemeHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: ReaderRenderer.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return handler
    }

    /// Renders `article` off the main thread, then loads it in `webView`.
    public func show(_ article: ReaderArticle, in webView: WKWebView) async throws {
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.readerShow)
        defer { signposter.endInterval(Signposts.readerShow, state) }

        async let html = renderer.page(for: article)
        async let css = ReaderResources.stylesheet()
        let (page, sheet) = try await (Data(html.utf8), css)
        stylesheet = sheet

        let id = UUID().uuidString
        pages[id] = page
        pageOrder.append(id)
        while pageOrder.count > Self.keptPages { pages[pageOrder.removeFirst()] = nil }

        webView.load(URLRequest(url: URL(string: "\(ReaderRenderer.scheme)://article/\(id)")!))
    }

    // MARK: WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let body: Data?
        let type: String
        switch (url.host(), url.path()) {
        case ("reader", "/reader.css"):
            body = stylesheet
            type = "text/css; charset=utf-8"
        case ("article", let path):
            body = pages[String(path.dropFirst())]
            type = "text/html; charset=utf-8"
        default:
            body = nil
            type = ""
        }
        guard let body else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type,
            "Content-Length": String(body.count),
            "Content-Security-Policy": ReaderRenderer.contentSecurityPolicy,
        ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
