#if canImport(UIKit)
import BrowserCore
import UIKit
import WebKit

/// What dark pages is doing on a tab's page (`Tab.darkPages`). The page menu offers "Turn Off
/// Dark Pages for This Site" only on `.darkened`, and "Turn On" only on `.offForSite`
/// (docs/state-rules.md, section 4).
public enum DarkPagesState: String, Sendable, Equatable {
    /// Nothing to do: the app is light, the page is not a web page, or the page is still deciding.
    case inactive
    /// The site has its own dark design (or asked to stay light), so it is left alone.
    case native
    /// Plain darkens the page.
    case darkened
    /// The user turned dark pages off for this site; the page shows as the site made it.
    case offForSite = "off"
}

/// The sites where the user turned dark pages off, remembered automatically like the other
/// per-site choices. The engine builds each page's script from `offSites`, so it must answer
/// from memory: load the stored list at launch and write changes behind it.
public protocol SiteDarkPagesStore: AnyObject {
    var offSites: Set<String> { get }
    func setDarkPagesOff(_ off: Bool, forSite site: String)
}

/// Dark pages choices kept in memory: the default until Storage provides a persistent store.
public final class InMemorySiteDarkPagesStore: SiteDarkPagesStore {
    public private(set) var offSites: Set<String> = []

    public init() {}

    public func setDarkPagesOff(_ off: Bool, forSite site: String) {
        if off { offSites.insert(site) } else { offSites.remove(site) }
    }
}

/// A private session's choices over the persistent ones: read through, written in memory.
final class LayeredDarkPagesStore: SiteDarkPagesStore {
    private let base: any SiteDarkPagesStore
    private var own: [String: Bool] = [:]

    init(base: any SiteDarkPagesStore) {
        self.base = base
    }

    var offSites: Set<String> {
        var sites = base.offSites
        for (site, off) in own {
            if off { sites.insert(site) } else { sites.remove(site) }
        }
        return sites
    }

    func setDarkPagesOff(_ off: Bool, forSite site: String) {
        own[site] = off
    }
}

/// Dark pages: while the app is dark, a page without a dark design of its own is darkened, as
/// Safari does. The research and the choice of technique are in docs/research/dark-mode.md.
///
/// One user script per page, main frame only, at document start, in the engine's content world
/// (the page can't see or undo it). It never touches a site that has a dark design: it looks for
/// a `color-scheme` that includes dark (or `only light`, a site's way of saying "never darken
/// me"), for `prefers-color-scheme: dark` rules in the style sheets it can read, and for a light
/// background with the page's own colors. Only a page that fails all three is darkened.
///
/// Darkening is one CSS filter on the root (`invert(1) hue-rotate(180deg)`): colors flip in
/// lightness and keep their hue, and pictures, video, canvases, frames and background images get
/// the same filter again, which puts them back as they were. WebKit draws the filter on the GPU
/// as the page is composited, so it costs no script work while scrolling and nothing per element;
/// the script runs a handful of checks per page and then sleeps.
///
/// While the app is dark and the page has not been judged yet, a guard keeps the page's
/// background dark, so a page never flashes white before it is darkened; it goes as soon as the
/// page shows it has dark styles of its own. The script follows `prefers-color-scheme` live, so
/// switching the app or iOS between light and dark applies or removes the darkening without a
/// reload.
enum DarkPages {
    /// The message handler the script reports its state to (`DarkPagesState` raw values).
    static let handlerName = "plainDarkPages"

    /// The area past a darkened page's edges: the page's white turned dark by the filter.
    static let overscrollColor = UIColor.black

    /// The script for one kind of tab, with the sites where dark pages is off.
    static func userScript(offSites: Set<String>) -> WKUserScript {
        WKUserScript(
            source: source(offSites: offSites), injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: UserScripts.world
        )
    }

    /// The first line of every dark-pages script, so the pool can tell it from the others.
    private static let marker = "// Plain dark pages"

    static func isDarkPagesScript(_ script: WKUserScript) -> Bool {
        script.source.hasPrefix(marker)
    }

    /// Asks the page's script to turn off (true) or back on (false) for this page now.
    static func setOffSource(_ off: Bool) -> String {
        "globalThis.__plainDarkPages && globalThis.__plainDarkPages.setOff(\(off));"
    }

