#if canImport(UIKit)
import BrowserCore
import Foundation
import os
import PerfSignposts
import Reader
import Synchronization
import WebEngine
import WebKit

/// Browse for Me's hidden pages: the results page and the sources, each in its own hidden web
/// view from the pool (`WebViewPool.makeHiddenWebView`), all in one non-persistent website data
/// store made for this run and dropped with it. Nothing reaches the tabs' store, history or the
/// tab list, in a regular or a private tab, and in a test run nothing touches the owner's data.
///
/// Every view is released the moment its links or text are read, or when the read is cancelled,
/// so at most `FixedChoices.browseSources` exist at once (the run reads that many in parallel).
/// Cancelling a read returns at once, even while WebKit is still answering a script: the view is
/// stopped and released, and its late answer is dropped.
@MainActor public final class HiddenBrowsing: ResultsReading, PageReading {
    private let pool: WebViewPool
    /// This run's store. In memory only: it goes away with the last view that uses it.
    private let dataStore = WKWebsiteDataStore.nonPersistent()

    public init(pool: WebViewPool) {
        self.pool = pool
    }

    // MARK: ResultsReading

    public func links(on page: BrowseForMe.ResultsPage) async throws -> [BrowseForMe.Link] {
        let webView = pool.makeHiddenWebView(dataStore: dataStore, javaScript: page.needsJavaScript)
        let load = HiddenLoad(webView: webView)
        defer { release(webView, load) }
        return try await abandoningOnCancel {
            try await load.loadUntilReady(page.url)
            if try await Self.isChallenge(in: webView) { throw BrowseReadError.blocked }
            var links = try await Self.links(in: webView, recipe: page.recipe)
            // A list the page builds with script may come after its HTML: wait for the load.
            if links.isEmpty, page.needsJavaScript {
                await load.waitForFinish(upTo: FixedChoices.browseResultsScriptWait)
                links = try await Self.links(in: webView, recipe: page.recipe)
            }
            return links
        }
    }

    // MARK: PageReading

    public func text(of url: URL) async throws -> ReaderText? {
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.summarySource, id: signposter.makeSignpostID(), "\(url.host() ?? "")")
        let webView = pool.makeHiddenWebView(
            dataStore: dataStore, javaScript: !FixedChoices.browseSourcesWithoutJavaScript
        )
        let load = HiddenLoad(webView: webView)
        defer { release(webView, load) }
        do {
            let text = try await abandoningOnCancel {
                try await load.loadUntilReady(url)
                return try await ReaderExtractor.text(in: webView, limit: FixedChoices.summaryMaxPageText)
            }
            signposter.endInterval(Signposts.summarySource, state, "\(text == nil ? "no text" : "read")")
            return text
        } catch {
            signposter.endInterval(Signposts.summarySource, state, "\(error is CancellationError ? "cancelled" : "failed")")
            throw error
        }
    }

    private func release(_ webView: WKWebView, _ load: HiddenLoad) {
        load.cancel()
        pool.releaseHiddenWebView(webView)
    }

    // MARK: Scripts

    /// Browse for Me's own content world: page scripts never see the results reader.
    private static let world = WKContentWorld.world(name: "dev.abrahamgonzalez.plainbrowser.browse")

    /// An engine's "are you a robot" page: DuckDuckGo's challenge form, Google's `/sorry/`, a
    /// captcha frame.
    private static func isChallenge(in webView: WKWebView) async throws -> Bool {
        let value = try await webView.callAsyncJavaScript("""
            return !!document.querySelector('form#challenge-form, form[action*="anomaly"], #captcha-form, \
            form[action*="captcha"], iframe[src*="recaptcha"], iframe[src*="hcaptcha"], iframe[src*="challenges.cloudflare"]') \
            || /\\/sorry\\/|captcha|anomaly/i.test(location.pathname)
            """, in: nil, contentWorld: world)
        return value as? Bool ?? false
    }

    /// The recipe's links, in page order, with their titles and whether an ad holds them.
    private static func links(in webView: WKWebView, recipe: BrowseForMe.Recipe) async throws -> [BrowseForMe.Link] {
        let value = try await webView.callAsyncJavaScript("""
            const out = [];
            for (const a of document.querySelectorAll(links)) {
              if (!a.href) continue;
              const heading = a.querySelector('h3, h2, .title');
              const title = (heading ? heading.textContent : a.textContent) || "";
              out.push({ href: a.href, title: title.trim().slice(0, titleLength), isAd: !!(ads && a.closest(ads)) });
              if (out.length >= max) break;
            }
            return JSON.stringify(out);
            """, arguments: ["links": recipe.links, "ads": recipe.ads, "max": FixedChoices.browseResultsLinksRead,
                        "titleLength": FixedChoices.browseResultTitleLength],
            in: nil, contentWorld: world)
        guard let json = value as? String else { return [] }
        return try await decode(json)
    }

    @concurrent private static func decode(_ json: String) async throws -> [BrowseForMe.Link] {
        try JSONDecoder().decode([BrowseForMe.Link].self, from: Data(json.utf8))
    }
}

