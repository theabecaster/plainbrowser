import WebKit

/// Owns every `WKWebView` the app shows (AGENTS.md rule 2): the UI asks the pool for one and never
/// creates its own. All web views share one configuration, so they share one website data store.
public final class WebViewPool {
    public let configuration = WKWebViewConfiguration()
    private var warmWebView: WKWebView?

    public init() {}

    /// Creates one offscreen web view and loads `about:blank`, which starts the WebContent and
    /// Networking processes. The first web view costs 47–100+ ms; later ones 2–8 ms
    /// (docs/research/notes.md). Call it right after the first frame, never before.
    public func warmUp() {
        guard warmWebView == nil else { return }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        warmWebView = webView
    }

    /// A web view for a tab: the warmed one if there is one, otherwise a new one.
    public func dequeueWebView() -> WKWebView {
        if let webView = warmWebView {
            warmWebView = nil
            return webView
        }
        return WKWebView(frame: .zero, configuration: configuration)
    }
}
