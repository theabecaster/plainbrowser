import DesignSystem
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
    /// Paper tile requests still waiting for their tile; WebKit may stop one meanwhile.
    private var running: Set<ObjectIdentifier> = []
    /// The latest `show` per web view. An older call that finishes later never loads.
    private var latestShow: [ObjectIdentifier: UUID] = [:]

    public override init() {}

    /// Registers a new handler on `configuration` and turns page JavaScript off: the reader page
    /// needs none, and the article HTML came from another site.
    @discardableResult
    public static func install(in configuration: WKWebViewConfiguration) -> ReaderSchemeHandler {
        let handler = ReaderSchemeHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: ReaderRenderer.scheme)
        // Its own preferences object: a copied configuration shares `defaultWebpagePreferences`
        // with the one it was copied from, so changing it in place turned JavaScript off for
        // every page loaded after the reader opened once.
        let page = WKWebpagePreferences()
        page.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = page
        return handler
    }

    /// Renders `article` off the main thread, then loads it in `webView`. When a newer `show` for
    /// the same web view started meanwhile, or the task was cancelled, this one loads nothing and
    /// throws `CancellationError`.
    public func show(_ article: ReaderArticle, in webView: WKWebView) async throws {
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.readerShow)
        defer { signposter.endInterval(Signposts.readerShow, state) }

        let key = ObjectIdentifier(webView)
        let request = UUID()
        latestShow[key] = request

        async let html = renderer.pageData(for: article)
        async let css = ReaderResources.stylesheet()
        let (page, sheet) = try await (html, css)
        stylesheet = sheet
        guard latestShow[key] == request, !Task.isCancelled else { throw CancellationError() }
        latestShow[key] = nil

        let id = request.uuidString
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
        case ("reader", "/paper-day.png"), ("reader", "/paper-night.png"):
            // Made per request, off the main thread; answered unless WebKit stopped the task.
            let sheet: PaperTexture.Sheet = url.path() == "/paper-day.png" ? .day : .night
            let id = ObjectIdentifier(urlSchemeTask)
            running.insert(id)
            Task {
                let tile = try? await ReaderResources.paperTile(sheet)
                guard running.remove(id) != nil else { return }
                respond(to: urlSchemeTask, url: url, body: tile, type: "image/png")
            }
            return
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
        respond(to: urlSchemeTask, url: url, body: body, type: type)
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func respond(to urlSchemeTask: any WKURLSchemeTask, url: URL, body: Data?, type: String) {
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
}
