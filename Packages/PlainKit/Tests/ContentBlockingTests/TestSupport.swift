import ContentBlocking
import Foundation
import WebKit

/// An in-memory allow-list store that counts saves.
actor MemoryAllowListStore: SiteAllowListStore {
    private(set) var sites: Set<String>
    private(set) var saveCount = 0

    init(_ sites: Set<String> = []) {
        self.sites = sites
    }

    func loadAllowedSites() async throws -> Set<String> { sites }

    func saveAllowedSites(_ sites: Set<String>) async throws {
        self.sites = sites
        saveCount += 1
    }
}

/// A fresh, empty rule-list store in a temporary folder. Delete it with `removeStore`.
@MainActor func makeTemporaryStore() throws -> (WKContentRuleListStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("plain-cb-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return (WKContentRuleListStore(url: url), url)
}

func removeStore(at url: URL) {
    try? FileManager.default.removeItem(at: url)
}

func milliseconds(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    let ms = Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    return String(format: "%.1f ms", ms)
}

/// Loads test pages from the `plaintest` scheme, entirely offline, and reports what loaded.
///
/// Every host serves the same page: an ad image from `ad.doubleclick.net` (blocked by EasyList's
/// `||ad.doubleclick.net^`), a first-party image, and an element with id `ad_banner` (hidden
/// by EasyList's generic `###ad_banner`).
@MainActor final class PageProbe: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
    struct Result: Equatable {
        /// The ad image loaded.
        var adLoaded: Bool
        /// The first-party image loaded (control: always true).
        var ownImageLoaded: Bool
        /// The ad element was hidden by an element-hiding rule.
        var adElementHidden: Bool
    }

    static let scheme = "plaintest"

    private(set) var requestedURLs: [URL] = []
    private var finished: CheckedContinuation<Void, any Error>?

    static func url(host: String) -> URL {
        URL(string: "\(scheme)://\(host)/index.html")!
    }

    private static let page = """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
        <div id="ad_banner">ad</div>
        <img id="ad" src="\(scheme)://ad.doubleclick.net/banner.png">
        <img id="own" src="/logo.png">
        </body></html>
        """

    // 1x1 PNG.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

    /// A configuration with its own `controller`, as the web view pool should give each tab.
    func configuration(controller: WKUserContentController) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    func load(_ url: URL, in webView: WKWebView) async throws -> Result {
        webView.navigationDelegate = self
        requestedURLs = []
        try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            webView.load(URLRequest(url: url))
        }
        // `didFinish` fires after the window's load event, so every image has loaded or failed.
        let values = try await webView.evaluateJavaScript("""
            [document.getElementById('ad').naturalWidth > 0,
             document.getElementById('own').naturalWidth > 0,
             getComputedStyle(document.getElementById('ad_banner')).display === 'none']
            """) as? [Bool] ?? []
        guard values.count == 3 else { throw URLError(.cannotParseResponse) }
        return Result(adLoaded: values[0], ownImageLoaded: values[1], adElementHidden: values[2])
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        requestedURLs.append(url)
        let isImage = url.pathExtension == "png"
        let data = isImage ? Self.png : Data(Self.page.utf8)
        urlSchemeTask.didReceive(URLResponse(
            url: url, mimeType: isImage ? "image/png" : "text/html",
            expectedContentLength: data.count, textEncodingName: isImage ? nil : "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finished?.resume(throwing: error)
        finished = nil
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finished?.resume(throwing: error)
        finished = nil
    }
}
