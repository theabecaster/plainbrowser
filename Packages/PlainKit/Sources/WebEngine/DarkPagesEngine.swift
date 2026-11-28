#if canImport(UIKit)
import BrowserCore

/// The script behind dark pages: judging a page, and darkening it per color the way Safari's
/// Adaptive Dark Mode and Chrome's Auto Dark Mode do in the engine. The research and the reasons
/// are in docs/research/dark-mode.md ("Per-element darkening").
///
/// - **Roles, not one filter.** Every color is changed by the role it plays: a light background
///   turns dark, dark text turns light, a light border turns into a visible grey. Anything already
///   dark stays a background as made, anything already light stays text as made, so a black hero
///   with white text and a dark card on a light section keep their design. Lightness is flipped in
///   OKLab, keeping hue and as much chroma as fits.
/// - **Style sheets first.** Each of the page's style sheets gets a twin made of only its rules
///   with colors, rewritten, in the same order, the same `@media`, `@supports`, `@layer` and
///   nesting, so the cascade (states, pseudo-elements, class changes) works as the site wrote it.
///   CSS variables that hold colors get one twin per role (`--plain-b-x`, `--plain-f-x`,
///   `--plain-d-x`), and uses of them in colors are pointed at the role's twin, with the original
///   as the fallback. Sheets from another origin are read again with the page's own `fetch`
///   where CORS allows.
/// - **Elements second.** What sheets can't reach (inline styles, `bgcolor` and `<font color>`,
///   sheets another origin won't share, inline SVG icons drawn in black, text left under 4.5:1
///   contrast) is fixed per element with a token attribute and a rule, checked top of the
///   document first in the first frame and the rest in idle slices.
/// - **Never touched:** pictures (but black-and-white logos, inverted after a histogram check, as
///   Safari does), video, canvases, other origins' frames, CSS background pictures, emoji,
///   colored SVG logos, and every page with a dark design of its own. Open shadow roots get twins
///   and fixes of their own; same-origin frames run the engine and follow the page.
///
/// All of it lives in constructed style sheets (`adoptedStyleSheets`) and one data attribute, in
/// the engine's content world, so pages never see a changed `<style>` and their scripts read the
/// colors they wrote.
extension DarkPages {
    /// The engine's values, from `FixedChoices` (each has its reason there).
    static var engineConstants: String {
        """
        const LIGHT = \(FixedChoices.darkPagesLightBackground);
        const MAX_RULES = \(FixedChoices.darkPagesMaxRulesRead);
        const BG_L = \(FixedChoices.darkPagesBackgroundLightness), BG_T = \(FixedChoices.darkPagesBackgroundThreshold);
        const FG_L = \(FixedChoices.darkPagesTextLightness), FG_T = \(FixedChoices.darkPagesTextThreshold);
        const BD_L = \(FixedChoices.darkPagesBorderLightness), BD_T = \(FixedChoices.darkPagesBorderThreshold);
        const LIFT = \(FixedChoices.darkPagesLift), LIFT_BELOW = \(FixedChoices.darkPagesLiftBelowContrast);
        const MIN_CONTRAST = \(FixedChoices.darkPagesMinimumContrast);
        const FIRST_MS = \(FixedChoices.darkPagesFirstFrameBudget), SLICE_MS = \(FixedChoices.darkPagesSliceBudget);
        const SVG_CHROMA = \(FixedChoices.darkPagesColoredSVGChroma), SVG_SHAPES = \(FixedChoices.darkPagesSVGShapesChecked);
        const LOGO_MAX_W = \(FixedChoices.darkPagesLogoMaxWidth), LOGO_MAX_H = \(FixedChoices.darkPagesLogoMaxHeight);
        const LOGO_READS = \(FixedChoices.darkPagesLogosRead), LOGO_SAMPLE = \(FixedChoices.darkPagesLogoSample);
        const LOGO_INVERT = \(FixedChoices.darkPagesLogoInvert), LOGO_VANISH = \(FixedChoices.darkPagesLogoVanishingContrast);
        const LOGO_CLEAR = \(FixedChoices.darkPagesLogoClearShare), LOGO_COLORED = \(FixedChoices.darkPagesLogoColoredShare), LOGO_WHITE = \(FixedChoices.darkPagesLogoWhiteShare);
        const LATE_HOST_CHECKS = [\(FixedChoices.darkPagesLateComponentChecks.map(String.init).joined(separator: ","))];
        const WATCH_DELAY = \(FixedChoices.darkPagesWatchDelay), SHEET_CHECK = \(FixedChoices.darkPagesSheetCheckInterval);
        const CHECK_DELAY = \(FixedChoices.darkPagesCheckDelay), CHECK_SLICE = \(FixedChoices.darkPagesCheckSlice);
        const LIGHT_SAMPLES = \(FixedChoices.darkPagesLightSamplesNeeded);
        """
    }

    // The engine itself. A raw string: backslashes are JavaScript's own. Only `\#(...)` is Swift.
    static let engineBody = #"""
    const site = location.hostname.toLowerCase().replace(/^www\./, '');
    const ATTR = 'data-plain-dark';
    const dark = matchMedia('(prefers-color-scheme: dark)');
    // In a same-origin frame the top page's engine (TOP) decides: its site's switch and verdict.
    // `off`: dark pages doesn't apply here (the switch is off and the site has no choice, or the
    // user turned the site off); `siteOff`: the latter, by hand.
    let siteOff = OFF_SITES.has(site);
    let off = TOP ? TOP.off : !(ON_SITES.has(site) || (!siteOff && ENABLED));
    // Whether a page dark pages doesn't apply to could use it: null until checked (`checkLight`),
    // then true or false. A page that was darkened is known to be light.
    let light = null;
    // This document's token: the shell takes reports and answers only for the current document.
    const DOC = Math.random().toString(36).slice(2) + Date.now().toString(36);
    let verdict = null;   // 'darken' or 'native' once judged; null while the page is still loading
    let settled = false;  // judged for good after the page's load event
    let posted = '';
    const now = () => performance.now();
    const stats = { judgeMs: 0, rewriteMs: 0, patchMs: 0, rules: 0, emitted: 0, patched: 0, contrastFixed: 0,
      icons: 0, shadowRoots: 0, logos: 0, logosRead: 0, logoMs: 0, logoMax: 0, lifted: 0, checked: 0, chained: 0, rechecked: 0, flushes: 0, slices: 0, styleMs: 0, onPicture: 0, fetched: 0, unreadable: 0, firstDark: -1, dcl: -1, firstPatchDone: -1 };
    // Script time on the page (outermost calls only), and per part.
    let cost = 0;
    let depth = 0;
    const timed = (work, key) => {
      const start = now();
      depth++;
      try { return work(); } finally {
        depth--;
        const t = now() - start;
        if (!depth) cost += t;
        if (key) stats[key] += t;
      }
    };

    // MARK: Colors

    const NAMED = new Map('aliceblue:f0f8ff,antiquewhite:faebd7,aqua:00ffff,aquamarine:7fffd4,azure:f0ffff,beige:f5f5dc,bisque:ffe4c4,black:000000,blanchedalmond:ffebcd,blue:0000ff,blueviolet:8a2be2,brown:a52a2a,burlywood:deb887,cadetblue:5f9ea0,chartreuse:7fff00,chocolate:d2691e,coral:ff7f50,cornflowerblue:6495ed,cornsilk:fff8dc,crimson:dc143c,cyan:00ffff,darkblue:00008b,darkcyan:008b8b,darkgoldenrod:b8860b,darkgray:a9a9a9,darkgreen:006400,darkgrey:a9a9a9,darkkhaki:bdb76b,darkmagenta:8b008b,darkolivegreen:556b2f,darkorange:ff8c00,darkorchid:9932cc,darkred:8b0000,darksalmon:e9967a,darkseagreen:8fbc8f,darkslateblue:483d8b,darkslategray:2f4f4f,darkslategrey:2f4f4f,darkturquoise:00ced1,darkviolet:9400d3,deeppink:ff1493,deepskyblue:00bfff,dimgray:696969,dimgrey:696969,dodgerblue:1e90ff,firebrick:b22222,floralwhite:fffaf0,forestgreen:228b22,fuchsia:ff00ff,gainsboro:dcdcdc,ghostwhite:f8f8ff,gold:ffd700,goldenrod:daa520,gray:808080,green:008000,greenyellow:adff2f,grey:808080,honeydew:f0fff0,hotpink:ff69b4,indianred:cd5c5c,indigo:4b0082,ivory:fffff0,khaki:f0e68c,lavender:e6e6fa,lavenderblush:fff0f5,lawngreen:7cfc00,lemonchiffon:fffacd,lightblue:add8e6,lightcoral:f08080,lightcyan:e0ffff,lightgoldenrodyellow:fafad2,lightgray:d3d3d3,lightgreen:90ee90,lightgrey:d3d3d3,lightpink:ffb6c1,lightsalmon:ffa07a,lightseagreen:20b2aa,lightskyblue:87cefa,lightslategray:778899,lightslategrey:778899,lightsteelblue:b0c4de,lightyellow:ffffe0,lime:00ff00,limegreen:32cd32,linen:faf0e6,magenta:ff00ff,maroon:800000,mediumaquamarine:66cdaa,mediumblue:0000cd,mediumorchid:ba55d3,mediumpurple:9370db,mediumseagreen:3cb371,mediumslateblue:7b68ee,mediumspringgreen:00fa9a,mediumturquoise:48d1cc,mediumvioletred:c71585,midnightblue:191970,mintcream:f5fffa,mistyrose:ffe4e1,moccasin:ffe4b5,navajowhite:ffdead,navy:000080,oldlace:fdf5e6,olive:808000,olivedrab:6b8e23,orange:ffa500,orangered:ff4500,orchid:da70d6,palegoldenrod:eee8aa,palegreen:98fb98,paleturquoise:afeeee,palevioletred:db7093,papayawhip:ffefd5,peachpuff:ffdab9,peru:cd853f,pink:ffc0cb,plum:dda0dd,powderblue:b0e0e6,purple:800080,rebeccapurple:663399,red:ff0000,rosybrown:bc8f8f,royalblue:4169e1,saddlebrown:8b4513,salmon:fa8072,sandybrown:f4a460,seagreen:2e8b57,seashell:fff5ee,sienna:a0522d,silver:c0c0c0,skyblue:87ceeb,slateblue:6a5acd,slategray:708090,slategrey:708090,snow:fffafa,springgreen:00ff7f,steelblue:4682b4,tan:d2b48c,teal:008080,thistle:d8bfd8,tomato:ff6347,turquoise:40e0d0,violet:ee82ee,wheat:f5deb3,white:ffffff,whitesmoke:f5f5f5,yellow:ffff00,yellowgreen:9acd32'
      .split(',').map((pair) => pair.split(':')));

