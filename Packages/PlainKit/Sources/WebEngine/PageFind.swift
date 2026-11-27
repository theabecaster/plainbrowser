#if canImport(UIKit)
import BrowserCore
import Foundation
import WebKit

/// One place a query matched on the page: the words around it, for a list of results.
public struct PageFindMatch: Sendable, Equatable {
    public let before: String
    public let match: String
    public let after: String

    public init(before: String, match: String, after: String) {
        self.before = before
        self.match = match
        self.after = after
    }
}

/// Every match of a query on a page: how many there are, and the first ones with their context.
public struct PageFindResult: Sendable, Equatable {
    public let total: Int
    public let matches: [PageFindMatch]

    public static let none = PageFindResult(total: 0, matches: [])
}

/// Find on Page as a list of results (the side pane's Find), next to the system find bar.
///
/// The search runs in the page's process, in the engine's content world (the page can't see or
/// change it): it walks the visible text, keeps a DOM range per match, and marks every match with
/// the CSS Custom Highlight API, which draws without touching the page's DOM. A tapped result
/// scrolls its match to the middle of the page and marks it as the current one.
public enum PageFind {
    /// Finds `query` (case-insensitive) in `webView`'s page, up to `limit` matches with context.
    @MainActor
    public static func find(
        _ query: String, in webView: WKWebView, limit: Int = FixedChoices.findResultLimit
    ) async -> PageFindResult {
        await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(
                findSource, arguments: ["query": query, "limit": limit, "context": FixedChoices.findResultContext],
                in: nil, in: UserScripts.world
            ) { result in
                guard let reply = (try? result.get()) as? [String: Any] else { return continuation.resume(returning: .none) }
                let matches = (reply["matches"] as? [[String: Any]] ?? []).map {
                    PageFindMatch(
                        before: $0["before"] as? String ?? "", match: $0["match"] as? String ?? "",
                        after: $0["after"] as? String ?? ""
                    )
                }
                continuation.resume(returning: PageFindResult(total: reply["total"] as? Int ?? matches.count, matches: matches))
            }
        }
    }

    /// Scrolls match `index` of the last `find` to the middle of the page and marks it current.
    /// False when the page changed since (the match is gone).
    @MainActor
    public static func reveal(_ index: Int, in webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(revealSource, arguments: ["index": index], in: nil, in: UserScripts.world) { result in
                continuation.resume(returning: (try? result.get()) as? Bool ?? false)
            }
        }
    }

    /// Removes the marks and forgets the matches.
    @MainActor
    public static func clear(in webView: WKWebView) {
        webView.callAsyncJavaScript(clearSource, arguments: [:], in: nil, in: UserScripts.world) { _ in }
    }

    /// The highlight styles, added once per document as a constructed style sheet (a page's
    /// Content Security Policy blocks inline `<style>`, not the CSS object model).
    private static let styleSource = """
        const ensureStyle = () => {
          if (globalThis.__plainFindStyled === document) return;
          globalThis.__plainFindStyled = document;
          const css = '::highlight(plain-find){background-color:rgba(255,204,0,0.38);}'
            + '::highlight(plain-find-current){background-color:rgb(255,204,0);color:black;}';
          try {
            const sheet = new CSSStyleSheet();
            sheet.replaceSync(css);
            document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
          } catch (e) {
            const style = document.createElement('style');
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          }
        };
        const highlights = (globalThis.CSS && CSS.highlights) ? CSS.highlights : null;
        """

    static let findSource = """
        \(styleSource)
        const state = globalThis.__plainFind = { ranges: [] };
        if (highlights) { highlights.delete('plain-find'); highlights.delete('plain-find-current'); }
        const needle = String(query).trim().toLocaleLowerCase();
        if (!needle || !document.body) return { total: 0, matches: [] };
        const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'SELECT', 'OPTION']);
        const shown = new Map();
        const isShown = (element) => {
          if (shown.has(element)) return shown.get(element);
          const style = getComputedStyle(element);
          const value = element.getClientRects().length > 0 && style.visibility !== 'hidden';
          shown.set(element, value);
          return value;
        };
        const blockOf = (element) => element.closest(
          'p,li,td,th,h1,h2,h3,h4,h5,h6,blockquote,figcaption,dd,dt,pre,article,section,div') || element;
        // The block's text with the match's offset in it, so the context crosses inline tags.
        const contextOf = (node, at) => {
          const block = blockOf(node.parentElement);
          const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
          let offset = 0;
          for (let current = walker.nextNode(); current && current !== node; current = walker.nextNode()) {
            offset += current.nodeValue.length;
          }
          const text = block.textContent || '';
          const start = offset + at;
          const clip = (value) => value.replace(/\\s+/g, ' ');
          return {
            before: clip(text.slice(Math.max(0, start - context), start)).trimStart(),
            match: text.slice(start, start + needle.length),
            after: clip(text.slice(start + needle.length, start + needle.length + context * 2)).trimEnd(),
          };
        };
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            const parent = node.parentElement;
            if (!parent || skip.has(parent.tagName)) return NodeFilter.FILTER_REJECT;
            return node.nodeValue && node.nodeValue.length >= needle.length ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
          },
        });
        const matches = [];
        let total = 0;
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const text = node.nodeValue;
          const lower = text.toLocaleLowerCase();
          if (lower.length !== text.length) continue;
          let at = lower.indexOf(needle);
          if (at < 0 || !isShown(node.parentElement)) continue;
          while (at >= 0) {
            total += 1;
            if (state.ranges.length < limit) {
              const range = document.createRange();
              range.setStart(node, at);
              range.setEnd(node, at + needle.length);
              state.ranges.push(range);
              matches.push(contextOf(node, at));
            }
            at = lower.indexOf(needle, at + needle.length);
          }
        }
        if (highlights && state.ranges.length && globalThis.Highlight) {
          ensureStyle();
          highlights.set('plain-find', new Highlight(...state.ranges));
        }
        return { total, matches };
        """

    static let revealSource = """
        \(styleSource)
        const state = globalThis.__plainFind;
        const range = state && state.ranges[index];
        if (!range || !range.startContainer.isConnected) return false;
        const element = range.startContainer.parentElement;
        if (!element) return false;
        element.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' });
        if (highlights && globalThis.Highlight) {
          ensureStyle();
          highlights.set('plain-find-current', new Highlight(range));
        }
        return true;
        """

    static let clearSource = """
        globalThis.__plainFind = { ranges: [] };
        if (globalThis.CSS && CSS.highlights) {
          CSS.highlights.delete('plain-find');
          CSS.highlights.delete('plain-find-current');
        }
        """
}
#endif
