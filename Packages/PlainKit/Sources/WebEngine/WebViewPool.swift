import PerfSignposts
import WebKit

/// Owns every `WKWebView` the app shows (AGENTS.md rule 2): the UI asks the pool for one and never
/// creates its own. All web views share one configuration, so they share one website data store.
///
/// The pool keeps a strong reference to every web view it hands out until the UI gives it back
/// with `recycle(_:)`, so the pool, not the UI, decides when a web view dies.
public final class WebViewPool {
    public let configuration = WKWebViewConfiguration()
    private var warmWebView: WKWebView?
    private var checkedOut: [ObjectIdentifier: WKWebView] = [:]

    public init() {}

    /// Creates one offscreen web view and loads `about:blank`, which starts the WebContent and
    /// Networking processes. The first web view costs 47–100+ ms; later ones 2–8 ms
    /// (docs/research/notes.md). Call it once the first frame is on screen, never before.
    public func warmUp() {
        guard warmWebView == nil else { return }
        let state = Signposts.signposter.beginInterval(Signposts.webViewWarmUp)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        warmWebView = webView
        Signposts.signposter.endInterval(Signposts.webViewWarmUp, state)
    }

    /// A web view for a tab: the warmed one if there is one, otherwise a new one. The pool keeps
    /// owning it until `recycle(_:)`.
    public func dequeueWebView() -> WKWebView {
        let webView: WKWebView
        if let warm = warmWebView {
            warmWebView = nil
            webView = warm
        } else {
            webView = WKWebView(frame: .zero, configuration: configuration)
        }
        checkedOut[ObjectIdentifier(webView)] = webView
        return webView
    }

    /// Gives a web view back. The pool stops it and releases it.
    public func recycle(_ webView: WKWebView) {
        guard checkedOut.removeValue(forKey: ObjectIdentifier(webView)) != nil else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
    }

    /// How many web views the UI holds right now.
    public var checkedOutCount: Int { checkedOut.count }
}
