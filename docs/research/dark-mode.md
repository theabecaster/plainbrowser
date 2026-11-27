# Appearance and dark pages

Research for Settings > Appearance (System, Light, Dark) and dark pages (Plain darkening pages
that have no dark design, like Safari's new Adaptive Dark Mode). Done 2026-11-26 against iOS 27.2.
[V] means the source was read; [S] secondhand; [M] measured in this repo.

## Decision

- **Appearance** is a Settings row with System (default), Light and Dark. It sets every window's
  `overrideUserInterfaceStyle` (System is `.unspecified`), with a 0.3 s crossfade of each window.
  The database keeps the choice; a user-defaults copy is read as the scene connects so the first
  frame already has the user's colors.
- **Web content follows** through the web view's traits. The pool also gives every web view the
  window's resolved style as a trait override, so pages loading off screen match.
- **Dark pages** is one user script (main frame, document start, the engine's content world)
  that darkens a page **per color, by role**, the way Chrome's Auto Dark Mode and Safari's
  Adaptive Dark Mode do inside the engine: light backgrounds turn dark, dark text turns light,
  and what is already dark (a black hero, a dark card) or already light (white text on it) stays
  exactly as made. Pictures, video, canvases, frames, emoji and colored logos are never changed.
  It touches only pages that declare no dark `color-scheme`, have no `prefers-color-scheme: dark`
  rules Plain can read, and have a light background. A guard keeps the root dark while the page
  is judged. Per-site off from the page menu, remembered like blocking. How it works and what it
  costs: section 9.
- **2026-11-27: the root filter was replaced.** The owner, on apple.com: "There is text that looks
  kind of white … it needs to be perfected and refined until it works like Safari does." A
  filter flips every color, so on pages that mix dark and light sections the dark parts turned
  light and their white text turned near white on light (washed out), emoji and gradients
  flipped. Per-role darkening fixes the class of bug, not the one page. The filter's reasons
  (sections 4 and 7) were cost and robustness; the measurements in section 9 show the rewrite
  fits the budget.

## 1. App theme on iOS

- `overrideUserInterfaceStyle` on a window covers its root view controller and every presentation
  in that window; `.unspecified` follows the system. [V]
  [UIKit](https://developer.apple.com/documentation/uikit/uiview/overrideuserinterfacestyle),
  [Choosing a specific interface style](https://developer.apple.com/documentation/uikit/choosing-a-specific-interface-style-for-your-ios-app),
  [.unspecified](https://developer.apple.com/documentation/uikit/uiuserinterfacestyle/unspecified)
- Other windows (another scene, the intro's window) do not inherit it; each window is set.
  Firefox iOS keeps a window map for this. [V]
  [DefaultThemeManager.swift](https://github.com/mozilla-mobile/firefox-ios/blob/main/BrowserKit/Sources/Common/Theming/DefaultThemeManager.swift)
- Animating: `UIView.transition(with: window, options: .transitionCrossDissolve)` around the
  change is the common pattern; Apple documents none. [S]
- How others expose it [V unless noted]:

| Browser | Setting | Options | Default |
|---|---|---|---|
| Safari iOS | none, follows iOS | — | system [S] |
| Chrome iOS | none, follows iOS ([Google](https://support.google.com/chrome/answer/9275525?hl=en&co=GENIE.Platform%3DiOS)) | — | system |
| Firefox iOS | Theme: "Use System Light/Dark Mode", then Light / Dark ([Strings.swift](https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Shared/Strings.swift)) | | system |
| DuckDuckGo iOS | Appearance > Theme: System Default / Light / Dark ([ThemeManager.swift](https://github.com/duckduckgo/apple-browsers/blob/main/iOS/DuckDuckGo/Themes/ThemeManager.swift)) | | System Default |
| Brave iOS | Appearance: Automatic / Light / Dark ([Theme.swift](https://github.com/brave/brave-core/blob/master/ios/brave-ios/Sources/Brave/Frontend/Widgets/Themes/Theme.swift)) | | |
| Arc Search | none found, follows iOS [S] | — | system |

  All of them set the window's style, and web views follow it. Plain uses DuckDuckGo's wording,
  "Appearance", with Apple's own option names (System, Light, Dark).

## 2. WKWebView and `prefers-color-scheme`

- WebKit takes the page's appearance from the web view's own trait:
  `_effectiveAppearanceIsDark` reads `self.traitCollection.userInterfaceStyle`. [V]
  [WKWebViewIOS.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/ios/WKWebViewIOS.mm)
- A trait change updates the page live: media queries are evaluated again, no reload. [V]
  ([Document.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/dom/Document.cpp),
  [WebKit blog](https://webkit.org/blog/8840/dark-mode-support-in-webkit/)) [M] a page's
  `matchMedia('(prefers-color-scheme: dark)')` follows the window's override both ways without a
  reload.
- [M] **A web view outside a window ignores `overrideUserInterfaceStyle`** (still light), but
  honors `traitOverrides.userInterfaceStyle` followed by `updateTraitsIfNeeded()`. The pool uses
  the second for every web view, so background tabs and the warm web view load in the app's
  colors.
- `color-scheme` (CSS or `<meta name="color-scheme">`) with `dark` lets WebKit use dark canvas,
  form controls and scrollbars; without it a page paints a white canvas even in dark mode.
  `only` forbids the browser from overriding the scheme. [V]
  [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/color-scheme)
- `underPageBackgroundColor` defaults to the page's background; it can be set (nil restores the
  default). [V] [Apple](https://developer.apple.com/documentation/webkit/wkwebview/underpagebackgroundcolor)
  Plain sets it while a page is darkened, so overscroll is dark too.

## 3. Safari's Adaptive Dark Mode

- Announced 2026-11-03 for Safari 27.3 (beta; not in 27.2). "When enabled by a user, Safari
  adapts light websites and presents them as dark." [V]
  [WebKit blog](https://webkit.org/blog/18541/introducing-adaptive-dark-mode/),
  [MacRumors](https://www.macrumors.com/2026/11/03/ios-27-3-safari/)
- How: a color matrix that inverts lightness and keeps hue, applied while painting; text aims for
  4.5:1 contrast; light gradients turn dark; most images unchanged, simple black-and-white
  bitmaps inverted after a histogram check; canvas untouched. Sites declaring
  `color-scheme: light dark` are left alone; otherwise Safari "quickly analyzes the page's
  colors" and leaves dark pages alone. `color-scheme: light only` opts out. Scripts read the
  authored colors, so sites cannot detect it. [V] (WebKit blog)
- UI [S]: a "Try" button on bright pages in dark mode, then Page Menu > Adaptive Dark Mode
  On/Off per site, and Settings > Apps > Safari > Adaptive Dark Mode.
  ([9to5Mac](https://9to5mac.com/2026/11/03/ios-27-3-and-macos-27-3-add-vertical-tabs-adaptive-dark-mode-and-more-to-safari/),
  [iOSHacker](https://ioshacker.com/how-to/use-adaptive-dark-mode-in-safari-on-iphone-running-ios-27-3))
- **Not available to apps.** It exists only as private API (`WKPreferences._axCustomColorModeEnabled`,
  `WKWebpagePreferences._forceDisableAXCustomColorMode`); the public headers have nothing for it
  at iOS 27 or later. [V]
  [WKPreferencesPrivate.h](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKPreferencesPrivate.h)
  The older `-apple-color-filter` (Mail's dark mode) is off in WKWebView: [M]
  `CSS.supports('-apple-color-filter', 'apple-invert-lightness()')` is false on iOS 27.2.
- Even in the engine it has scroll cost: Safari Technology Preview 257 fixed "laggy scrolling on
  pages with many gradients affected by Adaptive Dark Mode color filters". [V]
  [STP 257](https://webkit.org/blog/18652/release-notes-for-safari-technology-preview-257/)

## 4. Techniques an app can use

| Technique | How | Quality | Cost | Who |
|---|---|---|---|---|
| Root filter ("filter mode") | `html { filter: invert(1) hue-rotate(180deg) }`, the same filter again on media | Hue kept, lightness flipped. Dark parts of a light page turn light; emoji, shadows and CSS gradients flip; CSS background pictures need finding | O(1) script; the filter is applied while compositing or painting. Gecko on Android showed slow scrolling with it on `html` ([bug 1826576](https://bugzilla.mozilla.org/show_bug.cgi?id=1826576), Gecko-specific) | Dark Reader "Filter", "Filter+" ([css-filter.ts](https://github.com/darkreader/darkreader/blob/main/src/generators/css-filter.ts)) |
| Style rewrite ("dynamic") | Read every style sheet, rewrite each color in HSL, re-fetch cross-origin sheets, watch mutations, classify background pictures on a canvas | Best: designs keep their structure, pictures dimmed only when needed | CPU at load, more on huge or CSS-variable-heavy pages ([bug 1633543](https://bugzilla.mozilla.org/show_bug.cgi?id=1633543), [bug 1800440](https://bugzilla.mozilla.org/show_bug.cgi?id=1800440)); MutationObservers for the page's life; cross-origin sheets without CORS stay light | Firefox iOS (Night Mode, `darkreader` 4.9.89), Brave iOS, DuckDuckGo iOS (as a `WKWebExtension`) [V] |
| Paint-time color filter | In the engine: Chrome's `LABColorFilter` flips CIELAB lightness, images classified by a sampled decision tree; skipped wherever `color-scheme` includes dark ([dark_mode_color_filter.cc](https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/platform/graphics/dark_mode_color_filter.cc), [computed_style.cc](https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/style/computed_style.cc)) | Best | Engine only | Chrome Android, Android WebView ([docs](https://developer.android.com/develop/ui/views/layout/webapps/dark-theme)), Safari 27.3 |
| Forced palette | Override every color with a few system colors | Flat, loses design | Style system | Firefox desktop "Override colors" ([docs](https://firefox-source-docs.mozilla.org/accessible/ColorsAndHighContrastMode.html)) |

- A filter on an ancestor in iOS 26 cancels touch scrolling of inner scrollers, but only when the
  filter *changes* during the gesture (a `:active` transition), not a static filter. [V]
  [WebKit bug 322849](https://bugs.webkit.org/show_bug.cgi?id=322849) Plain's filter changes
  only when the appearance or the per-site switch changes.
- The spec exempts the root from the filter's containing block for fixed elements, so fixed
  headers keep working with the filter on `html`. [V]
  [Filter Effects](https://www.w3.org/TR/filter-effects-1/)

## 5. Detecting a page that already has a dark design

- Chrome: per element, only the `color-scheme` declaration (includes `dark` means skip; `only`
  opts out). No pixel check. [V]
- Safari: `color-scheme: light dark` means skip; otherwise a quick color analysis. [V]
- Dark Reader's detector: meta `color-scheme`, `.dark` or `data-theme="dark"` classes, root
  `color-scheme`, then samples a 4x4 grid with `elementFromPoint`, then the `html`/`body`
  background lightness (below 0.5 is dark). [V]
  [detector.ts](https://github.com/darkreader/darkreader/blob/main/src/inject/detector.ts)
- Reading `cssRules` of another origin's style sheet throws unless it was served with CORS. [V]
  [CSSOM](https://drafts.csswg.org/cssom/#dom-cssstylesheet-cssrules)
- The cheapest strong signal: once the web view is dark, a site with real dark styles already
  renders a dark background, so a background check catches dark designs in sheets Plain cannot
  read.

Plain's judgement, in order, all cheap: `<meta name="color-scheme">`, a readable rule for the
root or body, or the root's inline style has a `color-scheme` with `dark` or `only` → leave
alone; any `prefers-color-scheme: dark` rule in a readable sheet (up to
`FixedChoices.darkPagesMaxRulesRead` rules) → leave alone; the root's, else the body's, own
background luminance at least `FixedChoices.darkPagesLightBackground` (no background counts as
white) → darken; otherwise leave alone. Since 2026-11-27 the background is read with Plain's
rewritten sheets on (each carries the site's value in `--plain-o-bg`), so judging costs no extra
style pass (section 9).

## 6. No flash of white

- WebKit paints nothing until the head's style sheets have loaded, and keeps the previous page
  (or the web view's dark background) on screen until then.
- The script adds a guard at document start while the app is dark: `html, body` in the page dark
  (#181818 since 2026-11-27; black with the filter). The
  judgement runs in a `requestAnimationFrame` callback as soon as the body exists and the head's
  sheets have loaded, which is inside the rendering update of the first paint, and again at
  `DOMContentLoaded` and `load`. The guard goes either way once judged.
- [M] DarkPagesTests reads the root's computed background from an inline script at the top of the
  body (before any paint): it is the guard's black.
- The guard and the darkening are constructed style sheets in `document.adoptedStyleSheets`, not
  DOM nodes, so frameworks that hydrate the document never see them.

## 7. Choosing the technique

| Need (brief) | Root filter | Style rewrite |
|---|---|---|
| No measurable scroll hitch increase | Unknown until the device gate; static filter, GPU composited or painted with tiles | Pure CSS after load, no filter |
| Never touch dark designs | Same judgement for both | Same |
| Pictures, video, canvas, frames, logos kept | Exact (filter applied twice is the identity), CSS background pictures found by a capped scan | Dimmed by classification |
| Script cost on a large page | [M] 0.05–0.25 ms judgement + full scan on a 6,600-element page (simulator) | Tens to hundreds of ms reported on huge pages |
| Works on cross-origin style sheets | Yes, nothing to read | Only with CORS or a native fetch |
| Live switch, per-site off without reload | One sheet toggled | Re-run the rewrite |
| Size | ~6 KB script | Dark Reader ~300 KB per page |

The filter wins on everything Plain can measure in the simulator and on robustness; the style
rewrite wins on quality and is the known-good answer for scrolling. Plain ships the filter and
treats the device perf gate's `hitchMsPerS` on a darkened page as the deciding number.

## 8. Measurements of the root filter (simulator, 2026-11-26)

The Mac was heavily loaded during every run (1-minute load average 170–725), so timings carry
wide noise; read differences, not absolutes.

- **Page load, large light-only page** (6,600 elements, 4,000 style rules, 300 background
  pictures; `DarkPagesTests.largePageCost`, iPhone 17 simulator, navigation start to main-frame
  finish, median of 7, after a warm-up round, two interleaved rounds): darkened 13.1 / 13.3 ms,
  dark pages off for the site 13.1 / 11.6 ms, light app 13.2 / 7.9 ms. No consistent difference.
- **Script cost on that page:** the judgement plus a full background-picture scan 0.05 ms per run
  (averaged over 20 runs; 0.25 ms in one loaded run); the script's whole time per page rounds to
  1 ms on the page's 1 ms clock (0 ms when off or light).
- **Scroll proxy** (`AppearanceTests.testScrollFramesWithAndWithoutDarkPages`, iPhone 17
  simulator, the light-only test site, 20 fast swipes, page frames over 25 ms while scrolling):
  darkened 31 of 3,081, off 26 of 3,054, darkened again 4 of 3,112. No measurable increase; the
  spread is the machine's load. The simulator draws with the Mac's GPU and reports no hitch
  metric, so the device number (`testScrollHitchesDarkened` against
  `testScrollHitchesDarkPagesOff`, XCTHitchMetric) is still to be taken.
- **No white flash:** an inline script at the top of a light-only page's body (before any paint)
  reads the root's background as the guard's `rgb(0, 0, 0)`.

## 9. Per-element darkening (2026-11-27)

### How the others do it

- **Safari 27.3 Adaptive Dark Mode** [V] ([WebKit blog](https://webkit.org/blog/18541/introducing-adaptive-dark-mode/)):
  a color matrix that inverts luminosity and keeps hue, "used to darken light backgrounds and
  lighten dark text"; it "determines when to invert colors so elements remain visible or when
  to leave colors unchanged"; text aims for WCAG 4.5:1; light CSS gradients turn dark; buttons
  keep contrast with their backgrounds; "text is kept visible over images"; most images are
  unchanged, simple black-and-white logos inverted after a histogram check; SVG colors change
  only where icons would lose contrast; canvas untouched; `mask` and `mix-blend-mode` sometimes
  dropped on transformed elements; scripts read the authored colors. The post is page-level about
  detection and says nothing explicit about dark sections on a light page; inverting only light
  backgrounds and only dark text (its own wording) leaves them as they are.
- **Chrome Auto Dark Mode** [V] ([dark_mode_filter.cc](https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/platform/graphics/dark_mode_filter.cc),
  dark_mode_color_classifier.cc): every painted color has a role. Foreground, border, SVG and
  list markers use the foreground classifier: inverted only when darker than brightness 150/255.
  Backgrounds and selections use the background classifier: inverted only when brighter than
  205/255. Inversion is CIELAB lightness (`LABColorFilter`), hue kept. Borders are then adjusted
  for readable contrast against the background they sit on. Elements whose `color-scheme`
  includes dark are skipped.
- **Dark Reader dynamic theme** [V] (MIT; [modify-colors.ts](https://github.com/darkreader/darkreader/blob/main/src/inject/dynamic-theme/modify-colors.ts),
  `modify-css.ts`, `inline-style.ts`, `variables.ts`): rewrites each style sheet into an override
  sheet. Roles by property: anything with `background` is a background (but a foreground when the
  rule also has a `mask-image`, since the background paints an icon), `border`/`outline` are
  borders, `color`, `fill`, `stroke`, `stop-color` are text. Mapping in HSL: backgrounds
  `l < 0.5` scale into 0–0.4 (kept dark), lighter ones map down to the dark pole (#181a1b);
  text `l > 0.5` scales into 0.55–pole (kept light), darker text maps up to the light pole
  (#e8e6e3); neutral colors take the poles' hue; borders map all lightness into 0.5–0.2. CSS
  variables get typed twins (`--darkreader-bg--x`, `--darkreader-text--x`, `--darkreader-border--x`)
  from how they are used, including raw RGB channels used as `rgb(var(--x))`. Inline styles and
  `bgcolor`/`fill`/`stroke` attributes become `data-darkreader-inline-*` attributes plus CSS
  variables; SVG fills count as text in small SVGs (icons) and background in large ones.
  Cross-origin sheets are fetched by the extension's background page. Background pictures are
  drawn on a canvas and classified (dark, light, transparent, large); light large ones get a
  dimming filter. A `MutationObserver` watches style elements, and a polling loop catches
  `insertRule` (CSS-in-JS) that changes no DOM.

### What Plain does (`WebEngine/DarkPagesEngine.swift`)

A focused engine of Plain's own (~1,300 lines of script, no dependency), taking Chrome's role
classification and Safari's stated rules, and Dark Reader's style-sheet rewriting technique
(ideas only; no code copied, so no license to carry):

1. **Colors by role, in OKLab.** Background: OKLab L above 0.62 maps down so white lands on 0.21
   (#181818); darker stays as made (Apple's blue button, 0.57, keeps its color). Text: L under
   0.66 maps up so black lands on 0.94; lighter stays. Borders: above 0.55 map down so white is
   0.30. Hue is kept and chroma kept as far as sRGB allows at the new lightness. Each curve is
   continuous and leaves its own side alone, so applying it twice changes nothing; that makes
   every later check safe to repeat. Values in `FixedChoices`.
2. **Twins of the page's style sheets.** For each sheet (`<style>`, `<link>`, `@import`, adopted)
   a constructed sheet with only the rules that set colors, in the same order and under the same
   `@media`, `@supports`, `@layer`, `@container`, `@scope` and nesting; `@keyframes` with colors
   are copied whole. Every color declaration is repeated, changed or not, so twins compete
   exactly as the originals do: a `.tile-dark` rule after `.tile` still wins. Shorthands are
   never repeated (they would reset widths, styles and pictures a later rule sets): only their
   color longhands. Declarations are read from `cssText` in one call per rule. Twins come after
   the page's sheets in `adoptedStyleSheets`, so they win only where the original rule would.
3. **CSS variables.** A custom property holding a color (or colors, or RGB channels) gets three
   twins in the same rule (`--plain-b-x`, `--plain-f-x`, `--plain-d-x`); color properties that use
   `var(--x)` become `var(--plain-<role>-x, var(--x))`, so an unknown or inline-only variable
   falls back to the site's value. Variables first seen in a later sheet send earlier sheets
   round again.
4. **Other origins.** `cssRules` is null for another origin's sheet in WebKit (no exception).
   The page's own `fetch` (CORS mode, no credentials) reads it again from the HTTP cache and a
   constructed sheet parses it. Without CORS the element pass covers it.
5. **Element pass.** In document order (the top of the page first), 4 ms in the first frame,
   then idle slices of 5 ms: inline styles (rewritten like rules, applied with a token attribute
   `data-plain-dark` and a rule in Plain's patch sheet, `!important`), legacy `bgcolor` and
   `<font color>`, colors that escaped (another origin without CORS), CSS gradients, grey inline
   SVG icons that would vanish on the dark page (colored ones are logos and keep their colors),
   text over pictures, and contrast. **Text over a picture** (one that overlaps it with no box of
   its own color in between, or a CSS background picture) keeps the site's color, as Safari
   does: the twins carry it in `--plain-o-color`, and a lazy picture that loads later rechecks
   the text around it. **Contrast**: any other text under 4.5:1 against the composited color
   behind it is moved in lightness until it passes.
6. **Never touched:** `img`, `picture`, `video`, `canvas`, frames, plugins, CSS background
   pictures, emoji (no filter anywhere), colored SVG logos.
7. **Watching.** A throttled `MutationObserver` (every frame while loading, 100 ms after): new
   or changed sheets are rewritten, new content queued for idle time; an inline-style change
   counts only when its colors changed (pages animate transforms every frame); a class change
   needs a look only when the element carries a fix. `insertRule` and replaced adopted sheets
   are caught on the next scroll or touch and every few batches.
8. **Judging costs no extra style pass.** The twins are built first (style sheets only), then
   the page is read with them on; each twin's background carries the site's value in
   `--plain-o-bg`. With the filter, judging needed a style pass with Plain's sheets off, thrown
   away right after.
9. **Engine pitfalls found by measuring** (each was a multiple of the total): a rule inserted into
   a sheet mid-slice makes the next `getComputedStyle` restyle the whole page (AP News: 2.2 s of
   script, now 0.2 s), so patch rules go in at the end of a slice; element work right after a
   mutation forces WebKit's pending restyle early, so it waits for idle time.

### Measurements (iPhone 17 simulator on this Mac, 2026-11-27)

Script time is everything the engine spends on the main thread for a page (`stats.cost`). The
first frame is what runs before the first paint, which is already darkened (the guard holds the
page dark until then; there is never a light frame).

| Page | Elements | Rules read | Script, whole load | First frame: rewrite / judge style pass / visible elements | Texts under 4.5:1 |
|---|---|---|---|---|---|
| Large light page (`/big`) | 6,308 | 4,000 | 43–44 ms median (filter: ~1 ms) | 15 / 12 / 5 ms | — |
| apple.com-like at store size (`/apple-big`) | 1,580 | ~4,100 | 36–37 ms | 19 / 7 / 5 ms | 0 of 45 (fixture) |
| apple.com (real) | ~1,400 | 6,702 | 42–50 ms | 20 / 6 / 2 ms | 0 of 126 (min 4.7) |
| apnews.com (real) | ~3,800 | 20,675 | 209 ms over a 5 s load | 4 / 34 / 4 ms | 0 of 490 (min 4.88) |
| news.ycombinator.com (real) | 774 | 110 | 11 ms | 4 / 2 / 4 ms | 0 of 291 (min 4.54) |
| wikipedia.org | — | — | judged native (own dark mode) | — | — |

- Load to main-frame finish on `/big`: darkened 65–73 ms vs dark pages off 40–48 ms (the filter
  showed no difference). On `/apple-big`: 52–59 ms vs 25–28 ms. The difference is the first
  frame's work above plus the restyle with twins.
- Every element checked by DCL+58–80 ms (`/big`), DCL+52–58 ms (`/apple-big`).
- The "judge style pass" is WebKit's restyle with the twins, read by the judgement: the same pass
  the darkened first frame needs anyway.
- Scroll proxy: see the table after this list.

| Scroll proxy (`AppearanceTests/testScrollFramesWithAndWithoutDarkPages`, light-only test site, frames over 25 ms while scrolling) | Darkened | Off for the site | Darkened again |
|---|---|---|---|
| Root filter (before) | 17 of 3,090 | 26 of 3,167 | 9 of 3,205 |
| Per-role darkening (after) | 15 of 3,187 | 7 of 3,160 | 20 of 3,123 |

No measurable change: the spread between runs of the same mode is larger than between modes (the
Mac's load average reached 224 during the second run). A darkened page now scrolls with no
filter at all, only ordinary colors, so the device's hitch metric should match a page with dark
pages off; `testScrollHitchesDarkened` on the Duo confirms it.
