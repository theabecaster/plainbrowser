import Foundation
import os
import PerfSignposts
import WebKit

/// Finds a page's main article with Mozilla Readability.
///
/// Everything runs in the reader's own `WKContentWorld` (`ReaderWorld`), never the page world, so
/// page scripts can neither see nor tamper with it.
///
/// Two steps, so ordinary browsing pays almost nothing:
/// 1. **Availability.** `install(in:)` adds only `Readability-readerable.js` (about 4 KB) as a
///    main-frame user script at document end (DOMContentLoaded). It runs `isProbablyReaderable`
///    and reports the answer; `onAvailability` hears it, so the shell can offer reader mode.
/// 2. **Extraction.** `article(in:)`, when the user opens reader mode, injects the full
///    `Readability.js` (about 90 KB) into that document's reader world and parses a clone of the
///    page. The page returns one JSON string, decoded off the main thread.
@MainActor public final class ReaderExtractor: NSObject, WKScriptMessageHandler {
    /// Called on the main thread when a page's readerable check reports: `true` when the page
    /// probably has an article.
    public var onAvailability: ((WKWebView, Bool) -> Void)?

    private struct Availability {
        weak var webView: WKWebView?
        let url: URL?
        let available: Bool
    }

    private struct Kept {
        weak var webView: WKWebView?
        let url: URL?
        let article: ReaderArticle?
    }

    private static let messageName = "plainReaderAvailability"

    private let world = WKContentWorld.world(name: ReaderWorld.contentWorldName)
    private var availability: [ObjectIdentifier: Availability] = [:]
    private var kept: [ObjectIdentifier: Kept] = [:]

    public override init() {}

    // MARK: Availability

    /// Adds the readerable check to `controller`, in the reader world. Call it while building a
    /// web view's configuration, before its first navigation. Reads the script off the main thread.
    public func install(in controller: WKUserContentController) async throws {
        let check = try await ReaderResources.readerableScript()
        let source = check + """

            ;(() => {
              let available = false;
              try { available = !!document.body && isProbablyReaderable(document); } catch (e) {}
              window.webkit.messageHandlers.\(Self.messageName).postMessage(available);
            })();
            """
        controller.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        controller.add(WeakMessageHandler(self), contentWorld: world, name: Self.messageName)
    }

    /// The last readerable report for the page `webView` shows now, or `nil` before it reports.
    public func isAvailable(in webView: WKWebView) -> Bool? {
        guard let entry = availability[ObjectIdentifier(webView)], entry.webView === webView,
              entry.url == webView.url
        else { return nil }
        return entry.available
    }

    public func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName, message.frameInfo.isMainFrame,
              let webView = message.webView, let available = message.body as? Bool
        else { return }
        let key = ObjectIdentifier(webView)
        prune()
        availability[key] = Availability(webView: webView, url: webView.url, available: available)
        if kept[key]?.url != webView.url { kept[key] = nil }
        onAvailability?(webView, available)
    }

    // MARK: Extraction

    /// The page's article, or `nil` when the page isn't readerable. Repeated calls for the same
    /// page return the article already found.
    public func article(in webView: WKWebView) async throws -> ReaderArticle? {
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.readerExtract)
        defer { signposter.endInterval(Signposts.readerExtract, state) }

        let key = ObjectIdentifier(webView)
        let url = webView.url
        if let entry = kept[key], entry.webView === webView, entry.url == url {
            return entry.article
        }
        let article = try await extract(in: webView)
        // Keep it only if the web view still shows the page it came from.
        if webView.url == url {
            prune()
            kept[key] = Kept(webView: webView, url: url, article: article)
        }
        return article
    }

    /// Forgets what was kept for `webView`, for example when its tab closes.
    public func forget(_ webView: WKWebView) {
        availability[ObjectIdentifier(webView)] = nil
        kept[ObjectIdentifier(webView)] = nil
    }

    /// Runs the check and the parse in the reader world, installing Readability first when this
    /// document's reader world doesn't have it yet.
    private func extract(in webView: WKWebView) async throws -> ReaderArticle? {
        let url = webView.url
        var result = try await callExtract(in: webView)
        if result == Self.missing {
            let script = try await ReaderResources.readabilityScript()
            try Task.checkCancellation()
            _ = try await webView.evaluateJavaScript(script, in: nil, contentWorld: world)
            result = try await callExtract(in: webView)
        }
        guard result != Self.missing, result != Self.notReaderable else { return nil }
        return try await Self.decode(result, pageURL: url)
    }

    private func callExtract(in webView: WKWebView) async throws -> String {
        try Task.checkCancellation()
        let value = try await webView.callAsyncJavaScript(Self.extractBody, in: nil, contentWorld: world)
        return value as? String ?? Self.notReaderable
    }

    private static let missing = "missing"
    private static let notReaderable = "none"

    /// The body of an async function run in the reader world. It returns one string: a status,
    /// or the article as JSON, so the app receives a single value instead of a bridged dictionary.
    private static let extractBody = """
        if (typeof Readability !== "function" || typeof isProbablyReaderable !== "function") return "missing";
        try {
          if (!document.body || !isProbablyReaderable(document)) return "none";
          const a = new Readability(document.cloneNode(true)).parse();
          if (!a || !a.content || !(a.textContent || "").trim()) return "none";
          return JSON.stringify({
            title: a.title || document.title || "",
            byline: a.byline || null,
            siteName: a.siteName || null,
            contentHTML: a.content,
            textLength: a.length || 0,
            lang: a.lang || document.documentElement.lang || null,
            dir: a.dir || null,
            excerpt: a.excerpt || null
          });
        } catch (e) {
          return "none";
        }
        """

    /// Decodes the page's JSON off the main thread.
    @concurrent private static func decode(_ json: String, pageURL: URL?) async throws -> ReaderArticle? {
        var article = try JSONDecoder().decode(ReaderArticle.self, from: Data(json.utf8))
        article.url = pageURL
        return article
    }

    private func prune() {
        availability = availability.filter { $0.value.webView != nil }
        kept = kept.filter { $0.value.webView != nil }
    }
}

/// `WKUserContentController` keeps its message handlers strongly. This keeps the extractor weakly,
/// so a long-lived controller never keeps it alive.
@MainActor private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