    // A color as [r, g, b, alpha], sRGB 0-1, or null when it isn't a plain color (a keyword like
    // currentcolor, a var(), a system color: those are left as written).
    const hex = (h) => {
      if (!/^[0-9a-f]+$/.test(h)) return null;
      if (h.length === 3 || h.length === 4) h = h.split('').map((c) => c + c).join('');
      if (h.length !== 6 && h.length !== 8) return null;
      const n = (i) => parseInt(h.slice(i, i + 2), 16) / 255;
      return [n(0), n(2), n(4), h.length === 8 ? n(6) : 1];
    };
    const channel = (v, scale) => v.endsWith('%') ? parseFloat(v) / 100 : parseFloat(v) / scale;
    const rgbFunction = (s) => {
      const m = /^rgba?\(([^()]*)\)$/.exec(s);
      if (!m) return null;
      const parts = m[1].split(/[\s,/]+/).filter(Boolean);
      if (parts.length < 3 || parts.length > 4 || parts.some((p) => !/^[\d.+-]+(e[\d+-]+)?%?$/.test(p))) return null;
      return [channel(parts[0], 255), channel(parts[1], 255), channel(parts[2], 255), parts[3] === undefined ? 1 : channel(parts[3], 1)];
    };
    // Display P3 into sRGB (linear), for colors the canvas reports as color(display-p3 ...).
    const lin = (c) => c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    const gam = (c) => c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
    const fromP3 = (r, g, b, a) => {
      r = lin(r); g = lin(g); b = lin(b);
      const out = [1.2249 * r - 0.2247 * g, -0.0420 * r + 1.0419 * g, -0.0197 * r - 0.0786 * g + 1.0979 * b];
      return [...out.map((c) => gam(Math.min(1, Math.max(0, c)))), a];
    };
    let ctx2d = null;
    // Any other color syntax (hsl, hwb, lab, oklch, color(), color-mix of plain colors) goes
    // through a canvas, which resolves every color the engine knows. Invalid input leaves the
    // canvas's previous color, which two different starting colors expose.
    const viaCanvas = (s) => {
      try {
        if (!ctx2d) ctx2d = new OffscreenCanvas(1, 1).getContext('2d');
        ctx2d.fillStyle = '#000'; ctx2d.fillStyle = s; const a = ctx2d.fillStyle;
        ctx2d.fillStyle = '#fff'; ctx2d.fillStyle = s; const b = ctx2d.fillStyle;
        if (a !== b) return null;
        if (a[0] === '#') return hex(a.slice(1));
        const p3 = /^color\((srgb|display-p3) ([\d.e+-]+) ([\d.e+-]+) ([\d.e+-]+)(?: \/ ([\d.e+-]+))?\)$/.exec(a);
        if (p3) {
          const alpha = p3[5] === undefined ? 1 : parseFloat(p3[5]);
          const [r, g, b2] = [parseFloat(p3[2]), parseFloat(p3[3]), parseFloat(p3[4])];
          return p3[1] === 'srgb' ? [r, g, b2, alpha] : fromP3(r, g, b2, alpha);
        }
        return rgbFunction(a);
      } catch (e) { return null; }
    };
    const colorCache = new Map();
    const parseColor = (raw) => {
      let c = colorCache.get(raw);
      if (c !== undefined) return c;
      const s = raw.trim().toLowerCase();
      c = null;
      if (s === 'transparent') c = [0, 0, 0, 0];
      else if (s[0] === '#') c = hex(s.slice(1));
      else if (NAMED.has(s)) c = hex(NAMED.get(s));
      else if (/^(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color|color-mix)\(/.test(s) && !/var\(|env\(|attr\(|currentcolor|\bfrom\b|light-dark/.test(s)) {
        c = rgbFunction(s) || viaCanvas(s);
      }
      if (colorCache.size > 8000) colorCache.clear();
      colorCache.set(raw, c);
      return c;
    };

    // OKLab (Björn Ottosson), from and to linear sRGB.
    const toLab = (c) => {
      const r = lin(c[0]), g = lin(c[1]), b = lin(c[2]);
      const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
      const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
      const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
      return [0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
              1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
              0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s];
    };
    const labToLinear = (L, A, B) => {
      const l = Math.pow(L + 0.3963377774 * A + 0.2158037573 * B, 3);
      const m = Math.pow(L - 0.1055613458 * A - 0.0638541728 * B, 3);
      const s = Math.pow(L - 0.0894841775 * A - 1.2914855480 * B, 3);
      return [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
              -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
              -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s];
    };
    const inGamut = (v) => v[0] >= -1e-4 && v[0] <= 1.0001 && v[1] >= -1e-4 && v[1] <= 1.0001 && v[2] >= -1e-4 && v[2] <= 1.0001;
    // Lightness L with the hue of (A, B) and as much of its chroma as sRGB can show.
    const fromLab = (L, A, B) => {
      let v = labToLinear(L, A, B);
      if (!inGamut(v)) {
        let lo = 0, hi = 1;
        for (let i = 0; i < 10; i++) { const k = (lo + hi) / 2; if (inGamut(labToLinear(L, A * k, B * k))) lo = k; else hi = k; }
        v = labToLinear(L, A * lo, B * lo);
      }
      return v.map((x) => gam(Math.min(1, Math.max(0, x))));
    };
    // The lightness curves for each role (b background, f text and icons, d borders). Each is
    // continuous and leaves its own side alone, so applying it twice changes nothing.
    const curve = {
      b: (L) => L > BG_T ? BG_T - (L - BG_T) * (BG_T - BG_L) / (1 - BG_T) : L,
      f: (L) => L < FG_T ? FG_L - L * (FG_L - FG_T) / FG_T : L,
      d: (L) => L > BD_T ? BD_T - (L - BD_T) * (BD_T - BD_L) / (1 - BD_T) : L,
    };
    // g: SVG fill and stroke. Greys are icons drawn like text and flip with it; colored paints
    // are logos and illustrations and keep their colors (Safari changes SVG colors only where an
    // icon would lose contrast).
    const chroma = (c) => Math.max(c[0], c[1], c[2]) - Math.min(c[0], c[1], c[2]);
    const mapRGBA = (role, c) => {
      if (c[3] === 0) return c;
      if (role === 'g') { if (chroma(c) >= SVG_CHROMA) return c; role = 'f'; }
      const lab = toLab(c);
      const L = curve[role](lab[0]);
      if (Math.abs(L - lab[0]) < 0.004) return c;
      const rgb = fromLab(L, lab[1], lab[2]);
      return [rgb[0], rgb[1], rgb[2], c[3]];
    };
    const css = (c) => {
      const r = Math.round(c[0] * 255), g = Math.round(c[1] * 255), b = Math.round(c[2] * 255);
      return c[3] >= 0.999 ? `rgb(${r}, ${g}, ${b})` : `rgba(${r}, ${g}, ${b}, ${Math.round(c[3] * 1000) / 1000})`;
    };
    const mapCache = new Map();
    // The color string for `role`: the same string when it stays, null when it isn't a color.
    const mapColor = (role, s) => {
      const key = role + s;
      let out = mapCache.get(key);
      if (out !== undefined) return out;
      const c = parseColor(s);
      if (!c) out = null;
      else { const m = mapRGBA(role, c); out = m === c ? s : css(m); }
      if (mapCache.size > 8000) mapCache.clear();
      mapCache.set(key, out);
      return out;
    };
    const luminance = (c) => 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2]);
    const contrast = (a, b) => { const x = luminance(a) + 0.05, y = luminance(b) + 0.05; return x > y ? x / y : y / x; };
    const over = (c, base) => c[3] >= 1 ? c : [0, 1, 2].map((i) => c[i] * c[3] + base[i] * (1 - c[3])).concat(1);
    // The page's own dark: what white turns into.
    const PAGE_BG = fromLab(BG_L, 0, 0).concat(1);
    const PAGE_BG_CSS = css(PAGE_BG);

    // MARK: Rewriting values

    // Color variables: name -> 1 (a color, or a value with colors in it) or 2 (bare RGB channels,
    // used as rgb(var(--x))). Learned from definitions in style sheets and inline styles.
    const kinds = new Map();
    let kindsVersion = 0;
    const roleVar = (role, name) => '--plain-' + role + name.slice(1);
    const closing = (s, i) => {
      let depth = 0, quote = '';
      for (; i < s.length; i++) {
        const ch = s[i];
        if (quote) { if (ch === '\\') i++; else if (ch === quote) quote = ''; continue; }
        if (ch === '"' || ch === "'") quote = ch;
        else if (ch === '(') depth++;
        else if (ch === ')' && --depth === 0) return i;
      }
      return -1;
    };
    const COLOR_FUNCTION = /^(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color|color-mix)$/;
    const IDENT_START = /[a-zA-Z_-]/, IDENT = /[\w-]/, HEX = /[0-9a-fA-F]/;
    // Rewrites every color in a CSS value for `role`: plain colors, colors inside gradients and
    // shadows, and color variables (pointed at the role's twin, the original as fallback).
    // `ctx.unknown` collects variables used here that aren't known colors yet; `ctx.found` is set
    // when the value holds a color at all.
    // Values without variables repeat across a site's rules (the same few colors thousands of
    // times), so their rewrites are kept.
    const scanCache = new Map();
    const scan = (v, role, ctx) => {
      if (v.includes('var(')) return scanValue(v, role, ctx);
      const key = role + v;
      let hit = scanCache.get(key);
      if (hit === undefined) {
        const probe = { found: false };
        hit = [scanValue(v, role, probe), probe.found];
        if (scanCache.size > 20000) scanCache.clear();
        scanCache.set(key, hit);
      }
      if (hit[1] && ctx) ctx.found = true;
      return hit[0];
    };
    const scanValue = (v, role, ctx) => {
      let out = '';
      let i = 0;
      const n = v.length;
      while (i < n) {
        const ch = v[i];
        if (ch === '#') {
          let j = i + 1;
          while (j < n && HEX.test(v[j])) j++;
          const token = v.slice(i, j);
          const mapped = j - i === 4 || j - i === 5 || j - i === 7 || j - i === 9 ? mapColor(role, token) : null;
          if (mapped !== null && ctx) ctx.found = true;
          out += mapped === null ? token : mapped;
          i = j;
          continue;
        }
        if (IDENT_START.test(ch) && (i === 0 || !IDENT.test(v[i - 1]))) {
          let j = i;
          while (j < n && IDENT.test(v[j])) j++;
          const word = v.slice(i, j);
          const lower = word.toLowerCase();
          if (v[j] === '(') {
            const end = closing(v, j);
            if (end < 0) { out += v.slice(i); break; }
            const inner = v.slice(j + 1, end);
            if (lower === 'url') out += v.slice(i, end + 1);
            else if (lower === 'var') out += variable(inner, role, ctx);
            else if (COLOR_FUNCTION.test(lower) && !inner.includes('var(')) {
              const mapped = mapColor(role, v.slice(i, end + 1));
              if (mapped !== null && ctx) ctx.found = true;
              out += mapped === null ? word + '(' + scan(inner, role, ctx) + ')' : mapped;
            } else out += word + '(' + scan(inner, role, ctx) + ')';
            i = end + 1;
            continue;
          }
          if (NAMED.has(lower)) {
            const mapped = mapColor(role, lower);
            if (ctx) ctx.found = true;
            out += mapped === lower ? word : mapped;
          } else out += word;
          i = j;
          continue;
        }
        out += ch;
        i++;
      }
      return out;
    };
    const variable = (inner, role, ctx) => {
      const comma = inner.indexOf(',');
      const name = (comma < 0 ? inner : inner.slice(0, comma)).trim();
      const fallback = comma < 0 ? null : scan(inner.slice(comma + 1), role, ctx);
      const original = 'var(' + name + (fallback === null ? '' : ',' + fallback) + ')';
      if (!name.startsWith('--')) return original;
      // SVG paints through variables keep the site's value: a logo's colors must not move, and a
      // grey icon that would vanish is caught by the element pass.
      if (role === 'g') return original;
      if (kinds.has(name)) { if (ctx) ctx.found = true; return 'var(' + roleVar(role, name) + ', ' + original + ')'; }
      if (ctx && ctx.unknown) ctx.unknown.add(name);
      return original;
    };
    const TRIPLE = /^\s*([\d.]+%?)(\s*,\s*|\s+)([\d.]+%?)(\s*,\s*|\s+)([\d.]+%?)\s*$/;
    const mapTriple = (role, v) => {
      const m = TRIPLE.exec(v);
      if (!m) return v;
      const c = [channel(m[1], 255), channel(m[3], 255), channel(m[5], 255), 1];
      const o = mapRGBA(role, c);
      if (o === c) return v;
      return [o[0], o[1], o[2]].map((x) => Math.round(x * 255)).join(m[2].includes(',') ? ', ' : ' ');
    };
    // What a custom property's value is: 1 a color (or holds colors), 2 RGB channels, 0 neither,
    // -1 an alias of a variable not known yet.
    const kindOf = (v, ctx) => {
      const t = v.trim();
      if (!t) return 0;
      if (TRIPLE.test(t)) return 2;
      const alias = /^var\(\s*(--[\w-]+)\s*\)$/.exec(t);
      if (alias) {
        if (kinds.has(alias[1])) return kinds.get(alias[1]);
        if (ctx && ctx.unknown) ctx.unknown.add(alias[1]);
        return -1;
      }
      if (parseColor(t)) return 1;
      const probe = { found: false };
      scan(t, 'b', probe);
      return probe.found ? 3 : 0;
    };
    const learn = (name, v, ctx) => {
      if (kinds.has(name)) return;
      const k = kindOf(v, ctx);
      if (k > 0) { kinds.set(name, k); kindsVersion++; }
    };
    const absolute = (v, base) => v.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/g, (m, q, u) => {
      if (/^(data:|https?:|blob:|#)/i.test(u)) return m;
      try { return 'url("' + new URL(u, base).href + '")'; } catch (e) { return m; }
    });

    const ROLES = new Map([
      ['color', 'f'], ['-webkit-text-fill-color', 'f'], ['-webkit-text-stroke-color', 'f'], ['caret-color', 'f'],
      ['text-decoration-color', 'f'], ['text-emphasis-color', 'f'], ['-webkit-text-emphasis-color', 'f'],
      ['fill', 'g'], ['stroke', 'g'],
      ['background-color', 'b'], ['background-image', 'b'], ['box-shadow', 'b'], ['text-shadow', 'b'],
      ['outline-color', 'd'], ['column-rule-color', 'd'],
    ]);
    const roleOf = (p) => ROLES.get(p) || (p.startsWith('border') && p.endsWith('-color') ? 'd' : null);
    // Shorthands and the color longhands they set. Twins never repeat a shorthand: it would also
    // reset widths, styles and pictures that a later rule of the page may set.
    const LONGHANDS = {
      'background': ['background-color', 'background-image'],
      'border': ['border-top-color', 'border-right-color', 'border-bottom-color', 'border-left-color'],
      'border-top': ['border-top-color'], 'border-right': ['border-right-color'],
      'border-bottom': ['border-bottom-color'], 'border-left': ['border-left-color'],
      'border-block': ['border-block-start-color', 'border-block-end-color'],
      'border-inline': ['border-inline-start-color', 'border-inline-end-color'],
      'border-block-start': ['border-block-start-color'], 'border-block-end': ['border-block-end-color'],
      'border-inline-start': ['border-inline-start-color'], 'border-inline-end': ['border-inline-end-color'],
      'outline': ['outline-color'], 'column-rule': ['column-rule-color'],
      'text-decoration': ['text-decoration-color'], '-webkit-text-stroke': ['-webkit-text-stroke-color'],
      'text-emphasis': ['text-emphasis-color'], '-webkit-text-emphasis': ['-webkit-text-emphasis-color'],
    };
    const shorthandRole = (p) => p === 'background' ? 'b' : p.includes('text') ? 'f' : 'd';
    // The first color in a value (a literal or a variable), for a shorthand whose longhands are
    // left empty by a var() until computed.
    const firstColor = (v) => {
      const re = /var\(\s*--[\w-]+[^()]*(?:\([^()]*\)[^()]*)*\)|#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^()]*\)|\b[a-zA-Z]+\b/g;
      let m;
      while ((m = re.exec(v))) {
        const t = m[0];
        if (t.startsWith('var(')) { const name = /--[\w-]+/.exec(t)[0]; if (kinds.get(name) === 1) return t; continue; }
        if (parseColor(t)) return t;
      }
      return null;
    };
    // A style block's declarations, read in one call: [property, value, important].
    const parseDeclarations = (text) => {
      const out = [];
      let start = 0, depth = 0, quote = '';
      for (let i = 0; i <= text.length; i++) {
        const ch = text[i];
        if (quote) { if (ch === '\\') i++; else if (ch === quote) quote = ''; continue; }
        if (ch === '"' || ch === "'") quote = ch;
        else if (ch === '(') depth++;
        else if (ch === ')') depth--;
        else if ((ch === ';' && depth <= 0) || i === text.length) {
          const d = text.slice(start, i);
          start = i + 1;
          const colon = d.indexOf(':');
          if (colon < 0) continue;
          let prop = d.slice(0, colon).trim();
          let value = d.slice(colon + 1).trim();
          let important = false;
          const bang = value.lastIndexOf('!');
          if (bang >= 0 && /^!\s*important$/i.test(value.slice(bang))) { important = true; value = value.slice(0, bang).trim(); }
          if (!prop.startsWith('--')) prop = prop.toLowerCase();
          out.push([prop, value, important]);
        }
      }
      return out;
    };
    const ROLE_HINT = /color|background|border|outline|fill|stroke|shadow|--|text-decoration|column-rule|emphasis/;
    // A background that draws text (background-clip: text) or an icon (a mask) plays the role of
    // text: it must turn light, not dark.
    const drawsForeground = (list) => list.some(([p, v]) =>
      ((p === 'background-clip' || p === '-webkit-background-clip') && v.includes('text'))
      || ((p === 'mask-image' || p === '-webkit-mask-image' || p === 'mask' || p === '-webkit-mask') && v !== 'none' && !v.startsWith('linear-gradient')));
    const NONE = { out: '', emit: false };
    let schemeDark = false;
    const rootRule = (r) => {
      try {
        return document.documentElement.matches(r.selectorText) || (!!document.body && document.body.matches(r.selectorText));
      } catch (e) { return false; }
    };

    // The rewritten declarations of one style block: { out, emit }. Every color declaration is
    // repeated (unchanged ones too), so twins compete with each other exactly as the originals
    // do: a dark card's rule still wins over the light card rule it overrides.
    const declarations = (st, ctx, force) => {
      const text = st.cssText;
      if (!text || !ROLE_HINT.test(text)) return NONE;
      const list = parseDeclarations(text);
      let out = '';
      let emit = false;
      let changed = false;
      let foreground = null;
      const write = (prop, value, important, role) => {
        let v = scan(value, role, ctx);
        if (v !== value) changed = true;
        if (ctx.base && v.includes('url(')) v = absolute(v, ctx.base);
        const bang = force || important ? ' !important' : '';
        out += prop + ':' + v + bang + ';';
        // The site's own text and background colors travel with the twins' (custom properties
        // inherit like color does), so the judgement and text over pictures can read them.
        if (prop === 'color') out += '--plain-o-color:' + value + bang + ';';
        else if (prop === 'background-color' && role === 'b') out += '--plain-o-bg:' + value + bang + ';';
      };
      for (const [p, v, important] of list) {
        if (p.charCodeAt(0) === 45 && p.charCodeAt(1) === 45) {
          learn(p, v, ctx);
          const kind = kinds.get(p);
          if (!kind) continue;
          for (const role of 'bfd') {
            let value = kind === 2 ? mapTriple(role, v) : scan(v, role, ctx);
            if (ctx.base && value.includes('url(')) value = absolute(value, ctx.base);
            out += roleVar(role, p) + ':' + value + (force || important ? ' !important' : '') + ';';
          }
          emit = true;
          changed = true;
          continue;
        }
        if (p === 'color-scheme') {
          // A dark color-scheme on the root or body is a dark design of the site's own.
          if (/\b(dark|only)\b/.test(v) && ctx.rule && rootRule(ctx.rule)) schemeDark = true;
          continue;
        }
        const longhands = LONGHANDS[p];
        let role = longhands ? shorthandRole(p) : roleOf(p);
        if (!role) continue;
        if (role === 'b' && p !== 'box-shadow' && p !== 'text-shadow') {
          if (foreground === null) foreground = drawsForeground(list);
          if (foreground) role = 'f';
        }
        emit = true;
        if (!longhands) { write(p, v, important, role); continue; }
        let any = false;
        for (const longhand of longhands) {
          const value = st.getPropertyValue(longhand);
          if (!value) continue;
          any = true;
          write(longhand, value, important, role);
        }
        if (!any) {
          const color = firstColor(v);
          if (color) {
            for (const longhand of longhands) if (longhand !== 'background-image') write(longhand, color, important, role);
            continue;
          }
          // One variable holding a gradient: a background gets it as its picture. (A variable
          // holding a whole border is left: repeating the shorthand would reset widths a later
          // rule sets.)
          const only = /^var\(\s*(--[\w-]+)\s*(?:,[^]*)?\)$/.exec(v.trim());
          if (p === 'background' && only && kinds.get(only[1]) === 3) write('background-image', v, important, role);
        }
      }
      return { out, emit, changed };
    };

    const kindOfRule = (r) => Object.prototype.toString.call(r).slice(8, -1);
    // The twin of a list of rules: only rules with colors, in the same order and the same
    // conditions, so the cascade works as the site wrote it.
    const rewriteRules = (rules, ctx) => {
      let out = '';
      for (let i = 0; i < rules.length; i++) {
        const r = rules[i];
        ctx.count++;
        if (r.type === 1) {
          ctx.rule = r;
          const d = r.style.length ? declarations(r.style, ctx, false) : null;
          const nested = r.cssRules && r.cssRules.length ? rewriteRules(r.cssRules, ctx) : '';
          if ((d && d.emit) || nested) out += r.selectorText + '{' + (d && d.emit ? d.out : '') + nested + '}';
          continue;
        }
        let head = null;
        let inner = null;
        switch (r.type) {
          case 3: { // @import
            let sub = null;
            try { sub = r.styleSheet && r.styleSheet.cssRules; } catch (e) { stats.unreadable++; }
            if (!sub) continue;
            const base = ctx.base;
            ctx.base = r.styleSheet.href || base;
            inner = rewriteRules(sub, ctx);
            ctx.base = base;
            const media = r.media && r.media.mediaText;
            if (inner && media && media !== 'all') inner = '@media ' + media + '{' + inner + '}';
            if (inner && r.layerName) inner = '@layer ' + r.layerName + '{' + inner + '}';
            out += inner;
            continue;
          }
          case 4: if (r.media.mediaText === 'print') continue; head = '@media ' + r.media.mediaText; break;
          case 12: head = '@supports ' + r.conditionText; break;
          case 7: out += keyframes(r, ctx); continue;
          default: {
            const kind = kindOfRule(r);
            if (kind === 'CSSLayerBlockRule') head = '@layer' + (r.name ? ' ' + r.name : '');
            else if (kind === 'CSSContainerRule') head = '@container ' + (r.containerName ? r.containerName + ' ' : '') + (r.containerQuery || r.conditionText);
            else if (kind === 'CSSScopeRule') head = '@scope' + (r.start ? ' (' + r.start + ')' : '') + (r.end ? ' to (' + r.end + ')' : '');
            else if (kind === 'CSSStartingStyleRule') head = '@starting-style';
            else if (kind === 'CSSNestedDeclarations') {
              const d = declarations(r.style, ctx, false);
              if (d.emit) out += d.out;
              continue;
            } else continue;
          }
        }
        inner = r.cssRules ? rewriteRules(r.cssRules, ctx) : '';
        if (inner) out += head ? head + '{' + inner + '}' : inner;
      }
      return out;
    };
    // Keyframes are replaced whole by a later @keyframes of the same name, so a twin copies every
    // declaration, with its colors rewritten.
    const keyframes = (r, ctx) => {
      let changed = false;
      let body = '';
      for (const frame of r.cssRules) {
        const st = frame.style;
        let decls = '';
        for (let i = 0; i < st.length; i++) {
          const p = st[i];
          const v = st.getPropertyValue(p);
          const role = roleOf(p);
          const value = role ? scan(v, role, ctx) : v;
          if (value !== v) changed = true;
          decls += p + ':' + value + ';';
        }
        body += frame.keyText + '{' + decls + '}';
      }
      return changed ? '@keyframes ' + CSS.escape(r.name) + '{' + body + '}' : '';
    };

    // MARK: Style sheets

    const ours = new WeakSet();
    const sheet = (css) => { const s = new CSSStyleSheet(); s.replaceSync(css); s.disabled = true; ours.add(s); return s; };
    const guard = sheet(`html, body { background-color: ${PAGE_BG_CSS} !important; }`);
    // The page's dark scheme, and a frame's default border (the browser's own bevel, drawn from
    // the now light text color) in the darkened border grey; a border the site sets wins.
    const BASE = ':root { color-scheme: dark !important; } :where(iframe, frame) { border-color: '
      + css(mapRGBA('d', [0.75, 0.75, 0.75, 1])) + '; }';
    const BASE_RULES = 2;
    const base = sheet(BASE);
    const patch = sheet('');
    const twins = new Map(); // a page style sheet -> { sheet, signature, unknown, version }
    let order = [];          // the twins in the page's order
    const fetched = new Map(); // address -> { state, sheet } for sheets another origin served
    let enabled = false;

    // WebKit answers null for another origin's rules (other engines throw).
    const rulesOf = (s) => {
      try { const rules = s.cssRules; if (rules) return rules; } catch (e) {}
      const f = s.href && fetched.get(s.href);
      if (f) return f.state === 'done' ? f.sheet.cssRules : null;
      if (s.href) fetchSheet(s.href);
      return null;
    };
    // A sheet from another origin can't be read in place. The page's own fetch reads it again
    // (from the HTTP cache, usually) when the server allows it (CORS); otherwise the elements it
    // styles are fixed one by one.
    const fetchSheet = (href) => {
      fetched.set(href, { state: 'pending' });
      fetch(href, { mode: 'cors', credentials: 'omit' })
        .then((r) => r.ok ? r.text() : Promise.reject(new Error('status')))
        .then((text) => { const s = new CSSStyleSheet(); return s.replace(text).then(() => s); })
        .then((s) => { fetched.set(href, { state: 'done', sheet: s }); stats.fetched++; later(); },
              () => {
                fetched.set(href, { state: 'failed' });
                // From now on the element pass also reads borders and pseudo-elements, which
                // that sheet may color: the page gets another walk.
                if (!stats.unreadable++ && built) rewalk();
              });
    };
    // What tells a changed sheet: its rule count, media, and the shape of its first and last
    // rules (a sheet replaced whole, a <style> given new text). Cheap reads only: never the
    // cssText of a block rule, which serializes everything inside it.
    const shape = (r) => r.type === 1 ? r.selectorText.length + '.' + r.style.length : r.type + '.' + (r.cssRules ? r.cssRules.length : 0);
    const signature = (s, rules) => {
      const n = rules.length;
      return n + '|' + (s.media ? s.media.mediaText : '') + '|' + (n ? shape(rules[0]) + ':' + shape(rules[n - 1]) : '')
        + '|' + (s.ownerNode && s.ownerNode.localName === 'style' ? s.ownerNode.textContent.length : '');
    };
    // The page's sheets in one scope: the document, or an open shadow root (web components keep
    // their styles there, out of the document's reach).
    const pageSheets = (scope = document) => {
      const list = [];
      for (const s of scope.styleSheets) if (!s.disabled) list.push(s);
      for (const s of scope.adoptedStyleSheets) if (!ours.has(s) && !s.disabled) list.push(s);
      return list;
    };
    // Open shadow roots found on the page, each with its twins in its sheets' order. Plain's
    // patch sheet goes into each too, so element fixes reach inside.
    const shadowRoots = new Map(); // root -> [twin sheets]
    const scopes = () => {
      const list = [document];
      for (const root of shadowRoots.keys()) {
        if (root.host.isConnected) list.push(root); else shadowRoots.delete(root);
      }
      return list;
    };
    const twinFor = (s, rules) => {
      const ctx = { base: s.href || null, unknown: new Set(), count: 0 };
      let text = rewriteRules(rules, ctx);
      const media = s.media && s.media.mediaText;
      if (text && media && media !== 'all') text = '@media ' + media + '{' + text + '}';
      let twin = twins.get(s);
      if (!twin) { twin = { sheet: sheet('') }; twin.sheet.disabled = !enabled; twins.set(s, twin); }
      try { twin.sheet.replaceSync(text); } catch (e) { twin.sheet.replaceSync(''); }
      twin.signature = signature(s, rules);
      twin.unknown = ctx.unknown;
      twin.version = kindsVersion;
      stats.rules += ctx.count;
      stats.emitted += twin.sheet.cssRules.length;
      return twin;
    };
    // Brings every twin in line with the page's sheets: new and changed sheets are rewritten,
    // removed ones dropped. Variables first seen in a later sheet send the sheets that used them
    // round again (twice at most: aliases of aliases).
    // `budget` (ms) bounds the work after the first frame: sheets past it wait for the next
    // batch, one sheet at a time (a sheet is rewritten whole).
    // The twins of one scope's sheets, new and changed ones rewritten: [sheet, twin, rules].
    const syncScope = (scope, deadline, done) => {
      const live = [];
      for (const s of pageSheets(scope)) {
        const rules = rulesOf(s);
        if (!rules) continue;
        let twin = twins.get(s);
        // A sheet shared by many shadow roots (one per component class) is rewritten once.
        if (!done.has(s) && (!twin || twin.signature !== signature(s, rules))) {
          if (now() > deadline) { sheetsDirty = true; later(); if (twin) live.push([s, twin, rules]); continue; }
          twin = twinFor(s, rules);
        }
        done.add(s);
        live.push([s, twin, rules]);
      }
      return live;
    };
    const syncSheets = (budget = Infinity, only = null) => {
      const deadline = now() + budget;
      const html = document.documentElement;
      if (!only && html && html.style.length) declarations(html.style, { base: null, unknown: null }, true);
      const done = new Set();
      const all = [];
      const perScope = [];
      for (const scope of only ? [only] : scopes()) {
        const live = syncScope(scope, deadline, done);
        perScope.push([scope, live]);
        all.push(...live);
      }
      const live = all;
      for (let round = 0; round < 2; round++) {
        let again = false;
        for (const [s, twin, rules] of live) {
          if (twin.version === kindsVersion) continue;
          let stale = false;
          for (const name of twin.unknown) if (kinds.has(name)) { stale = true; break; }
          if (!stale) { twin.version = kindsVersion; continue; }
          if (now() > deadline) { sheetsDirty = true; later(); continue; }
          twinFor(s, rules);
          again = true;
        }
        if (!again) break;
      }
      for (const [scope, list] of perScope) {
        const sheets = list.map(([, twin]) => twin.sheet);
        if (scope === document) order = sheets; else shadowRoots.set(scope, sheets);
      }
      if (only) { adoptScope(only); return; }
      const keep = new Set(live.map(([s]) => s));
      for (const s of [...twins.keys()]) if (!keep.has(s)) twins.delete(s);
      adopt();
    };
    const sheetsChanged = () => {
      for (const scope of scopes()) {
        let count = 0;
        for (const s of pageSheets(scope)) {
          const known = s.href && fetched.get(s.href);
          let rules = null;
          try { rules = s.cssRules; } catch (e) {}
          if (!rules && known) rules = known.state === 'done' ? known.sheet.cssRules : null;
          if (!rules) { if (s.href && !known) return true; continue; }
          count++;
          const twin = twins.get(s);
          if (!twin || twin.signature !== signature(s, rules)) return true;
        }
        if (count !== (scope === document ? order : shadowRoots.get(scope)).length) return true;
      }
      return false;
    };
    // Plain's sheets sit after the page's own, in a fixed order; puts them back if the page
    // replaced its adopted style sheets.
    let adopted = false;
    const adoptScope = (scope) => {
      const want = scope === document ? [base, ...order, patch, guard] : [...(shadowRoots.get(scope) || []), patch];
      const list = scope.adoptedStyleSheets;
      const tail = list.slice(list.length - want.length);
      if (tail.length === want.length && tail.every((s, i) => s === want[i])) return;
      scope.adoptedStyleSheets = [...list.filter((s) => !ours.has(s)), ...want];
    };
    const adopt = () => {
      for (const scope of scopes()) adoptScope(scope);
      adopted = true;
    };
    // A shadow root met on the walk: its sheets get twins now, before its elements are read,
    // within what is left of the walk's budget (at least 1 ms; sheets past it wait for the next
    // batch, and their elements are fixed one by one meanwhile), and its changes are watched
    // like the document's.
    const addRoot = (root, deadline) => {
      shadowRoots.set(root, []);
      if (now() < deadline) timed(() => syncSheets(deadline - now(), root), 'rewriteMs');
      else { adoptScope(root); sheetsDirty = true; later(); }
      if (observer) observer.observe(root, OBSERVED);
      stats.shadowRoots++;
    };
    // Every element fix off, in the document and in each shadow root.
    const clearMarks = () => {
      for (const scope of scopes()) for (const el of scope.querySelectorAll('[' + ATTR + ']')) el.removeAttribute(ATTR);
    };
    // An element's descendants, through the open shadow roots below it.
    const below = (el) => {
      const out = [];
      const add = (list) => { for (const d of list) out.push(d); };
      if (el.shadowRoot && shadowRoots.has(el.shadowRoot)) add(el.shadowRoot.querySelectorAll('*'));
      add(el.getElementsByTagName('*'));
      // Every host found on the way adds its shadow tree, nested ones included.
      for (let i = 0; i < out.length; i++) {
        const shadow = out[i].shadowRoot;
        if (shadow && shadowRoots.has(shadow)) add(shadow.querySelectorAll('*'));
      }
      return out;
    };
    // Custom elements whose shadow root may come later (defined after they were walked).
    const pendingHosts = new Set();
    const checkHosts = () => {
      // One slice for all of them: a burst of upgraded components never holds a frame.
      const deadline = now() + SLICE_MS;
      for (const host of pendingHosts) {
        if (!host.isConnected) { pendingHosts.delete(host); continue; }
        const root = host.shadowRoot;
        if (!root) continue;
        pendingHosts.delete(host);
        if (shadowRoots.has(root) || !info.has(host)) continue;
        addRoot(root, deadline);
        queue.push(root);
      }
      if (queue.length) pump();
    };
    let rewalkNeeded = false;
    const setEnabled = (on) => {
      if (!on && enabled && built) rewalkNeeded = true;
      if (!on) logoGeneration++;
      enabled = on;
      base.disabled = !on;
      patch.disabled = !on;
      for (const twin of twins.values()) twin.sheet.disabled = !on;
    };

    // MARK: Elements the sheets can't reach

    const tokens = new Map();
    let tokenCount = 0;
    const token = (decls, pseudo = '') => {
      const key = pseudo + decls;
      let t = tokens.get(key);
      if (!t) {
        t = 'p' + (++tokenCount).toString(36);
        tokens.set(key, t);
        // Two :not(#id) lift it over the page's own !important rules of usual specificity. Added
        // with the attributes at the end of a slice: a rule added mid-slice would make the next
        // style read restyle the whole page.
        newRules.push(`[${ATTR}~="${t}"]:not(#_pd):not(#_pd)${pseudo}{${decls}}`);
      }
      return t;
    };
    let newRules = [];
    const SKIP = new Set(['script', 'style', 'link', 'meta', 'head', 'title', 'noscript', 'template', 'img', 'video',
      'canvas', 'iframe', 'frame', 'embed', 'object', 'picture', 'audio', 'source', 'track', 'br', 'wbr', 'math']);
    const SIDES = ['Top', 'Right', 'Bottom', 'Left'];
    const hasText = (el) => {
      for (let n = el.firstChild; n; n = n.nextSibling) if (n.nodeType === 3 && /\S/.test(n.data)) return true;
      return false;
    };
    let writes = [];
    const write = () => {
      for (const rule of newRules) { try { patch.insertRule(rule, patch.cssRules.length); } catch (e) {} }
      newRules = [];
      for (const [el, value] of writes) {
        // A second walk reads colors with the earlier fixes in place: keep those, add the new.
        const before = el.getAttribute(ATTR);
        el.setAttribute(ATTR, before ? [...new Set((before + ' ' + value).split(' '))].join(' ') : value);
      }
      stats.patched += writes.length;
      writes = [];
    };
    // The lightest (or darkest) version of a text color that reaches the contrast target on `bg`.
    const readable = (c, bg) => {
      const lab = toLab(c);
      const up = luminance(bg) < 0.18;
      let lo = lab[0], hi = up ? 1 : 0;
      const target = (L) => contrast(fromLab(L, lab[1], lab[2]), bg) >= MIN_CONTRAST + 0.05;
      if (!target(hi)) return fromLab(hi, 0, 0).concat(1);
      for (let i = 0; i < 12; i++) { const mid = (lo + hi) / 2; if (target(mid)) hi = mid; else lo = mid; }
      return fromLab(hi, lab[1], lab[2]).concat(1);
    };
    const inlineContext = { base: null, unknown: null };

    // Checks one element with its parent's information ({ bg: opaque color behind it, image:
    // whether a picture is behind it }) and returns its own, or null to skip its subtree.
    const check = (el, up) => {
      const tag = el.localName;
      if (tag === 'img') { if (up.darkened && !up.image) logo(el, up.bg, null); return null; }
      if (tag === 'picture') return up;
      if (SKIP.has(tag)) return null;
      if (tag === 'svg') { icon(el, up); return null; }
      stats.checked++;
      const cs = getComputedStyle(el);
      if (cs.display === 'none') return null;
      const decls = [];
      let inline = '';
      if (el.hasAttribute('style') && el.style.length) {
        const d = declarations(el.style, inlineContext, true);
        if (d.changed) { inline = d.out; decls.push(d.out); }
      }
      const covered = (p) => inline.includes(p + ':');
      let bg = up.bg;
      let image = up.image;
      let owner = up.owner; // the nearest element with an opaque background (this one included)
      let darkened = up.darkened; // whether what is behind it was light before
      const own = parseColor(cs.backgroundColor);
      if (own && own[3] > 0) {
        let mapped = mapRGBA('b', own);
        // Light before any of Plain's changes: turned dark here, or already by a twin (the site's
        // value rides along in --plain-o-bg).
        let wasLight = mapped !== own;
        if (!wasLight && own[3] > 0.9) {
          const o = cs.getPropertyValue('--plain-o-bg');
          const original = o && parseColor(o.trim());
          wasLight = !!original && !close(original, own) && close(mapRGBA('b', original), own);
        }
        if (mapped !== own && !covered('background')) decls.push('background-color:' + css(mapped) + ' !important');
        else if (!wasLight && own[3] > 0.9 && up.darkened && contrast(own, up.bg) < LIFT_BELOW) {
          // A dark card on a light section: once the section is dark too, the card would melt
          // into it. It is lifted a little, as raised surfaces are in dark designs.
          const lab = toLab(own);
          mapped = fromLab(Math.max(lab[0], toLab(up.bg)[0]) + LIFT, lab[1], lab[2]).concat(own[3]);
          decls.push('background-color:' + css(mapped) + ' !important');
          stats.lifted++;
        }
        bg = over(mapped, bg);
        if (mapped[3] > 0.9) { image = false; owner = el; darkened = wasLight; }
      }
      const picture = cs.backgroundImage;
      if (picture && picture !== 'none') {
        if (picture.includes('gradient(') && !covered('background')) {
          const role = cs.webkitBackgroundClip === 'text' || cs.backgroundClip === 'text' ? 'f' : 'b';
          const value = scan(picture, role, null);
          if (value !== picture) decls.push('background-image:' + value + ' !important');
        }
        // A picture is what the text sits on when it is the background, not a small icon on a
        // colored box.
        if (picture.includes('url(') && (!(own && own[3] > 0.9) || /cover|contain/.test(cs.backgroundSize))) image = true;
        // A logo drawn as the background of an empty box (its name hidden off the box), once:
        // a repeating picture is a pattern, not a logo.
        if (!(own && own[3] > 0) && up.darkened && !up.image && !el.firstElementChild
            && cs.backgroundRepeat === 'no-repeat'
            && (!hasText(el) || parseFloat(cs.textIndent) < -500 || parseFloat(cs.fontSize) === 0)) {
          const urls = picture.match(/url\(/g);
          const m = /url\(\s*(['"]?)([^'")]+)\1\s*\)/.exec(picture);
          if (m && urls.length === 1 && !picture.includes('gradient(')) logo(el, up.bg, m[2]);
        }
      }
      let color = parseColor(cs.color);
      if (color) {
        const mapped = mapRGBA('f', color);
        if (mapped !== color) { if (!covered('color')) decls.push('color:' + css(mapped) + ' !important'); color = mapped; }
      }
      const fill = cs.webkitTextFillColor;
      if (fill && fill !== cs.color) {
        const c = parseColor(fill);
        if (c && c[3] > 0) {
          const mapped = mapRGBA('f', c);
          if (mapped !== c && !covered('-webkit-text-fill-color')) decls.push('-webkit-text-fill-color:' + css(mapped) + ' !important');
          color = mapped;
        } else if (c) color = null; // text drawn by its background (gradient text)
      }
      // Borders from readable sheets are in the twins; only the rest are read here.
      if (stats.unreadable || el.hasAttribute('border') || el.hasAttribute('bordercolor')) for (const side of SIDES) {
        if (cs['border' + side + 'Style'] === 'none' || !parseFloat(cs['border' + side + 'Width'])) continue;
        const c = parseColor(cs['border' + side + 'Color']);
        if (!c) continue;
        const mapped = mapRGBA('d', c);
        if (mapped !== c && !covered('border')) decls.push('border-' + side.toLowerCase() + '-color:' + css(mapped) + ' !important');
      }
      const text = color && cs.visibility !== 'hidden' && hasText(el);
      // Text over a picture keeps the site's own color, as Safari keeps it: the picture isn't
      // darkened, so text made light would vanish on it. The original rides along in
      // --plain-o-color when a twin changed the color.
      let onPicture = image;
      if (text && !covered('color')) {
        const authored = cs.getPropertyValue('--plain-o-color');
        const original = authored && parseColor(authored.trim());
        const current = parseColor(cs.color);
        if (original && current && !close(original, current) && close(mapRGBA('f', original), current)
            && (image || overPicture(el, owner))) {
          onPicture = true;
          pictureText.add(el);
          for (let i = decls.length - 1; i >= 0; i--) if (decls[i].startsWith('color:')) decls.splice(i, 1);
          decls.push('color:' + css(original) + ' !important');
          stats.onPicture++;
        }
      }
      // Text keeps at least the contrast target with what is behind it. Over a picture the
      // site's own choice stands: Plain can't see the picture's colors.
      if (text && !onPicture) {
        const shown = over(color, bg);
        if (contrast(shown, bg) < MIN_CONTRAST) {
          const fixed = readable(shown, bg);
          for (let i = decls.length - 1; i >= 0; i--) if (decls[i].startsWith('color:')) decls.splice(i, 1);
          decls.push('color:' + css(fixed) + ' !important');
          if (fill && fill !== cs.color) decls.push('-webkit-text-fill-color:' + css(fixed) + ' !important');
          stats.contrastFixed++;
        }
      }
      const marks = decls.map((d) => token(d));
      // A sheet Plain couldn't read may also color ::before and ::after (fades, overlays,
      // decorations); those are read only on such pages.
      if (stats.unreadable) for (const pseudo of ['::before', '::after']) {
        const ps = getComputedStyle(el, pseudo);
        if (ps.content === 'none' || ps.content === 'normal' || ps.display === 'none') continue;
        const pd = [];
        const pbg = parseColor(ps.backgroundColor);
        if (pbg && pbg[3] > 0) { const m = mapRGBA('b', pbg); if (m !== pbg) pd.push('background-color:' + css(m) + ' !important'); }
        const pimage = ps.backgroundImage;
        if (pimage && pimage.includes('gradient(')) { const v = scan(pimage, 'b', null); if (v !== pimage) pd.push('background-image:' + v + ' !important'); }
        const pc = parseColor(ps.color);
        if (pc && ps.color !== cs.color) { const m = mapRGBA('f', pc); if (m !== pc) pd.push('color:' + css(m) + ' !important'); }
        for (const d of pd) marks.push(token(d, pseudo));
      }
      if (marks.length) writes.push([el, marks.join(' ')]);
      return { bg, image, owner, darkened };
    };
    const pictureText = new WeakSet();
    const close = (a, b) => Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]) + Math.abs(a[2] - b[2]) < 0.03;

    // Pictures, video and canvases big enough to carry text, in page coordinates; read again at
    // most twice a second.
    let pictures = null;
    let picturesAt = -1e9;
    const largePictures = () => {
      if (pictures && now() - picturesAt < 500) return pictures;
      picturesAt = now();
      pictures = [];
      const all = document.querySelectorAll('img, video, canvas');
      // The first few hundred: a page with more is a gallery, not text over pictures.
      for (let i = 0; i < all.length && i < 300; i++) {
        const m = all[i];
        const r = m.getBoundingClientRect();
        if (r.width >= 120 && r.height >= 80) pictures.push([m, r.left + scrollX, r.top + scrollY, r.right + scrollX, r.bottom + scrollY]);
      }
      return pictures;
    };
    // Whether the element's text lies on a picture: one overlaps it, and no box of its own color
    // sits between them (`owner` holds the picture too).
    const overPicture = (el, owner) => {
      const list = largePictures();
      if (!list.length) return false;
      const r = el.getBoundingClientRect();
      if (!r.width || !r.height) return false;
      const x1 = r.left + scrollX, y1 = r.top + scrollY, x2 = r.right + scrollX, y2 = r.bottom + scrollY;
      for (const [m, a, b, c, d] of list) {
        if (x1 >= c || x2 <= a || y1 >= d || y2 <= b) continue;
        if (el.contains(m) || m.contains(el)) continue;
        if (owner && !owner.contains(m)) continue;
        return true;
      }
      return false;
    };

    // An inline SVG drawn in color is a logo or an illustration: it keeps its colors. One in
    // greys is an icon; where its shapes would vanish on the dark page they flip like text.
    const colorful = (paint, depth = 0) => {
      const c = parseColor(paint);
      if (c) return c[3] >= 0.5 && Math.max(c[0], c[1], c[2]) - Math.min(c[0], c[1], c[2]) >= SVG_CHROMA;
      const ref = /url\(["']?[^"')#]*#([^"')]+)/.exec(paint || '');
      const target = ref && document.getElementById(ref[1]);
      if (!target) return false;
      for (const stop of target.querySelectorAll('stop')) {
        const s = parseColor(getComputedStyle(stop).stopColor);
        if (s && s[3] >= 0.5 && Math.max(s[0], s[1], s[2]) - Math.min(s[0], s[1], s[2]) >= SVG_CHROMA) return true;
      }
      return depth < 2 && target.localName === 'pattern' && coloredSVG(target, depth + 1);
    };
    const SHAPES = 'path, rect, circle, ellipse, polygon, polyline, line, text, use';
    const coloredSVG = (svg, depth = 0) => {
      const shapes = svg.querySelectorAll(SHAPES);
      for (let i = 0; i < shapes.length && i < SVG_SHAPES; i++) {
        const style = getComputedStyle(shapes[i]);
        if (colorful(style.fill, depth) || colorful(style.stroke, depth)) return true;
      }
      return false;
    };
    const icon = (svg, up) => {
      if (up.image || coloredSVG(svg)) return;
      const paints = [];
      let vanishes = false;
      const shapes = svg.querySelectorAll(SHAPES);
      for (let i = 0; i < shapes.length && i < 200; i++) {
        const shape = shapes[i];
        if (shape.closest('defs, mask, clipPath, pattern, symbol, marker')) continue;
        const style = getComputedStyle(shape);
        for (const prop of ['fill', 'stroke']) {
          const value = style[prop];
          // currentColor follows the text, which is already right.
          if (!value || value === 'none' || value === style.color) continue;
          const c = parseColor(value);
          if (!c || c[3] === 0) continue;
          if (contrast(over(c, up.bg), up.bg) < 3) vanishes = true;
          paints.push([shape, prop, c]);
        }
      }
      if (!vanishes) return;
      const marks = new Map();
      for (const [shape, prop, c] of paints) {
        const mapped = mapRGBA(toLab(c)[0] < FG_T ? 'f' : 'b', c);
        if (mapped === c) continue;
        const list = marks.get(shape) || [];
        list.push(token(prop + ':' + css(mapped) + ' !important'));
        marks.set(shape, list);
      }
      for (const [shape, list] of marks) writes.push([shape, list.join(' ')]);
      if (marks.size) stats.icons++;
    };

    // MARK: Black-and-white logos

    // Safari inverts simple black-and-white logos after a histogram check; so does Plain, for the
    // pictures it can read: a mark in greys only (no color), dark, on a transparent ground, that
    // would vanish on the darkened page (under 3:1 against what is behind it). Read off a small
    // copy (LOGO_SAMPLE pixels across) once per address, the page's own picture first; another
    // origin's is read again with CORS, which most image servers allow. Photos and colored logos
    // never qualify; a picture Plain can't read stays as made.
    const logoVerdicts = new Map(); // address -> the mark's color when it is one, else false
    const logoWaiting = new WeakMap(); // a picture still loading -> the walk that waits for it
    const logoQueue = [];
    let logoRunning = false;
    // A read in flight belongs to one walk: switching off or walking again starts a new
    // generation, and an older read's verdict is never applied.
    let logoGeneration = 0;
    const logo = (el, bg, address) => {
      logoQueue.push([el, bg, address, logoGeneration]);
      if (!logoRunning) runLogos();
    };
    const runLogos = async () => {
      logoRunning = true;
      while (logoQueue.length) {
        const [el, bg, address, generation] = logoQueue.shift();
        if (!enabled || !el.isConnected || generation !== logoGeneration) continue;
        try { await judgeLogo(el, bg, address, generation); } catch (e) {}
      }
      logoRunning = false;
    };
    const judgeLogo = async (el, bg, address, generation) => {
      const img = address ? null : el;
      if (img && (!img.complete || !img.naturalWidth)) {
        // Not loaded yet (lazy, or still on its way): looked at once it is.
        if (logoWaiting.get(img) !== generation) {
          logoWaiting.set(img, generation);
          img.addEventListener('load', () => {
            if (logoWaiting.get(img) === generation) logoWaiting.delete(img);
            if (enabled && img.isConnected && generation === logoGeneration) logo(img, bg, null);
          }, { once: true });
        }
        return;
      }
      const r = el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8 || r.width > LOGO_MAX_W || r.height > LOGO_MAX_H) return;
      let src;
      try { src = address ? new URL(address, document.baseURI).href : (img.currentSrc || img.src); } catch (e) { return; }
      if (!src) return;
      let ink = logoVerdicts.get(src);
      if (ink === undefined) {
        if (stats.logosRead >= LOGO_READS) return;
        stats.logosRead++;
        ink = await readLogo(img, src, r);
        logoVerdicts.set(src, ink);
      }
      // Still the same walk and the same picture (a page may swap a picture while it is read).
      if (!ink || !enabled || !el.isConnected || generation !== logoGeneration || contrast(ink, bg) >= LOGO_VANISH) return;
      if (address ? !getComputedStyle(el).backgroundImage.includes(src) : (img.currentSrc || img.src) !== src) return;
      writes.push([el, token('filter:invert(' + LOGO_INVERT + ') !important')]);
      timed(write);
      stats.logos++;
    };
    // One picture read per idle period: a read never holds a frame.
    const idleTime = () => new Promise((resolve) => idle(resolve));
    let logoCanvas = null;
    const pixels = (source, w, h) => {
      const t = now();
      try {
        if (!logoCanvas) logoCanvas = new OffscreenCanvas(w, h).getContext('2d', { willReadFrequently: true });
        const g = logoCanvas;
        g.canvas.width = w; g.canvas.height = h;
        g.drawImage(source, 0, 0, w, h);
        return g.getImageData(0, 0, w, h).data; // throws for a picture another origin won't share
      } finally { const t2 = now() - t; stats.logoMs += t2; stats.logoMax = Math.max(stats.logoMax, t2); cost += t2; }
    };
    // An SVG picture is judged from its source, never drawn: rasterizing an SVG on the main
    // thread costs milliseconds where a PNG costs microseconds. Its paints must all be greys
    // without white (no colors, no embedded pictures); no paint at all means SVG's default black.
    const isSVG = (src) => /^data:image\/svg\+xml/i.test(src) || /\.svg(?:[?#]|$)/i.test(src);
    const svgSource = async (src) => {
      if (src.startsWith('data:')) {
        const comma = src.indexOf(',');
        const body = src.slice(comma + 1);
        try { return /;base64/i.test(src.slice(0, comma)) ? atob(body) : decodeURIComponent(body); } catch (e) { return null; }
      }
      let other;
      try { other = new URL(src).origin !== location.origin; } catch (e) { return null; }
      try {
        const response = await fetch(src, { mode: other ? 'cors' : 'same-origin', credentials: other ? 'omit' : 'same-origin' });
        const text = response.ok ? await response.text() : null;
        return text && text.length <= 65536 ? text : null;
      } catch (e) { return null; }
    };
    const PAINT = /(?:^|[\s;"'{])(?:fill|stroke|stop-color)\s*[=:]\s*["']?([^"';>}\n]+)/gi;
    const svgMarkColor = (text) => {
      const t = now();
      try {
        if (/<(image|foreignObject)\b/i.test(text)) return false;
        let r = 0, g = 0, b = 0, n = 0;
        for (const m of text.matchAll(PAINT)) {
          const value = m[1].trim().toLowerCase();
          if (value === 'none' || value === 'transparent' || value.startsWith('url(') || value === 'inherit') continue;
          const c = value === 'currentcolor' ? [0, 0, 0, 1] : parseColor(value);
          if (!c || c[3] === 0) continue;
          if (chroma(c) >= SVG_CHROMA || luminance(c) > 0.6) return false;
          r += c[0]; g += c[1]; b += c[2]; n++;
        }
        return n ? [r / n, g / n, b / n, 1] : [0, 0, 0, 1];
      } finally { const t2 = now() - t; stats.logoMs += t2; cost += t2; }
    };
    const readLogo = async (img, src, rect) => {
      if (isSVG(src)) {
        const text = await svgSource(src);
        return text ? svgMarkColor(text) : false;
      }
      const sample = (nw, nh) => {
        if (!nw || !nh) { nw = rect.width; nh = rect.height; }
        const k = Math.min(1, LOGO_SAMPLE / Math.max(nw, nh));
        return [Math.max(1, Math.round(nw * k)), Math.max(1, Math.round(nh * k))];
      };
      let data = null;
      if (img) {
        // Decoded off the main thread first, so the draw below only scales it.
        try { await img.decode(); } catch (e) {}
        await idleTime();
        try { data = pixels(img, ...sample(img.naturalWidth, img.naturalHeight)); } catch (e) {}
      }
      if (!data) {
        const copy = new Image();
        let other = false;
        try { other = !/^(data|blob):/.test(src) && new URL(src).origin !== location.origin; } catch (e) {}
        if (other) copy.crossOrigin = 'anonymous';
        copy.src = src;
        try { await copy.decode(); } catch (e) { return false; }
        await idleTime();
        try { data = pixels(copy, ...sample(copy.naturalWidth, copy.naturalHeight)); } catch (e) { return false; }
      }
      return markColor(data);
    };
    // The color of a black-and-white mark on a transparent ground, or false: at least 15% of the
    // picture see-through, the rest greys (under 4% colored) with little white in it.
    const markColor = (data) => {
      let total = 0, clear = 0, solid = 0, colored = 0, light = 0, r = 0, g = 0, b = 0, w = 0;
      for (let i = 0; i < data.length; i += 4) {
        total++;
        const a = data[i + 3];
        if (a < 26) { clear++; continue; }
        solid++;
        const R = data[i], G = data[i + 1], B = data[i + 2];
        if (a > 128 && Math.max(R, G, B) - Math.min(R, G, B) > 40) colored++;
        if (R + G + B > 600) light++;
        const k = a / 255;
        r += R * k; g += G * k; b += B * k; w += k;
      }
      if (clear < total * LOGO_CLEAR || solid < total * 0.02 || colored > solid * LOGO_COLORED || light > solid * LOGO_WHITE) return false;
      return [r / w / 255, g / w / 255, b / w / 255, 1];
    };

    // The walk over the document: top first, in budgets, then idle slices; new content queued.
    const info = new WeakMap();
    const above = new WeakMap(); // backgrounds behind elements never checked (ancestors of added content)
    let seen = new WeakSet();
    let queue = [];
    let walk = null; // { root, el }
    const rootInfo = { bg: PAGE_BG, image: false, owner: null, darkened: true };
    // The parent in the composed tree: a host's own children sit on the slot that shows them,
    // a shadow tree's top elements on their host.
    const parentOf = (el) => el.assignedSlot || el.parentElement || (el.parentNode && el.parentNode.host) || null;
    const infoAbove = (el) => {
      const parent = parentOf(el);
      if (!parent) return rootInfo;
      const known = info.get(parent) || above.get(parent);
      if (known) return known;
      // A subtree added later: the backgrounds above it, outermost first, from the nearest
      // ancestor already known. Remembered, so its siblings don't walk the chain again.
      const chain = [];
      let result = rootInfo;
      for (let p = parent; p; p = parentOf(p)) {
        const k = info.get(p) || above.get(p);
        if (k) { result = k; break; }
        chain.unshift(p);
      }
      for (const p of chain) {
        const cs = getComputedStyle(p);
        const c = parseColor(cs.backgroundColor);
        let bg = result.bg, image = result.image, owner = result.owner, darkened = result.darkened;
        if (c && c[3] > 0) {
          const m = mapRGBA('b', c);
          bg = over(m, bg);
          if (m[3] > 0.9) {
            image = false;
            owner = p;
            const o = cs.getPropertyValue('--plain-o-bg');
            const original = o && parseColor(o.trim());
            darkened = m !== c || (!!original && !close(original, c) && close(mapRGBA('b', original), c));
          }
        }
        if (cs.backgroundImage !== 'none' && cs.backgroundImage.includes('url(')) image = true;
        result = { bg, image, owner, darkened };
        above.set(p, result);
        stats.chained++;
      }
      return result;
    };
    // The next element in document order, through open shadow roots: a host's shadow tree
    // first, then its own children (the ones its slots show).
    const following = (el, root, descend) => {
      if (descend) {
        const shadow = el.shadowRoot;
        if (shadow && shadowRoots.has(shadow) && shadow.firstElementChild) return shadow.firstElementChild;
        if (el.firstElementChild) return el.firstElementChild;
      }
      while (el && el !== root) {
        if (el.nextElementSibling) return el.nextElementSibling;
        const parent = el.parentElement;
        if (parent) { el = parent; continue; }
        const scope = el.parentNode;
        if (!scope || scope === root || !scope.host) return null;
        // Out of a shadow tree: on to the host's own children.
        if (scope.host.firstElementChild) return scope.host.firstElementChild;
        el = scope.host;
      }
      return null;
    };
    // Where a walk starts: an element, or a shadow root's first element.
    const startOf = (root) => root.nodeType === 11 ? root.firstElementChild : root;
    // Works until `deadline`; true when nothing is left.
    const step = (deadline) => {
      let n = 0;
      for (;;) {
        if (!walk) {
          const root = queue.shift();
          if (!root) return true;
          if (!root.isConnected || !startOf(root)) continue;
          walk = { root, el: startOf(root) };
        }
        let el = walk.el;
        if (!el.isConnected) {
          walk.el = walk.root.isConnected ? startOf(walk.root) : null;
          if (!walk.el) walk = null;
          continue;
        }
        while (el) {
          let descend = true;
          if (!seen.has(el)) {
            seen.add(el);
            const mine = check(el, infoAbove(el));
            if (mine) {
              info.set(el, mine);
              const shadow = el.shadowRoot;
              if (shadow) { if (!shadowRoots.has(shadow)) addRoot(shadow, deadline); }
              else if (el.localName.includes('-') && pendingHosts.size < 2000) pendingHosts.add(el);
            } else descend = false;
          } else if (!info.has(el)) descend = false;
          el = following(el, walk.root, descend);
          if (++n % 16 === 0 && now() > deadline) { if (el) { walk.el = el; return false; } }
        }
        walk = null;
      }
    };
    const idle = window.requestIdleCallback
      ? (fn) => requestIdleCallback(fn, { timeout: 150 })
      : (fn) => setTimeout(() => fn(null), 16);
    let pumping = false;
    const pump = () => {
      if (pumping) return;
      pumping = true;
      idle((deadline) => {
        pumping = false;
        if (!enabled) return;
        const budget = deadline ? Math.max(1, Math.min(SLICE_MS, deadline.timeRemaining())) : SLICE_MS;
        // The page's own pending style work, done before the slice's first read: WebKit would do
        // it for the next frame anyway, so it is kept apart from the engine's time.
        const t = now();
        if (document.body) getComputedStyle(document.body).color;
        stats.styleMs += now() - t;
        stats.slices++;
        const done = timed(() => { const d = step(now() + budget); write(); return d; }, 'patchMs');
        if (!done) pump();
        else if (stats.firstPatchDone < 0) stats.firstPatchDone = now();
      });
    };

    // Content and style sheets a page adds or changes, in batches.
    let observer = null;
    const OBSERVED = {
      childList: true, subtree: true, characterData: true, attributes: true,
      attributeFilter: ['style', 'class', 'bgcolor', 'color', 'fill', 'stroke', 'media', 'disabled', 'rel'],
    };
    let addedRoots = [];
    const changedElements = new Set();
    const inlineSeen = new WeakMap();
    const classRechecks = new WeakMap();
    const trailingRecheck = new WeakSet();
    // The color part of an element's inline style, to tell a color change from an animation.
    const inlineColors = (el) => {
      const text = el.getAttribute('style') || '';
      if (!ROLE_HINT.test(text)) return '';
      return parseDeclarations(text).filter(([p]) => p.startsWith('--') || LONGHANDS[p] || roleOf(p)).map((d) => d.join(':')).join(';');
    };
    let sheetsDirty = false;
    let flushTimer = 0;
    let lastSheetCheck = 0;
    const later = () => {
      if (flushTimer) return;
      const run = () => { flushTimer = 0; if (enabled) timed(flush); };
      flushTimer = document.readyState === 'loading' ? requestAnimationFrame(run) : setTimeout(run, WATCH_DELAY);
    };
    const flush = () => {
      const start = now();
      stats.flushes++;
      if (sheetsDirty || start - lastSheetCheck > SHEET_CHECK) {
        lastSheetCheck = start;
        const dirty = sheetsDirty;
        sheetsDirty = false;
        if (dirty || sheetsChanged()) timed(() => syncSheets(2 * SLICE_MS), 'rewriteMs');
      }
      for (let el of changedElements) {
        if (!el.isConnected) continue;
        // A shape is fixed from its SVG as a whole: the SVG gets the look.
        if (el.ownerSVGElement) { const svg = el.closest('svg'); if (svg) el = svg; }
        // Everything below it was judged against its old colors: all of it gets another look.
        // In a small subtree (a component) the fixes come off first, so the new styles are
        // read as the site wrote them; on a large one (a theme class on the body) they stay
        // until replaced, so nothing flashes, and the new look adds to them.
        const inside = below(el);
        const fresh = inside.length < 300;
        if (el.hasAttribute(ATTR)) el.removeAttribute(ATTR);
        seen.delete(el);
        info.delete(el);
        above.delete(el);
        for (const d of inside) {
          if (fresh && d.hasAttribute(ATTR)) d.removeAttribute(ATTR);
          seen.delete(d);
          info.delete(d);
          above.delete(d);
        }
        queue.unshift(el);
        stats.rechecked++;
      }
      changedElements.clear();
      if (addedRoots.length) { queue.push(...addedRoots); addedRoots = []; }
      if (pendingHosts.size) checkHosts();
      // The elements wait for idle time: by then WebKit has restyled the page for its next frame
      // (new twins included), so reading styles costs the engine nothing extra.
      if (queue.length || walk) pump();
    };
    const watch = () => {
      if (observer) return;
      observer = new MutationObserver((records) => {
        // While off nothing is kept: turning back on walks the whole page again.
        if (!enabled) return;
        for (const r of records) {
          if (r.type === 'childList') {
            if (r.target.localName === 'style') sheetsDirty = true;
            for (const n of r.addedNodes) {
              if (n.nodeType !== 1) continue;
              const tag = n.localName;
              if (tag === 'style' || tag === 'link') sheetsDirty = true;
              else addedRoots.push(n);
            }
            if (r.removedNodes.length) for (const n of r.removedNodes) if (n.localName === 'style' || n.localName === 'link') sheetsDirty = true;
          } else if (r.type === 'characterData') {
            if (r.target.parentNode && r.target.parentNode.localName === 'style') sheetsDirty = true;
          } else {
            const t = r.target;
            if (t.localName === 'link' || t.localName === 'style') sheetsDirty = true;
            // A new class is styled by the twins already; the element needs another look only
            // when it carries a fix that may now be stale, or when another origin's sheet could
            // style it out of the twins' reach.
            else if (r.attributeName === 'style') {
              // Pages animate inline styles (transforms, opacity) every frame; only a change of
              // the colors in it needs a look.
              const key = inlineColors(t);
              if (key !== (inlineSeen.get(t) || '')) { inlineSeen.set(t, key); changedElements.add(t); }
            } else if (r.attributeName !== 'class') changedElements.add(t);
            else if (stats.unreadable || t.hasAttribute(ATTR) || t.querySelector('[' + ATTR + ']')) {
              // At most once a second per element: some pages toggle classes every frame.
              // with one last look when the burst is over.
              const wait = 1000 - (now() - (classRechecks.get(t) || -1e9));
              if (wait <= 0) { classRechecks.set(t, now()); changedElements.add(t); }
              else if (!trailingRecheck.has(t)) {
                trailingRecheck.add(t);
                setTimeout(() => {
                  trailingRecheck.delete(t);
                  if (!enabled || !t.isConnected) return;
                  classRechecks.set(t, now());
                  changedElements.add(t);
                  later();
                }, wait);
              }
            }
          }
        }
        later();
      });
      observer.observe(document.documentElement, OBSERVED);
      for (const root of shadowRoots.keys()) observer.observe(root, OBSERVED);
      // A style sheet's load event doesn't bubble; captured here, it brings the sheet in at once.
      // A picture that loads late (lazy images) may now lie under text checked before it had a
      // size: that text gets another look.
      document.addEventListener('load', (e) => {
        const t = e.target;
        if (!t || !t.localName) return;
        if (t.localName === 'link') { sheetsDirty = true; later(); return; }
        if (t.localName !== 'img' || !enabled) return;
        pictures = null;
        const r = t.getBoundingClientRect();
        if (r.width < 120 || r.height < 80) return;
        let a = t.parentElement;
        for (let i = 0; a && i < 6 && !/\S/.test(a.textContent); i++) a = a.parentElement;
        if (!a || a === document.body || a === document.documentElement) return;
        for (const el of a.querySelectorAll('*')) if (seen.has(el) && hasText(el)) changedElements.add(el);
        later();
      }, true);
    };

    // A page that replaces its adopted style sheets, or adds rules with insertRule, changes no
    // DOM. There is no event for either, so the next scroll or touch checks (throttled, with one
    // last check after a burst; the listeners are passive and never delay scrolling).
    let keeping = false;
    const keep = () => {
      if (keeping) return;
      keeping = true;
      let trailing = 0;
      let last = 0;
      const check = () => {
        if (!enabled) return;
        const wait = SHEET_CHECK - (Date.now() - last);
        if (wait > 0) {
          if (!trailing) trailing = setTimeout(() => { trailing = 0; check(); }, wait);
          return;
        }
        last = Date.now();
        timed(() => { adopt(); if (sheetsChanged()) syncSheets(2 * SLICE_MS); }, 'rewriteMs');
        if (pendingHosts.size) timed(checkHosts);
      };
      addEventListener('scroll', check, { passive: true, capture: true });
      addEventListener('pointerdown', check, { passive: true, capture: true });
    };

    // MARK: Judging

    // The state for the app (the indicator, Site Settings, the suggestion), with the choice this
    // page holds: the app corrects a page that kept an old choice (one restored from the
    // back-forward cache, one that loaded before a change), and the document's token.
    const post = (state, force) => {
      if (TOP || (state === posted && !force)) return;
      posted = state;
      try { webkit.messageHandlers.\#(DarkPages.handlerName).postMessage({ state, applies: !off, siteOff, doc: DOC }); } catch (e) {}
    };

    // Rules that apply in dark mode, in the style sheets this page can read: its own, the
    // ones they import, and its adopted ones. Another origin's sheet throws, and is skipped.
    const DARK_QUERY = /prefers-color-scheme\s*:\s*dark/;
    const hasDarkRules = () => {
      let read = 0;
      const visitSheet = (s) => {
        if (s.media && DARK_QUERY.test(s.media.mediaText)) return true;
        let rules = null;
        try { rules = s.cssRules; } catch (e) { return false; }
        return rules ? visit(rules) : false;
      };
      const visit = (rules) => {
        for (let i = 0; i < rules.length; i++) {
          const rule = rules[i];
          if (++read > MAX_RULES) return false;
          const type = rule.type;
          // Plain style rules (most of them) only matter when they nest others.
          if (type === 1) { if (rule.cssRules.length && visit(rule.cssRules)) return true; continue; }
          if (type === 4 && DARK_QUERY.test(rule.media.mediaText)) return true;
          if (type === 3) { if (rule.styleSheet && visitSheet(rule.styleSheet)) return true; continue; }
          if (rule.conditionText && DARK_QUERY.test(rule.conditionText)) return true;
          if (rule.cssRules && visit(rule.cssRules)) return true;
        }
        return false;
      };
      for (const s of document.styleSheets) {
        if (visitSheet(s)) return true;
        if (read > MAX_RULES) return false;
      }
      for (const s of document.adoptedStyleSheets) {
        if (!ours.has(s) && visitSheet(s)) return true;
      }
      return false;
    };

    // The same scan, resumable: it yields after every rule so the light check can stop at its
    // slice's end and go on in the next task. Returns true for a dark rule.
    function* darkRuleScan() {
      let read = 0;
      function* visitSheet(s) {
        if (s.media && DARK_QUERY.test(s.media.mediaText)) return true;
        let rules = null;
        try { rules = s.cssRules; } catch (e) { return false; }
        return rules ? yield* visit(rules) : false;
      }
      function* visit(rules) {
        for (let i = 0; i < rules.length; i++) {
          const rule = rules[i];
          if (++read > MAX_RULES) return false;
          yield;
          const type = rule.type;
          if (type === 1) { if (rule.cssRules.length && (yield* visit(rule.cssRules))) return true; continue; }
          if (type === 4 && DARK_QUERY.test(rule.media.mediaText)) return true;
          if (type === 3) { if (rule.styleSheet && (yield* visitSheet(rule.styleSheet))) return true; continue; }
          if (rule.conditionText && DARK_QUERY.test(rule.conditionText)) return true;
          if (rule.cssRules && (yield* visit(rule.cssRules))) return true;
        }
        return false;
      }
      for (const s of Array.from(document.styleSheets)) {
        if (yield* visitSheet(s)) return true;
        if (read > MAX_RULES) return false;
      }
      for (const s of document.adoptedStyleSheets) {
        if (!ours.has(s) && (yield* visitSheet(s))) return true;
      }
      return false;
    }

    // The light check, for a page dark pages doesn't apply to: whether it could use it, read
    // without touching it (no guard, no twins, no sheet of Plain's). After load and a beat
    // (CHECK_DELAY), only while the page is visible, in slices of CHECK_SLICE ms. Stricter than
    // `judge`: the root's background and a sample of what shows must both be light, so a page
    // this passes is darkened when the user turns it on. Any change of choice cancels it.
    let checkRun = 0;
    let checkPending = 0; // the run in flight, 0 when none
    const MEDIA = new Set(['img', 'video', 'canvas', 'picture', 'svg', 'iframe', 'embed', 'object']);
    // What shows at (x, y): the first opaque background up its ancestors (resumable, one style
    // read per step); a picture counts as neither light nor dark.
    function* sampleAt(x, y) {
      let el = document.elementFromPoint(x, y);
      for (let depth = 0; el && depth < 40; depth++, el = el.parentElement) {
        if (MEDIA.has(el.localName)) return 'media';
        const cs = getComputedStyle(el);
        const c = parseColor(cs.backgroundColor);
        if (c && c[3] >= 0.5) return luminance(c) >= LIGHT ? 'light' : 'dark';
        if (cs.backgroundImage && cs.backgroundImage.includes('url(')) return 'media';
        yield;
      }
      return 'light'; // the white canvas
    }
    // The whole check, resumable: it yields after every sample and every rule, and returns
    // whether the page could use dark pages (light, no dark design of its own).
    function* lightCheck() {
      const meta = document.querySelector('meta[name="color-scheme" i]');
      if (/\b(dark|only)\b/.test((meta && meta.content) || '')) return false;
      const rootStyle = getComputedStyle(document.documentElement);
      if (/\b(dark|only)\b/.test(rootStyle.colorScheme || '')) return false;
      let color = parseColor(rootStyle.backgroundColor);
      if ((!color || color[3] < 0.5) && document.body) color = parseColor(getComputedStyle(document.body).backgroundColor);
      if (color && color[3] >= 0.5 && luminance(color) < LIGHT) return false;
      yield;
      const w = innerWidth, h = innerHeight;
      let lightCount = 0;
      for (const [fx, fy] of [[0.5, 0.5], [0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]]) {
        if ((yield* sampleAt(w * fx, h * fy)) === 'light') lightCount++;
        yield;
      }
      if (lightCount < LIGHT_SAMPLES) return false;
      return !(yield* darkRuleScan());
    }
    // Forgets a check in flight (a change of choice or of colors): the next render starts anew.
    const cancelCheck = () => { checkRun++; checkPending = 0; };
    const checkLight = () => {
      if (TOP || !off || !dark.matches || light !== null || (checkPending && checkPending === checkRun)) return;
      const run = ++checkRun;
      checkPending = run;
      const current = () => run === checkRun && off && dark.matches;
      const finish = (value) => { if (!current()) return; checkPending = 0; light = value; render(); };
      let scan = null;
      // One slice of at most CHECK_SLICE ms; a hidden page waits until it shows again.
      const slice = () => {
        if (!current()) return;
        if (document.visibilityState === 'hidden') {
          document.addEventListener('visibilitychange', slice, { once: true });
          return;
        }
        if (!document.body) return finish(false);
        if (!scan) scan = lightCheck();
        const end = now() + CHECK_SLICE;
        let result = null;
        timed(() => {
          for (;;) {
            const r = scan.next();
            if (r.done) { result = r.value === true; return; }
            if (now() > end) return;
          }
        });
        if (result === null) setTimeout(slice, 0); else finish(result);
      };
      const later = () => setTimeout(slice, CHECK_DELAY);
      if (document.readyState === 'complete') later(); else addEventListener('load', later, { once: true });
    };

    // 'native' when the page has a dark design, asks never to be darkened, is already dark,
    // or shows a background color Plain can't read; 'darken' when its background is light.
    let noBackground = false;
    const declaresDark = () => {
      const meta = document.querySelector('meta[name="color-scheme" i]');
      return /\b(dark|only)\b/.test((meta && meta.content) || '') || hasDarkRules();
    };
    // The page's own background on `el`. A twin that set it carries the site's value in
    // --plain-o-bg, so it reads right with the twins on.
    const ownBackground = (el) => {
      const cs = getComputedStyle(el);
      const c = parseColor(cs.backgroundColor);
      const o = cs.getPropertyValue('--plain-o-bg').trim();
      const original = o && parseColor(o);
      if (original && c && c[3] > 0 && Math.abs(original[3] - c[3]) < 0.01 && close(mapRGBA('b', original), c)) return original;
      return c;
    };
    // The twins are built first (style sheets only, no style pass) and the page is read with
    // them on, so judging costs no style pass beyond the one the darkened first frame needs. A
    // page found native switches them off again in `render`.
    const judge = () => timed(() => {
      if (declaresDark()) return 'native';
      timed(syncSheets, 'rewriteMs');
      if (schemeDark || /\b(dark|only)\b/.test(document.documentElement.style.colorScheme || '')) return 'native';
      if (base.cssRules.length !== BASE_RULES) base.replaceSync(BASE);
      guard.disabled = true;
      setEnabled(true);
      let color = ownBackground(document.documentElement);
      if (color && color[3] < 0.5 && document.body) color = ownBackground(document.body);
      if (!color) return 'native';
      noBackground = color[3] < 0.5;
      // No background of its own: the page shows on the browser's white canvas.
      return (noBackground ? 1 : luminance(color)) >= LIGHT ? 'darken' : 'native';
    }, 'judgeMs');

    // Darkens the page now: the top of the document in this frame, the rest in idle time, and
    // whatever the page adds later.
    let built = false;
    // Every element looked at again (fixes kept until each is checked, so nothing flashes).
    // `clean`: the fixes come off first (back on after being off, when the page may have
    // changed under them); the top of the page is redone at once so nothing shows undone.
    const rewalk = (clean) => {
      if (clean) clearMarks();
      logoGeneration++;
      seen = new WeakSet();
      walk = null;
      queue = [document.documentElement];
      sheetsDirty = true;
      later();
      pump();
    };
    const build = () => {
      const t0 = now();
      if (!queue.length && !walk && document.documentElement && !seen.has(document.documentElement)) queue.push(document.documentElement);
      timed(() => { step(now() + FIRST_MS); write(); }, 'patchMs');
      if (!stats.firstFrame) stats.firstFrame = { judge: stats.judgeMs, rewrite: stats.rewriteMs, elements: now() - t0, checked: stats.checked };
      pump();
      watch();
      keep();
      // Custom elements defined late attach their shadow roots after the walk met them.
      const hostChecks = () => { for (const t of LATE_HOST_CHECKS) setTimeout(() => { if (enabled && pendingHosts.size) timed(checkHosts); }, t); };
      if (document.readyState === 'complete') hostChecks(); else addEventListener('load', hostChecks, { once: true });
    };

    // Applies the current choice: darkened, the guard while judging, or nothing.
    // A frame follows the top page: nothing while the top is off or has a design of its own,
    // the guard while the top is still being judged.
    const parentState = () => {
      if (!TOP) return 'darken';
      try { return TOP.state; } catch (e) { return 'native'; }
    };
    const render = () => {
      const parent = parentState();
      const active = dark.matches && !off && parent !== 'native' && parent !== 'off';
      if (active || adopted) adopt();
      if (active && (verdict === null || parent === null)) {
        guard.disabled = false;
        setEnabled(false);
      } else {
        guard.disabled = true;
        const on = active && verdict === 'darken';
        if (on) {
          const text = BASE + (noBackground ? `html { background-color: ${PAGE_BG_CSS}; }` : '');
          if (base.cssRules.length !== BASE_RULES + (noBackground ? 1 : 0)) base.replaceSync(text);
          setEnabled(true);
          if (!built) { built = true; build(); } else if (rewalkNeeded) { rewalkNeeded = false; rewalk(true); timed(() => { step(now() + FIRST_MS); write(); }, 'patchMs'); }
          if (stats.firstDark < 0) stats.firstDark = now();
        } else if (enabled) {
          setEnabled(false);
          // A design of its own after all (it arrived late): nothing of Plain's stays on it.
          if (verdict === 'native') clearMarks();
        }
      }
      if (TOP) return;
      // Off: what the light check found (a darkened page turned off is known to be light).
      const offState = light === true ? (siteOff ? '\#(DarkPagesState.offForSite.rawValue)' : '\#(DarkPagesState.available.rawValue)')
        : light === false ? 'native' : 'inactive';
      post(!dark.matches ? 'inactive' : off ? offState
        : verdict === 'darken' ? 'darkened' : verdict === 'native' ? 'native' : 'inactive');
      if (off && dark.matches && light === null) checkLight();
      // Same-origin frames follow; frames that were there before the page turned dark get the
      // engine now.
      for (const [doc, follow] of followers) {
        if (!doc.defaultView) { followers.delete(doc); continue; }
        try { follow(); } catch (e) { followers.delete(doc); }
      }
      if (active && verdict !== 'native') askFrames();
    };
    const followers = new Map(); // a frame's document -> its engine's follow()
    const askFrames = () => {
      for (const f of document.getElementsByTagName('iframe')) {
        try {
          const w = f.contentWindow;
          if (w && w.__plainDarkFrame && !w.__plainDarkPages) w.__plainDarkFrame();
        } catch (e) {}
      }
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
    // The page's style sheets as judged, so a later judgement can tell whether anything changed.
    let judgedSheets = '';
    const sheetsKey = () => {
      let key = '';
      for (const s of document.styleSheets) {
        let n = -1;
        try { n = s.cssRules.length; } catch (e) {}
        key += (s.href || '') + ':' + n + (s.disabled ? 'd' : '') + ',';
      }
      return key;
    };
    const decide = (final) => timed(() => {
      if (settled || !dark.matches || off) return;
      if (!final && !ready()) return;
      // Judging a darkened page again switches every twin off and on, a full style pass; only
      // worth it when the page brought new style sheets (a late dark design).
      const key = sheetsKey();
      if (enabled && verdict === 'darken') {
        // New sheets: a dark design they declare is seen without switching anything off. The
        // background is read again only at load, and only for a page that had none of its own
        // when first judged (its design arrived late).
        const full = key !== judgedSheets && final && noBackground;
        if (!full) {
          if (key !== judgedSheets && declaresDark()) verdict = 'native';
          judgedSheets = key;
          if (final) settled = true;
          if (verdict === 'native') render(); else { sheetsDirty = true; later(); }
          return;
        }
      }
      judgedSheets = key;
      verdict = judge();
      if (final) settled = true;
      render();
      if (enabled) { sheetsDirty = true; later(); }
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
        judgedSheets = sheetsKey();
        verdict = judge();
      }
      render();
      if (verdict === null && dark.matches && !off) requestAnimationFrame(frame);
    });
    globalThis.__plainDarkPages = {
      // The app's choice for this page: whether dark pages applies, and whether the user turned
      // the site off by hand. Turning a darkened page off keeps what the judgement learned (the
      // page is light), so the indicator stays, off, without a second look.
      setChoice(applies, isSiteOff) {
        const value = !applies;
        const changedSite = siteOff !== isSiteOff;
        siteOff = isSiteOff;
        if (off !== value) {
          if (value && verdict === 'darken') light = true;
          off = value;
          cancelCheck();
          refresh();
        } else if (changedSite) {
          render();
        } else {
          post(posted, true);
        }
      },
      // The address changed without a new document (a single-page app): look again.
      recheck() {
        if (!off || TOP) return;
        light = null;
        cancelCheck();
        render();
      },
      get doc() { return DOC; },
      // For same-origin frames: the page's switch, its state ('off', null while judging,
      // 'darken' or 'native'), whether a new frame should ask for the engine, and following.
      get off() { return off; },
      get state() { return !dark.matches || off ? 'off' : verdict; },
      get framesWanted() { return dark.matches && !off && verdict !== 'native'; },
      follow(doc, fn) { followers.set(doc, fn); },
      unfollow(doc) { followers.delete(doc); },
      get cost() { return cost; },
      get stats() { return Object.assign({ cost, tokens: tokenCount, twins: order.length, enabled }, stats); },
      // The engine's perf test: the judgement, every sheet rewritten and every element checked
      // from scratch, averaged over `runs`.
      bench(runs) {
        const parts = { judge: 0, rewrite: 0, elements: 0 };
        for (let i = 0; i < runs; i++) {
          let t = now();
          for (const twin of twins.values()) twin.signature = '';
          kinds.clear(); kindsVersion++;
          syncSheets(); parts.rewrite += now() - t;
          // Sheets unchanged now: the judgement is its checks and the style pass it reads.
          t = now(); judge(); parts.judge += now() - t;
          t = now();
          seen = new WeakSet(); queue = [document.documentElement]; walk = null;
          step(Infinity); write(); parts.elements += now() - t;
        }
        for (const k in parts) parts[k] /= runs;
        return parts;
      },
      // Contrast of every visible text element against the color behind it, for the tests.
      audit() {
        const results = [];
        const bgOf = (el) => {
          const chain = [];
          for (let p = el; p; p = p.parentElement) chain.unshift(p);
          let bg = enabled ? PAGE_BG : [1, 1, 1, 1];
          let image = false;
          for (const p of chain) {
            const cs = getComputedStyle(p);
            const c = parseColor(cs.backgroundColor);
            if (c && c[3] > 0) { bg = over(c, bg); if (c[3] > 0.9) image = false; }
            if (cs.backgroundImage.includes('url(')) image = true;
          }
          return { bg, image };
        };
        for (const el of document.body.querySelectorAll('*')) {
          if (!hasText(el) || SKIP.has(el.localName)) continue;
          const cs = getComputedStyle(el);
          if (cs.display === 'none' || cs.visibility === 'hidden' || !el.getClientRects().length) continue;
          let color = parseColor(cs.webkitTextFillColor && cs.webkitTextFillColor !== cs.color ? cs.webkitTextFillColor : cs.color);
          if (!color || color[3] === 0) continue;
          const { bg, image } = bgOf(el);
          if (image) continue;
          let pictured = false;
          for (let p = el; p && !pictured; p = p.parentElement) pictured = pictureText.has(p);
          if (pictured) continue;
          results.push({ id: el.id || el.localName, ratio: Math.round(contrast(over(color, bg), bg) * 100) / 100,
            color: css(color), bg: css(bg) });
        }
        return results;
      },
    };
    // Colors changed: a check in flight is forgotten; back in dark, a page dark pages doesn't
    // apply to is looked at again (it may have changed meanwhile), unless it was darkened before.
    dark.addEventListener('change', () => {
      cancelCheck();
      if (dark.matches && off && verdict !== 'darken') light = null;
      refresh();
    });
    if (TOP) {
      // The frame's own guard (frameScript) gives way to the engine's in this same task.
      const early = globalThis.__plainDarkFrameGuard;
      if (early) { document.adoptedStyleSheets = document.adoptedStyleSheets.filter((s) => s !== early); globalThis.__plainDarkFrameGuard = null; }
      const follow = () => { if (TOP.off !== off) { off = TOP.off; refresh(); } else render(); };
      TOP.follow(document, follow);
      addEventListener('pagehide', () => { try { TOP.unfollow(document); } catch (e) {} });
      addEventListener('pageshow', (e) => { if (e.persisted) try { TOP.follow(document, follow); follow(); } catch (e2) {} });
    }
    document.addEventListener('DOMContentLoaded', () => { stats.dcl = now(); decide(document.readyState === 'complete'); });
    addEventListener('load', () => { settled = false; decide(true); });
    // Back from the back-forward cache: report again (the app corrects an old choice), and a page
    // dark pages doesn't apply to is checked again.
    addEventListener('pageshow', (e) => {
      if (!e.persisted) return;
      if (off && !TOP && verdict !== 'darken') { cancelCheck(); light = null; render(); }
      post(posted, true);
    });
    render();
    if (dark.matches && !off) requestAnimationFrame(frame);
    """#
}
#endif
