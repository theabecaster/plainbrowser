#if canImport(UIKit)
import DesignSystem
import Reader
import UIKit
import WebEngine
import WebKit

/// The reader view: a web view the pool makes for the `plain-reader:` page, shown over the tab's
/// page in the same container, so Back or Hide Reader returns to the page exactly as it was.
///
/// Only reader pages load in it. A tapped link closes the reader and opens in the tab
/// (`onOpenLink`); anything else is cancelled. The web view is released when the reader closes.
final class ReaderPresenter: NSObject, WKNavigationDelegate {
    private(set) var webView: WKWebView?
    private var handler: ReaderSchemeHandler?
    /// A link in the article was tapped: open it in the tab.
    var onOpenLink: (URL) -> Void = { _ in }
    /// The reader page is on screen.
    var onShown: () -> Void = {}
    private var insets: (obscured: UIEdgeInsets, minimum: UIEdgeInsets, maximum: UIEdgeInsets)?

    var isShowing: Bool { webView != nil }

    /// Makes the reader web view (once per opening) and puts it, still clear, over the page.
    func prepare(pool: WebViewPool, isPrivate: Bool, in container: UIView, scrollDelegate: any UIScrollViewDelegate) {
        guard webView == nil else { return }
        var schemeHandler: ReaderSchemeHandler?
        // A private tab's article (and its images) loads with the private data store.
        let webView = pool.makeAuxiliaryWebView(isPrivate: isPrivate) { configuration in
            schemeHandler = ReaderSchemeHandler.install(in: configuration)
        }
        handler = schemeHandler
        webView.navigationDelegate = self
        webView.isFindInteractionEnabled = true
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        Paper.apply(to: webView)
        Paper.apply(to: webView.scrollView)
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.bottomEdgeEffect.isHidden = true
        webView.scrollView.delegate = scrollDelegate
        webView.accessibilityIdentifier = "readerView"
        webView.alpha = 0
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
        self.webView = webView
        if let insets { setInsets(obscured: insets.obscured, minimumViewport: insets.minimum, maximumViewport: insets.maximum) }
    }

    /// Renders `article` and loads it; the view fades in when the page has loaded.
    func show(_ article: ReaderArticle) async throws {
        guard let webView, let handler else { return }
        try await handler.show(article, in: webView)
    }

    func close(animated: Bool) {
        guard let webView else { return }
        self.webView = nil
        handler = nil
        webView.navigationDelegate = nil
        webView.scrollView.delegate = nil
        let remove = {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        guard animated, webView.alpha > 0 else { return remove() }
        Motion.animate(Motion.urlFocus, changes: { webView.alpha = 0 }, completion: remove)
    }

    func setInsets(obscured: UIEdgeInsets, minimumViewport: UIEdgeInsets, maximumViewport: UIEdgeInsets) {
        insets = (obscured, minimumViewport, maximumViewport)
        guard let webView else { return }
        if webView.obscuredContentInsets != obscured { webView.obscuredContentInsets = obscured }
        webView.scrollView.followObscuredBottom(obscured.bottom)
        if webView.minimumViewportInset != minimumViewport || webView.maximumViewportInset != maximumViewport {
            webView.setMinimumViewportInset(minimumViewport, maximumViewportInset: maximumViewport)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = action.request.url
        if ReaderRenderer.isReaderURL(url) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        // Only a tap leaves the reader; a page can't navigate on its own (JavaScript is off).
        if action.navigationType == .linkActivated, let url, action.targetFrame?.isMainFrame != false {
            onOpenLink(url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, webView.alpha == 0 else { return }
        Motion.animate(Motion.urlFocus, changes: { webView.alpha = 1 })
        onShown()
    }
}
#endif
