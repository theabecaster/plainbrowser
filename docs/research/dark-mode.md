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
  that darkens a page with a CSS filter on the root, `invert(1) hue-rotate(180deg)`, and gives the
  same filter again to pictures, video, canvases, frames, plugins and background pictures so
  they show as made. It touches only pages that declare no dark `color-scheme`, have no
  `prefers-color-scheme: dark` rules Plain can read, and have a light background. A guard keeps
  the root dark while the page is judged. Per-site off from the page menu, remembered like
  blocking.
- **Why the filter and not a style rewrite (Dark Reader's dynamic mode):** see "Choosing the
  technique" below. In short: it is the same operation Safari's Adaptive Dark Mode does (invert
  lightness, keep hue), it costs O(1) script work per page and nothing per element or per
  mutation, it leaves computed styles alone (so the judgement can run again at any time and
  sites cannot detect it, as in Safari), it has no gaps on cross-origin style sheets, and it
  switches live. Its known costs are quality (dark parts of a light page turn light, emoji and
  CSS gradients flip) and possible GPU or raster cost while scrolling, which only the device's
  hitch metric can measure. If the device perf gate shows a hitch increase, the fallback is Dark
  Reader's dynamic mode (MIT, what Firefox, Brave and DuckDuckGo ship on iOS).

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

Plain's judgement, in order, all cheap: `<meta name="color-scheme">` or the root's computed
`color-scheme` includes `dark` or `only` → leave alone; any `prefers-color-scheme: dark` rule in
a readable sheet (up to `FixedChoices.darkPagesMaxRulesRead` rules) → leave alone; the root's,
else the body's, background luminance at least `FixedChoices.darkPagesLightBackground` (no
background counts as white) → darken; otherwise leave alone.

## 6. No flash of white

- WebKit paints nothing until the head's style sheets have loaded, and keeps the previous page
  (or the web view's dark background) on screen until then.
- The script adds a guard at document start while the app is dark: `html, body` black. The
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

## 8. Measurements

See the final section of this file, filled from the run that landed it.
