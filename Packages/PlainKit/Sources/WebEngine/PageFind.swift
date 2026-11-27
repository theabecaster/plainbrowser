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

/// The first matches of a query on a page, with their context, and whether there are more.
public struct PageFindResult: Sendable, Equatable {
    public let matches: [PageFindMatch]
    /// The page has more matches than were listed (the search stopped at the limit).
    public let hasMore: Bool

    public var total: Int { matches.count }

    public static let none = PageFindResult(matches: [], hasMore: false)
}

/// Find on Page as a list of results (the side pane's Find), next to the system find bar.
///
/// The search runs in the page's process, in the engine's content world (the page can't see or
/// change it). It walks the visible text block by block (a paragraph, a list item, a cell), so a
/// phrase split by inline tags (`hello <b>world</b>`) still matches, keeps a DOM range per match,
/// and marks every match with the CSS Custom Highlight API, which draws without touching the
/// page's DOM. It stops at `limit` matches: the work is bounded by the matches listed, plus one
/// pass over the text up to the last of them. A tapped result scrolls its match to the middle of
/// the page and marks it as the current one.
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
                continuation.resume(returning: PageFindResult(matches: matches, hasMore: reply["more"] as? Bool ?? false))
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
        if (!needle || !document.body) return { matches: [], more: false };
        const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'SELECT', 'OPTION']);
        const blocks = 'p,li,td,th,h1,h2,h3,h4,h5,h6,blockquote,figcaption,dd,dt,pre,article,section,div,body';
        const shown = new Map();
        const isShown = (element) => {
          if (shown.has(element)) return shown.get(element);
          const rect = element.getClientRects()[0];
          // A visually hidden label (a 1 pt clipped box for screen readers) is not on the page.
          const value = !!rect && rect.width > 1 && rect.height > 1 && getComputedStyle(element).visibility !== 'hidden';
          shown.set(element, value);
          return value;
        };
        const clip = (value) => value.replace(/\\s+/g, ' ');
        const matches = [];
        let more = false;
        // One block's text nodes, joined: matches may cross inline tags, never blocks.
        let group = null;
        const position = (offset, end) => {
          // The text node and offset for a place in the group's text (an end stays in its node).
          let index = 0;
          while (index + 1 < group.starts.length && (end ? group.starts[index + 1] < offset : group.starts[index + 1] <= offset)) index += 1;
          return [group.nodes[index], offset - group.starts[index]];
        };
        const flush = () => {
          if (!group || more) return;
          const text = group.text;
          const lower = text.toLocaleLowerCase();
          if (lower.length !== text.length) return;
          let at = lower.indexOf(needle);
          while (at >= 0) {
            if (matches.length >= limit) { more = true; return; }
            const [startNode, startOffset] = position(at, false);
            const [endNode, endOffset] = position(at + needle.length, true);
            const range = document.createRange();
            range.setStart(startNode, startOffset);
            range.setEnd(endNode, endOffset);
            state.ranges.push(range);
            matches.push({
              before: clip(text.slice(Math.max(0, at - context), at)).trimStart(),
              match: text.slice(at, at + needle.length),
              after: clip(text.slice(at + needle.length, at + needle.length + context * 2)).trimEnd(),
            });
            at = lower.indexOf(needle, at + needle.length);
          }
        };
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            const parent = node.parentElement;
            if (!parent || skip.has(parent.tagName)) return NodeFilter.FILTER_REJECT;
            return node.nodeValue ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
          },
        });
        for (let node = walker.nextNode(); node && !more; node = walker.nextNode()) {
          const parent = node.parentElement;
          if (!isShown(parent)) continue;
          const block = parent.closest(blocks) || parent;
          if (!group || group.block !== block) {
            flush();
            group = { block, nodes: [], starts: [], text: '' };
          }
          group.starts.push(group.text.length);
          group.nodes.push(node);
          group.text += node.nodeValue;
        }
        flush();
        if (highlights && state.ranges.length && globalThis.Highlight) {
          ensureStyle();
          highlights.set('plain-find', new Highlight(...state.ranges));
        }
        return { matches, more };
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
