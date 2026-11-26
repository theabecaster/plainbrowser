#if os(iOS)
import Foundation
import Reader
import WebKit

/// Saved pages from Readability's own test suite (`Fixtures/<name>/source.html`), served offline
/// from the `plainfixture` scheme. Every http(s) load is blocked, so a run never touches the
/// network and timings measure only the page and the extraction.
@MainActor final class FixtureServer: NSObject, WKURLSchemeHandler {
    static let scheme = "plainfixture"

    /// Real articles with images, code blocks, bylines and a long Wikipedia page.
    nonisolated static let articles = ["ars-1", "dropbox-blog", "v8-blog", "wikipedia"]
    /// A portal home page: navigation, a search form and link lists. Not an article.
    nonisolated static let nonArticle = "portal"

    /// Serves another fixture's page at a name's URL, to change a page's content in place.
    var replacements: [String: String] = [:]

    static func url(_ name: String) -> URL {
        URL(string: "\(scheme)://\(name)/index.html")!
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let host = url.host(),
              case let name = replacements[host] ?? host,
              url.path() == "/index.html",
              let file = Bundle.module.url(forResource: "source", withExtension: "html", subdirectory: "Fixtures/\(name)"),
              let data = try? Data(contentsOf: file)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(URLResponse(
            url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    /// A web view that loads fixtures with the network blocked.
    func makeWebView(extractor: ReaderExtractor? = nil) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let extractor { try await extractor.install(in: configuration.userContentController) }
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(try await Self.offline())
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), configuration: configuration)
    }

    private static var offlineList: WKContentRuleList?

    /// One rule list that blocks every http and https load.
    private static func offline() async throws -> WKContentRuleList {
        if let offlineList { return offlineList }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "plain-reader-tests-offline", encodedContentRuleList: rules)!
        offlineList = list
        return list
    }

    /// Expected title and byline from Readability's own test data.
    static func expected(_ name: String) throws -> (title: String, byline: String?) {
        let url = Bundle.module.url(forResource: "expected-metadata", withExtension: "json", subdirectory: "Fixtures/\(name)")!
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return (object["title"] as! String, object["byline"] as? String)
    }
}

/// Waits for a web view's main-frame navigation to finish.
@MainActor final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    func load(_ request: URLRequest, in webView: WKWebView) async throws {
        try await run(in: webView) { webView.load(request) }
    }

    /// Runs `start`, which begins a navigation, and waits for it to finish.
    func run(in webView: WKWebView, _ start: @escaping @MainActor () async throws -> Void) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor in
                do { try await start() } catch { self.finish(error) }
            }
        }
    }

    private func finish(_ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        finish(error)
    }
}

func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
}

func format(_ ms: Double) -> String {
    String(format: "%.1f ms", ms)
}
#endif
