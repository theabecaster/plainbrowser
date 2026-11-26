#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import WebKit
@testable import WebEngine

struct Timeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

@MainActor
func waitUntil(
    _ what: String, timeout: Duration = .seconds(15), _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw Timeout(what: what) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func ms(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
}

func describe(_ samples: [Duration]) -> String {
    let values = samples.map(ms).sorted()
    guard !values.isEmpty else { return "n/a" }
    let median = values[values.count / 2]
    return String(format: "median %.2f ms, min %.2f, max %.2f (n=%d)", median, values[0], values.last!, values.count)
}

/// Prints a measured number in a form that is easy to grep from the test log.
func report(_ line: String) {
    print("[plain-measure] \(line)")
}

/// The shell, faked: records every call and answers with preset values.
@MainActor
final class FakeHost: EngineHost {
    weak var pool: WebViewPool?
    /// When set, opened child tabs are attached here at once, as the shell would.
    var childContainer: UIView?

    var opened: [(child: Tab, opener: Tab)] = []
    var closeRequests: [Tab] = []
    var keepsCrashing: [Tab] = []
    var alerts: [String] = []
    var confirmAnswer = true
    var promptAnswer: String? = "typed"
    var credential: URLCredential?
    var authRequests: [AuthenticationRequest] = []
    var certificateErrors: [CertificateError] = []
    var proceedPastCertificateError = false
    var externalURLs: [URL] = []
    var universalLinks: [URL] = []
    var permissionAnswer = true
    var permissionAsks: [(permissions: [SitePermission], site: String)] = []
    var startedDownloads: [Download] = []
    var endedDownloads: [Download] = []

    func pool(_ pool: WebViewPool, didOpen child: Tab, from opener: Tab) {
        opened.append((child, opener))
        if let childContainer { pool.attach(child, to: childContainer) }
    }

    func pool(_ pool: WebViewPool, tabRequestsClose tab: Tab) {
        closeRequests.append(tab)
    }

    func pool(_ pool: WebViewPool, tabKeepsCrashing tab: Tab) {
        keepsCrashing.append(tab)
    }

    func tab(_ tab: Tab, alert message: String, from site: String) async {
        alerts.append(message)
    }

    func tab(_ tab: Tab, confirm message: String, from site: String) async -> Bool {
        alerts.append(message)
        return confirmAnswer
    }

    func tab(_ tab: Tab, prompt message: String, defaultText: String?, from site: String) async -> String? {
        alerts.append(message)
        return promptAnswer
    }

    func tab(_ tab: Tab, credentialFor request: AuthenticationRequest) async -> URLCredential? {
        authRequests.append(request)
        return credential
    }

    func tab(_ tab: Tab, shouldProceedPast error: CertificateError) async -> Bool {
        certificateErrors.append(error)
        return proceedPastCertificateError
    }

    func tab(_ tab: Tab, openExternally url: URL) async -> Bool {
        externalURLs.append(url)
        return true
    }

    func tab(_ tab: Tab, openUniversalLink url: URL) async -> Bool {
        universalLinks.append(url)
        return false
    }

    func tab(_ tab: Tab, allow permissions: [SitePermission], forSite site: String) async -> Bool {
        permissionAsks.append((permissions, site))
        return permissionAnswer
    }

    func downloadDidStart(_ download: Download) {
        startedDownloads.append(download)
    }

    func downloadDidEnd(_ download: Download) {
        endedDownloads.append(download)
    }
}

/// A window, a pool with a fake shell, and a local server.
@MainActor
final class Harness {
    let server: TestServer
    let pool: WebViewPool
    let host = FakeHost()
    let window: UIWindow
    /// The main pane: a phone-sized view in the window.
    let container: UIView
    let directory: URL

    init(
        paneSize: CGSize = CGSize(width: 390, height: 780),
        permissionStore: any SitePermissionStore = InMemorySitePermissionStore(),
        route: @escaping @Sendable (TestServer.Request) -> TestServer.Response = Pages.route
    ) async throws {
        server = try await TestServer(route: route)
        directory = FileManager.default.temporaryDirectory.appending(path: "plain-c-\(UUID().uuidString)")
        pool = WebViewPool(
            dataStore: .nonPersistent(),
            permissionStore: permissionStore,
            thumbnailDirectory: directory.appending(path: "Thumbnails"),
            downloadDirectory: directory.appending(path: "Downloads")
        )
        pool.host = host
        host.pool = pool
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        window.isHidden = false
        container = UIView(frame: CGRect(origin: .zero, size: paneSize))
        window.addSubview(container)
    }

    func makePane(size: CGSize) -> UIView {
        let view = UIView(frame: CGRect(origin: .zero, size: size))
        window.addSubview(view)
        return view
    }

    func cleanUp() {
        server.stop()
        window.isHidden = true
        try? FileManager.default.removeItem(at: directory)
    }

    /// Loads `path` in `tab` and waits until the page has finished loading.
    func load(_ path: String, in tab: Tab) async throws {
        let url = server.url(path)
        tab.load(url)
        try await waitForLoad(of: url, in: tab)
    }

    func waitForLoad(of url: URL, in tab: Tab) async throws {
        let webView = try #require(pool.existingWebView(for: tab))
        try await waitUntil("load of \(url.path())") {
            webView.url == url && !webView.isLoading && tab.url == url && !tab.isLoading
        }
    }

    func evaluate(_ script: String, in tab: Tab) async throws -> Any? {
        let webView = try #require(pool.existingWebView(for: tab))
        return try await webView.evaluateJavaScript(script)
    }
}

/// The test site.
enum Pages {
    static let password = "user:pass"

    @Sendable static func route(_ request: TestServer.Request) -> TestServer.Response {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        switch path {
        case "/a": return .html(page(title: "A", body: "<a id=next href='/b'>B</a>"))
        case "/b": return .html(page(title: "B", body: "<p>B</p>"))
        case "/tall":
            return .html(page(title: "Tall", body: "<div style='height:5000px;background:linear-gradient(red,blue)'>tall</div>"))
        case "/opener":
            return .html(page(title: "Opener", body: "<script>window.addEventListener('message', e => document.title = 'got ' + e.data)</script>"))
        case "/child":
            return .html(page(title: "Child", body: "<script>if (window.opener) window.opener.postMessage('hello', '*')</script>"))
        case "/file.bin":
            return .data(Data(repeating: 7, count: 4096), type: "application/octet-stream",
                         headers: ["Content-Disposition": "attachment; filename=\"report.bin\""])
        case "/big.bin":
            return .data(bigFile, type: "application/octet-stream",
                         headers: ["Content-Disposition": "attachment; filename=\"big.bin\""])
        case "/raw":
            return .data(Data(repeating: 1, count: 1024), type: "application/x-plain-unknown")
        case "/doc.pdf":
            return .data(minimalPDF, type: "application/pdf")
        case "/blob":
            return .html(page(title: "Blob", body: """
                <a id=save download="notes.txt">save</a>
                <script>
                  const url = URL.createObjectURL(new Blob(['hello blob'], { type: 'text/plain' }));
                  document.getElementById('save').href = url;
                </script>
                """))
        case "/links":
            return .html(page(title: "Links", body: """
                <a id=far href='https://example.org/x'>far</a>
                <a id=mail href='mailto:someone@example.com'>mail</a>
                """))
        case "/secret":
            let expected = "Basic " + Data(password.utf8).base64EncodedString()
            if request.headers["authorization"] == expected {
                return .html(page(title: "Welcome", body: "welcome"))
            }
            var response = TestServer.Response.html(page(title: "Denied", body: "denied"))
            response.status = 401
            response.reason = "Unauthorized"
            response.headers["WWW-Authenticate"] = "Basic realm=\"Plain Test\""
            return response
        case "/ua":
            return .html(page(title: "UA", body: "<p>ua</p>"))
        default:
            return .notFound
        }
    }

    static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title></head><body>\(body)</body></html>
        """
    }

    /// Large enough that a cancel lands before it finishes.
    static let bigFile = Data(repeating: 3, count: 256 * 1024 * 1024)

    /// A one-page PDF.
    static let minimalPDF: Data = {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        return renderer.pdfData { context in
            context.beginPage()
            ("PDF page" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
    }()
}
#endif