/// One hidden page's load: main-frame web pages only (no frames, downloads or other schemes),
/// done when its document has parsed (DOMContentLoaded), which is all Reader needs.
@MainActor final class HiddenLoad: NSObject, WKNavigationDelegate {
    enum Failure: Error {
        /// Not an HTML page (a PDF, a download, another scheme), or the web content process died.
        case notAPage
    }

    let webView: WKWebView
    private var committed: CheckedContinuation<Void, any Error>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var didFinish = false
    private var refused = false
    /// `cancel()` ran: the load is over and nothing starts again.
    private var isCancelled = false

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
    }

    /// Loads `url` and returns once its document has parsed.
    func loadUntilReady(_ url: URL) async throws {
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in
            committed = continuation
            webView.load(URLRequest(url: url))
        }
        // The document exists from the commit; poll until it has parsed. Each poll answers at
        // once (no promise that a navigation could leave hanging), and the caller's budget and
        // cancellation bound the wait.
        while !Task.isCancelled, !isCancelled {
            let state = try? await webView.evaluateJavaScript("document.readyState", in: nil, contentWorld: .defaultClient)
            if let state = state as? String, state != "loading" { return }
            if didFinish { return }
            try await Task.sleep(for: FixedChoices.hiddenPageReadyPoll)
        }
        throw CancellationError()
    }

    /// Waits for the page's load event, at most `limit`.
    func waitForFinish(upTo limit: Duration) async {
        guard !didFinish, !isCancelled else { return }
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            self?.resumeFinishWaiters()
        }
        await withCheckedContinuation { finishWaiters.append($0) }
        timeout.cancel()
    }

    /// Stops the page and fails a load still waiting.
    func cancel() {
        isCancelled = true
        webView.navigationDelegate = nil
        webView.stopLoading()
        resumeCommit(throwing: CancellationError())
        resumeFinishWaiters()
    }

    private func resumeCommit(throwing error: (any Error)? = nil) {
        guard let committed else { return }
        self.committed = nil
        if let error { committed.resume(throwing: error) } else { committed.resume() }
    }

    private func resumeFinishWaiters() {
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let scheme = action.request.url?.scheme?.lowercased()
        let isMainFrame = action.targetFrame?.isMainFrame ?? false
        // Frames hold ads, embeds and trackers, never the article; other schemes leave the app.
        decisionHandler(isMainFrame && (scheme == "https" || scheme == "http") ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let type = response.response.mimeType?.lowercased() ?? ""
        let isPage = response.canShowMIMEType && (type == "text/html" || type == "application/xhtml+xml")
        if response.isForMainFrame, !isPage {
            refused = true
            decisionHandler(.cancel)
            resumeCommit(throwing: Failure.notAPage)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        resumeCommit()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
        resumeCommit()
        resumeFinishWaiters()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        resumeCommit(throwing: refused ? Failure.notAPage : error)
        resumeFinishWaiters()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        didFinish = true
        resumeCommit(throwing: error)
        resumeFinishWaiters()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resumeCommit(throwing: Failure.notAPage)
        resumeFinishWaiters()
    }
}

#endif
