import Foundation
import os
import PerfSignposts
import WebKit

/// A page's readable text, for a summary: the article Readability finds, or, on a page without
/// one, the main content's text blocks with navigation, headers, footers and forms left out.
public struct ReaderText: Sendable, Equatable, Codable {
    public var title: String
    public var siteName: String?
    /// Paragraphs, headings and list items, one per block, separated by blank lines.
    public var text: String
    /// The page's language (`<html lang>`), if it has one.
    public var lang: String?
    /// The address the text came from (after redirects).
    public var url: URL?
    /// Readability found an article (false: the page's main text blocks).
    public var isArticle: Bool

    public init(title: String, siteName: String? = nil, text: String, lang: String? = nil, url: URL? = nil, isArticle: Bool = true) {
        self.title = title
        self.siteName = siteName
        self.text = text
        self.lang = lang
        self.url = url
        self.isArticle = isArticle
    }
}

extension ReaderExtractor {
    /// The readable text of the document `webView` shows, at most `limit` characters, or nil when
    /// it has none. Runs in the reader's own content world, like `article(in:)`, so it works with
    /// the page's JavaScript off and page scripts never see it. Readability is injected on first
    /// use in that document. The JSON is decoded off the main thread.
    public static func text(in webView: WKWebView, limit: Int) async throws -> ReaderText? {
        let world = WKContentWorld.world(name: ReaderWorld.contentWorldName)
        var result = try await callText(in: webView, limit: limit, world: world)
        if result == missingResult {
            let script = try await ReaderResources.readabilityScript()
            try Task.checkCancellation()
            _ = try await webView.evaluateJavaScript(script, in: nil, contentWorld: world)
            result = try await callText(in: webView, limit: limit, world: world)
        }
        guard result != missingResult, result != noneResult else { return nil }
        return try await decodeText(result)
    }

    private static let missingResult = "missing"
    private static let noneResult = "none"

    private static func callText(in webView: WKWebView, limit: Int, world: WKContentWorld) async throws -> String {
        try Task.checkCancellation()
        let value = try await webView.callAsyncJavaScript(
            textBody, arguments: ["limit": limit], in: nil, contentWorld: world
        )
        guard let result = value as? String else { throw CancellationError() }
        return result
    }

    @concurrent private static func decodeText(_ json: String) async throws -> ReaderText? {
        try JSONDecoder().decode(ReaderText.self, from: Data(json.utf8))
    }

    /// The body of an async function run in the reader world, with `limit` as an argument. It
    /// returns "missing" before Readability is in this world, "none" for a page with no text, or
    /// the `ReaderText` as JSON. Only leaf text blocks are read (a list item holding paragraphs
    /// gives its paragraphs, not itself again).
    private static let textBody = """
        if (typeof Readability !== "function" || typeof isProbablyReaderable !== "function") return "missing";
        const clean = s => s.replace(/[ \\t\\u00a0\\u200b]+/g, " ").replace(/\\s*\\n\\s*/g, "\\n").trim();
        let title = document.title || "", siteName = null, lang = document.documentElement.lang || null;
        let root = null, isArticle = false;
        try {
          if (document.body && isProbablyReaderable(document)) {
            const a = new Readability(document.cloneNode(true)).parse();
            if (a && a.content && (a.textContent || "").trim()) {
              const t = document.createElement("template");
              t.innerHTML = a.content;
              root = t.content;
              title = a.title || title;
              siteName = a.siteName || null;
              lang = a.lang || lang;
              isArticle = true;
            }
          }
        } catch (e) {}
        if (!root) root = document.querySelector("article, main, [role=main]") || document.body;
        if (!root) return "none";
        const blocks = "h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,dd,dt,figcaption,td";
        const skip = "nav,header,footer,aside,form,menu,dialog,[aria-hidden=true],[hidden],script,style,noscript";
        const parts = [];
        let used = 0;
        for (const el of root.querySelectorAll(blocks)) {
          if (el.querySelector(blocks)) continue;
          if (!isArticle && el.closest(skip)) continue;
          const s = clean(el.textContent || "");
          if (s.length < 2) continue;
          parts.push(s);
          used += s.length + 2;
          if (used >= limit) break;
        }
        if (!parts.length) {
          const s = clean(root.textContent || "");
          if (s) parts.push(s);
        }
        const text = parts.join("\\n\\n").slice(0, limit);
        if (!text) return "none";
        return JSON.stringify({ title, siteName, text, lang, url: document.URL, isArticle });
        """
}