    static func source(offSites: Set<String>) -> String {
        let sites = offSites.sorted().map(jsString).joined(separator: ",")
        guard FixedChoices.darkPagesOn else { return marker }
        return """
            \(marker)
            (() => {
              if (window !== window.top || !/^https?:$/.test(location.protocol)) return;
              const OFF_SITES = new Set([\(sites)]);
              const LIGHT = \(FixedChoices.darkPagesLightBackground);
              const MAX_RULES = \(FixedChoices.darkPagesMaxRulesRead);
              const MAX_SCAN = \(FixedChoices.darkPagesMaxElementsScanned);
              \(scriptBody)
            })();
            """
    }

    private static func jsString(_ text: String) -> String {
        let escaped = text.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "\\": return "\\\\"
            case "\"": return "\\\""
            default:
                return scalar.isASCII && scalar.value >= 0x20 ? String(scalar) : String(format: "\\u%04x", scalar.value)
            }
        }.joined()
        return "\"\(escaped)\""
    }

    /// The filter that darkens: lightness flips, hue stays. Applied twice it gives the original
    /// colors back (both steps commute, and two half turns of hue are a whole one), which is how
    /// pictures inside a darkened page keep their colors.
    static let filter = "invert(1) hue-rotate(180deg)"

    /// What gets the filter again, so it shows as the site made it: pictures, video, canvases
    /// (charts, maps, games), frames and plugins, and elements with an inline background image.
    /// The script marks the rest with `data-plain-dark-media`: elements whose background image is
    /// set by a style sheet, and inline SVGs drawn in color (logos). Inline SVGs in greys are
    /// icons drawn like text and flip with it, as Safari's Adaptive Dark Mode does with simple
    /// black-and-white images.
    static let mediaSelector = """
        img, picture, video, canvas, iframe, embed, object, svg image, [data-plain-dark-media], \
        [style*="background-image"], [style*="background:url"], [style*="background: url"]
        """

    private static var scriptBody: String {
        """
        const site = location.hostname.toLowerCase().replace(/^www\\./, '');
        const media = '\(mediaSelector.replacingOccurrences(of: "\n", with: " "))';
        const MARK = 'data-plain-dark-media';
        const dark = matchMedia('(prefers-color-scheme: dark)');
        let off = OFF_SITES.has(site);
        let verdict = null;   // 'darken' or 'native' once judged; null while the page is still loading
        let settled = false;  // judged for good after the page's load event
        let posted = '';
        let scanned = 0;
        let observer = null;

        const sheet = (css) => { const s = new CSSStyleSheet(); s.replaceSync(css); s.disabled = true; return s; };
        const guard = sheet('html, body { background-color: #000 !important; }');
        const theme = sheet(`@media screen {
          html { filter: \(filter) !important; background-color: #fff; }
          :is(${media}) { filter: \(filter) !important; }
          :is(${media}) :is(${media}) { filter: none !important; }
        }`);
        const ours = (s) => s === guard || s === theme;
        // Puts the sheets back if the page replaced its adopted style sheets.
        const adopt = () => {
          const list = document.adoptedStyleSheets;
          if (!list.includes(guard) || !list.includes(theme)) {
            document.adoptedStyleSheets = [...list.filter((s) => !ours(s)), guard, theme];
          }
        };

        // The state for the app's page menu, and whether this page has dark pages off: the app
        // corrects a page that kept an old choice (one restored from the back-forward cache).
        const post = (state, force) => {
          if (state === posted && !force) return;
          posted = state;
          try { webkit.messageHandlers.\(handlerName).postMessage({ state, off }); } catch (e) {}
        };

        // A computed color as { lum: relative luminance 0-1, alpha, chroma 0-1 }, or null when
        // the format is unknown. Computed colors are rgb(), color(srgb | display-p3 …), or the
        // lab family when the site wrote them that way.
        const measure = (color) => {
          if (!color || color === 'transparent') return { lum: 0, alpha: 0, chroma: 0 };
          const m = color.match(/^([a-z-]+)\\((.*)\\)$/);
          if (!m) return null;
          const [main, slash] = m[2].split('/');
          let parts = main.trim().split(/[\\s,]+/);
          let alpha = slash !== undefined ? parseFloat(slash) / (slash.includes('%') ? 100 : 1) : 1;
          const num = (v, scale) => v.endsWith('%') ? parseFloat(v) / 100 : parseFloat(v) / scale;
          const lin = (c) => c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
          const fromRGB = (r, g, b) => ({
            lum: 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b), alpha,
            chroma: Math.max(r, g, b) - Math.min(r, g, b),
          });
          switch (m[1]) {
            case 'rgb': case 'rgba':
              if (parts.length === 4 && slash === undefined) alpha = parseFloat(parts[3]);
              return fromRGB(num(parts[0], 255), num(parts[1], 255), num(parts[2], 255));
            case 'color':
              if (!/^(srgb|display-p3|srgb-linear)$/.test(parts[0])) return null;
              return fromRGB(num(parts[1], 1), num(parts[2], 1), num(parts[3], 1));
            case 'oklab': case 'oklch': {
              const l = num(parts[0], 1);
              const c = m[1] === 'oklch' ? parseFloat(parts[1]) : Math.hypot(parseFloat(parts[1]), parseFloat(parts[2]));
              return { lum: Math.pow(Math.max(0, l), 3), alpha, chroma: Math.min(1, c / 0.25) };
            }
            case 'lab': case 'lch': {
              const l = num(parts[0], 100) * 100;
              const c = m[1] === 'lch' ? parseFloat(parts[1]) : Math.hypot(parseFloat(parts[1]), parseFloat(parts[2]));
              return { lum: l > 8 ? Math.pow((l + 16) / 116, 3) : l / 903.3, alpha, chroma: Math.min(1, c / 100) };
            }
            default: return null;
          }
        };

        // Rules that apply in dark mode, in the style sheets this page can read: its own, the
        // ones they import, and its adopted ones. Another origin's sheet throws, and is skipped.
        const DARK_QUERY = /prefers-color-scheme\\s*:\\s*dark/;
        const hasDarkRules = () => {
          let read = 0;
          const visitSheet = (s) => {
            if (s.media && DARK_QUERY.test(s.media.mediaText)) return true;
            let rules = null;
            try { rules = s.cssRules; } catch (e) { return false; }
            return rules ? visit(rules) : false;
          };
          const visit = (rules) => {
            for (const rule of rules) {
              if (++read > MAX_RULES) return false;
              if (rule.media && DARK_QUERY.test(rule.media.mediaText)) return true;
              if (rule.conditionText && DARK_QUERY.test(rule.conditionText)) return true;
              if (rule.styleSheet && visitSheet(rule.styleSheet)) return true;
              if (rule.cssRules && visit(rule.cssRules)) return true;
            }
            return false;
          };
          for (const s of document.styleSheets) {
            if (visitSheet(s)) return true;
            if (read > MAX_RULES) return false;
          }
          for (const s of document.adoptedStyleSheets) {
            if (!ours(s) && visitSheet(s)) return true;
          }
          return false;
        };

        // 'native' when the page has a dark design, asks never to be darkened, is already dark,
        // or shows a background color Plain can't read; 'darken' when its background is light.
        // Read with Plain's own sheets off, so only the page's colors count.
        const judge = () => {
          const meta = document.querySelector('meta[name="color-scheme" i]');
          const declared = ((meta && meta.content) || '') + ' ' + getComputedStyle(document.documentElement).colorScheme;
          if (/\\bdark\\b/.test(declared) || /\\bonly\\b/.test(declared)) return 'native';
          if (hasDarkRules()) return 'native';
          const was = [guard.disabled, theme.disabled];
          guard.disabled = true;
          theme.disabled = true;
          let color = measure(getComputedStyle(document.documentElement).backgroundColor);
          if (color && color.alpha < 0.5 && document.body) color = measure(getComputedStyle(document.body).backgroundColor);
          [guard.disabled, theme.disabled] = was;
          if (!color) return 'native';
          // No background of its own: the page shows on the browser's white canvas.
          return (color.alpha < 0.5 ? 1 : color.lum) >= LIGHT ? 'darken' : 'native';
        };

        // An inline SVG drawn in color is a logo or an illustration: it keeps its colors. One in
        // greys is an icon drawn like text, and flips with it so it stays visible.
        const coloredSVG = (svg) => {
          const shapes = svg.querySelectorAll('path, rect, circle, ellipse, polygon, polyline, line, text, use');
          for (let i = 0; i < shapes.length && i < \(FixedChoices.darkPagesSVGShapesChecked); i++) {
            const style = getComputedStyle(shapes[i]);
            for (const paint of [style.fill, style.stroke]) {
              const c = measure(paint);
              if (c && c.alpha >= 0.5 && c.chroma >= \(FixedChoices.darkPagesColoredSVGChroma)) return true;
            }
          }
          return false;
        };
        // Pictures set by style sheets, and colored inline SVGs, get the media filter too.
        const check = (el) => {
          if (el.hasAttribute(MARK)) return;
          if (el.localName === 'svg') {
            if (coloredSVG(el)) el.setAttribute(MARK, '');
            return;
          }
          const image = getComputedStyle(el).backgroundImage;
          if (image && image !== 'none' && image.includes('url(')) el.setAttribute(MARK, '');
        };
        const scan = (rootNode) => {
          if (scanned >= MAX_SCAN || !rootNode.querySelectorAll) return;
          const nodes = rootNode.querySelectorAll('*');
          for (let i = 0; i < nodes.length && scanned < MAX_SCAN; i++, scanned++) check(nodes[i]);
        };
        // After load, pages that add content (infinite scroll, late widgets) are checked in
        // batches, and Plain's sheets are put back if the page replaced its adopted ones.
        const watch = () => {
          if (observer || !document.body) return;
          let pending = [];
          let timer = 0;
          observer = new MutationObserver((records) => {
            for (const r of records) for (const n of r.addedNodes) if (n.nodeType === 1) pending.push(n);
            if (!timer) timer = setTimeout(() => {
              timer = 0;
              const batch = pending; pending = [];
              if (theme.disabled) return;
              adopt();
              for (const n of batch) if (n.isConnected && scanned < MAX_SCAN) { scanned++; check(n); scan(n); }
            }, \(FixedChoices.darkPagesWatchDelay));
          });
          observer.observe(document.body, { childList: true, subtree: true });
        };

        // Applies the current choice: darkened, the guard while judging, or nothing.
        let adopted = false;
        const render = () => {
          const active = dark.matches && !off && !document.webkitFullscreenElement;
          // A page that is never dark never gets the style sheets.
          if (active || adopted) { adopt(); adopted = true; }
          if (active && verdict === null) {
            guard.disabled = false;
            theme.disabled = true;
          } else {
            guard.disabled = true;
            theme.disabled = !(active && verdict === 'darken');
          }
          if (!theme.disabled) {
            if (document.body && scanned === 0) scan(document.body);
            if (settled) watch();
          }
          post(!dark.matches ? 'inactive' : off ? '\(DarkPagesState.offForSite.rawValue)'
            : verdict === 'darken' ? 'darkened' : verdict === 'native' ? 'native' : 'inactive');
        };

        // Judges once the page can be judged: a body, and every style sheet in the head loaded
        // (WebKit paints nothing before those, so the first frame is already right).
        const ready = () => {
          if (!document.body) return false;
          for (const link of document.head ? document.head.querySelectorAll('link[rel~="stylesheet" i]') : []) {
            if (!link.sheet && !link.disabled && link.media !== 'print') return false;
          }
          return true;
        };
        // Time spent in this script's work on the page, for the engine's perf tests.
        let cost = 0;
        const timed = (work) => { const start = performance.now(); work(); cost += performance.now() - start; };
        const decide = (final) => timed(() => {
          if (settled || !dark.matches || off) return;
          if (!final && !ready()) return;
          verdict = judge();
          if (final) settled = true;
          render();
        });
        const frame = () => {
          if (verdict !== null || !dark.matches || off) return;
          decide(false);
          if (verdict === null) requestAnimationFrame(frame);
        };

        // Judged only while it matters: a light app never reads the page's styles. Each switch to
        // dark (or back on for the site) judges the page as it is now.
        const refresh = () => timed(() => {
          if (dark.matches && !off && document.readyState !== 'loading') {
            settled = document.readyState === 'complete';
            verdict = judge();
          }
          render();
          if (verdict === null && dark.matches && !off) requestAnimationFrame(frame);
        });
        globalThis.__plainDarkPages = {
          setOff(value) { if (off !== value) { off = value; refresh(); } else { post(posted, true); } },
          get cost() { return cost; },
          // The engine's perf test: the judgement and a full scan, averaged over `runs` (the
          // page's clock counts whole milliseconds).
          bench(runs) {
            const start = performance.now();
            for (let i = 0; i < runs; i++) { judge(); scanned = 0; scan(document.body); }
            return (performance.now() - start) / runs;
          },
        };
        dark.addEventListener('change', refresh);
        document.addEventListener('webkitfullscreenchange', refresh);
        document.addEventListener('DOMContentLoaded', () => decide(document.readyState === 'complete'));
        addEventListener('load', () => { settled = false; decide(true); });
        addEventListener('pageshow', (e) => { if (e.persisted) post(posted, true); });
        render();
        if (dark.matches && !off) requestAnimationFrame(frame);
        """
    }
}
#endif
