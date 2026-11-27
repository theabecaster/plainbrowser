#if canImport(UIKit)
import BrowserCore
import UIKit
import WebKit

/// Web views for pages read out of sight (Browse for Me's results page and sources). The pool
/// owns them like every web view; they are never tabs, never on screen, and never in history.
///
/// Each run passes its own `WKWebsiteDataStore.nonPersistent()`, so nothing a hidden page sets
/// (cookies, storage, cache) outlives the run or reaches the tabs' store, and the user's cookies
/// and logins are never sent to pages they didn't open (`FixedChoices.summariesLeaveNoTrace`).
/// The same holds in an isolated test run: a hidden view never touches `AppWebsiteData.store`.
extension WebViewPool {
    /// A hidden web view in `dataStore`: the tabs' identity (user agent, HTTPS first), Plain's
    /// content blocking, no page scripts, no media, no popups or dialogs (no UI delegate), and
    /// JavaScript only when `javaScript` (results pages that build their list with script).
    ///
    /// It has its own `WKPreferences` with no inactive scheduling, so its page keeps loading
    /// outside a window, where a tab's page is suspended. Release it with
    /// `releaseHiddenWebView(_:)` as soon as its text is read: each one costs a WebContent
    /// process's memory.
    public func makeHiddenWebView(dataStore: WKWebsiteDataStore, javaScript: Bool) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = EngineChoices.applicationNameForUserAgent
        // Nothing plays: a hidden page has no one to hear it.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.dataDetectorTypes = []
        configuration.suppressesIncrementalRendering = true
        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = false
        // A hidden page can't be interacted with, so there is nothing to warn about; the lookup
        // would only add a request.
        preferences.isFraudulentWebsiteWarningEnabled = false
        preferences.isElementFullscreenEnabled = false
        preferences.inactiveSchedulingPolicy = .none
        configuration.preferences = preferences
        let page = WKWebpagePreferences()
        page.preferredHTTPSNavigationPolicy = .automaticFallbackToHTTP
        page.allowsContentJavaScript = javaScript
        configuration.defaultWebpagePreferences = page
        let controller = WKUserContentController()
        configuration.userContentController = controller
        contentRules?.apply(to: controller, forMainFrameURL: nil)
        // A phone-sized viewport, so pages lay out as they would in a tab.
        let webView = WKWebView(frame: CGRect(origin: .zero, size: defaultPaneSize), configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        hiddenWebViews[ObjectIdentifier(webView)] = controller
        return webView
    }

    /// Stops and releases a hidden web view: its content rules, its scripts and its process.
    public func releaseHiddenWebView(_ webView: WKWebView) {
        guard let controller = hiddenWebViews.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        contentRules?.release(controller)
        controller.removeAllUserScripts()
        controller.removeAllScriptMessageHandlers()
    }

    /// Hidden web views lent out now. Browse for Me keeps at most `FixedChoices.browseSources`
    /// at once; tests check every one is released.
    public var hiddenWebViewCount: Int { hiddenWebViews.count }
}
#endif
