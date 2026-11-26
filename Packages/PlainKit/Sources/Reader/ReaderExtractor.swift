import Foundation
import os
import PerfSignposts
import WebKit

/// Finds a page's main article with Mozilla Readability.
///
/// Readability runs in the reader's own `WKContentWorld` (`ReaderWorld`), never the page world,
/// so page scripts can neither see it nor tamper with it. `isProbablyReaderable` runs first; a
/// page that fails it gives `nil` without the full parse.
///
/// Work split:
/// - The web content process does the DOM work (the check, the clone, the parse).
/// - The page returns one JSON string. It is decoded off the main thread.
/// - The main thread only starts the calls and receives that string.
///
/// Use: call `prefetch(in:)` from the navigation delegate's `didFinish`. It runs the cheap
/// readerable check and, on a small page, the full parse, and keeps the result for that web view
/// and URL. `article(in:)` returns the kept result when the URL still matches, and extracts
/// otherwise.
@MainActor public final class ReaderExtractor {
    /// Pages with more elements than this skip the full parse at prefetch; it waits for a request.
    /// Readability's cost grows with the DOM, and most articles are well under this.
    static let prefetchElementLimit = 4_000

    private enum Outcome: Sendable {
        case article(ReaderArticle)
        case notReaderable
        /// Readerable, but too big to parse ahead of a request.
        case deferred
    }

    private struct Entry {
        weak var webView: WKWebView?
        let url: URL?
        let task: Task<Outcome, any Error>
    }

    private let world = WKContentWorld.world(name: ReaderWorld.contentWorldName)
    private var entries: [ObjectIdentifier: Entry] = [:]

    public init() {}

    /// Starts extraction for the page that just finished loading: the readerable check, and the
    /// full parse when the page is small. Replaces anything kept for this web view.
    public func prefetch(in webView: WKWebView) {
        pruneEntries()
        let task = Task { [weak webView] () throws -> Outcome in
            guard let webView else { return .notReaderable }
            return try await self.run(in: webView, deferLargePages: true)
        }
        entries[ObjectIdentifier(webView)] = Entry(webView: webView, url: webView.url, task: task)
    }

    /// The page's article, or `nil` when the page isn't readerable.
    public func article(in webView: WKWebView) async throws -> ReaderArticle? {
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.readerExtract)
        defer { signposter.endInterval(Signposts.readerExtract, state) }

        let key = ObjectIdentifier(webView)
        if let entry = entries[key], entry.webView === webView, entry.url == webView.url,
           let outcome = try? await entry.task.value {
            switch outcome {
            case .article(let article): return article
            case .notReaderable: return nil
            case .deferred: break
            }
        }

        let url = webView.url
        let task = Task { [weak webView] () throws -> Outcome in
            guard let webView else { return .notReaderable }
            return try await self.run(in: webView, deferLargePages: false)
        }
        entries[key] = Entry(webView: webView, url: url, task: task)
        switch try await task.value {
        case .article(let article): return article
        case .notReaderable, .deferred: return nil
        }
    }

    /// Forgets what was kept for `webView`, for example when its tab closes.
    public func forget(_ webView: WKWebView) {
        entries[ObjectIdentifier(webView)]?.task.cancel()
        entries[ObjectIdentifier(webView)] = nil
    }

    // MARK: Running Readability

    /// Runs the check (and the parse) in the reader world. Installs Readability first when this
    /// document's reader world doesn't have it yet.
    private func run(in webView: WKWebView, deferLargePages: Bool) async throws -> Outcome {
        var result = try await callExtract(in: webView, deferLargePages: deferLargePages)
        if result == Self.missing {
            let script = try await ReaderResources.readabilityScript()
            try Task.checkCancellation()
            _ = try await webView.evaluateJavaScript(script, in: nil, contentWorld: world)
            result = try await callExtract(in: webView, deferLargePages: deferLargePages)
        }
        switch result {
        case Self.notReaderable, Self.missing: return .notReaderable
        case Self.deferred: return .deferred
        default: return try await Self.decode(result, pageURL: webView.url).map(Outcome.article) ?? .notReaderable
        }
    }

    private func callExtract(in webView: WKWebView, deferLargePages: Bool) async throws -> String {
        try Task.checkCancellation()
        let value = try await webView.callAsyncJavaScript(
            Self.extractBody,
            arguments: ["elementLimit": deferLargePages ? Self.prefetchElementLimit : 0],
            in: nil,
            contentWorld: world
        )
        return value as? String ?? Self.notReaderable
    }

    private static let missing = "missing"
    private static let notReaderable = "none"
    private static let deferred = "deferred"

    /// The body of an async function run in the reader world. It returns one string: a status,
    /// or the article as JSON, so the app receives a single value instead of a bridged dictionary.
    private static let extractBody = """
        if (typeof Readability !== "function" || typeof isProbablyReaderable !== "function") return "missing";
        try {
          if (!document.body || !isProbablyReaderable(document)) return "none";
          if (elementLimit > 0 && document.getElementsByTagName("*").length > elementLimit) return "deferred";
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

    private func pruneEntries() {
        entries = entries.filter { $0.value.webView != nil }
    }
}
