# Plain Browser — build plan

Status: approved 2026-11-26. Build in progress.
Inputs: 7 research reports (WebKit performance, motion/feel, feature completeness + reference browsers, on-device AI, stack/build pipeline, iPhone Duo design, naming), plus the design audit against reference browsers (`docs/research/design-audit.md`).

## 1. Bottom line

Build a UIKit-shell browser on `WKWebView`, designed Duo-first, with performance gates that fail the build on regressions.
Overnight target: a daily-usable v0.1 on the Duo (search-first launch, tabs, gestures, Duo split tabs, blocking, history, all P0 edge cases).
Reader, translation, AI, widgets and polish come in follow-up passes after you test it.

Correction from research: Arc Search was not fully pulled from iOS. Its AI features, sign-in and sync were switched off on 2026-11-23, and the app lives on as a "lite" browser. Desktop Arc ends 2026-12-22.

## 2. Goals and hard budgets

The build fails if a budget is broken. Budgets are measured on the Duo, never the simulator.

The perf gate's budgets (target = the best realistic number, fail = a regression guard; reasons
in `perf/budgets.json`, sources in `docs/research/perf-goals.md`). On top of `fail`, a device run
fails when a metric is more than 10% (or one frame) worse than its best in the last 5 passing
device rows.

| Metric | Target | Fail | How measured |
|---|---|---|---|
| Cold launch, `main` to first frame | 150 ms | 300 ms | `launch.firstFrame` signpost |
| Cold launch to a focused search field | 150 ms | 300 ms | `launch` signpost |
| Cold launch with the last tab on the first frame | 150 ms | 300 ms | `launch.firstFrame` signpost |
| Hitch ratio, scrolling a page | 0 ms/s | 5 ms/s | `XCTHitchMetric` |
| Hitch ratio, scrolling a large page with dark pages | 0 ms/s | 10 ms/s | `XCTHitchMetric` |
| Tabs button to gallery settled | 610 ms | 750 ms | `gallery.show` signpost |
| Gallery card tap to page settled | 610 ms | 750 ms | `gallery.openTab` signpost |
| Bar swipe, finger lift to page settled | 320 ms | 600 ms | `tab.swipeSettle` signpost |
| Address pill tap to keyboard at rest | 510 ms | 600 ms | `urlBar.ready` signpost (the system keyboard's 0.5 s rise inside) |
| New Tab to keyboard at rest | 510 ms | 600 ms | `tab.newReady` signpost |
| Keystroke to local suggestions | 8.3 ms | 50 ms | `search.suggestions` signpost |
| Link tap to next page's first paint (local page) | 100 ms | 200 ms | the pages' Paint Timing |
| App memory with 10 tabs | 60 MB | 150 MB | `XCTMemoryMetric`, absolute footprint |

Other budgets, not yet in the gate:

| Metric | Budget | How measured |
|---|---|---|
| Hitch ratio, tab gallery and transitions | < 5 ms/s, fail at 10 ms/s | `XCTOSSignpostMetric`, `xctrace` Animation Hitches |
| Frame rate | 120 Hz on all native motion (WebKit holds page content near 60 Hz) | `CADisableMinimumFrameDurationOnPhone` is set. No `CAFrameRateRange` exists yet: add `CAFrameRateRange(80,120,120)` where a display link drives big motion, and verify 120 Hz on the Duo with the Animation Hitches trace. |
| Omnibox query on 100k history rows | p95 < 16 ms | unit perf test |
| Tap-to-visual-response | same frame | no async hop before the first visual change |
| App memory per discarded tab | < 1 MB | `XCTMemoryMetric` |
| Fold/unfold | no reload, no dropped frames, no lost state | device test |

## 3. Tech stack (decided, minimal dependencies)

| Area | Choice | Why |
|---|---|---|
| Web engine | UIKit `WKWebView` | The SwiftUI `WebPage` API (iOS 27) still lacks popups, `WKDownload`, `interactionState`, snapshots, scroll-view access and `obscuredContentInsets`. |
| UI shell | UIKit: container, URL bar, toolbar, tab gallery (`UICollectionView`), gestures, transitions | SwiftUI still hitches more on hot paths. Firefox iOS is UIKit too. |
| Leaf screens | SwiftUI via `UIHostingController`: settings, history, bookmarks, menus | Low-frequency screens, faster to build. |
| Animation | One spring vocabulary through `UIView.animate(SwiftUI.Animation)` (iOS 18+) | Same springs in UIKit and SwiftUI, free velocity handoff from gestures. |
| Models | `@Observable`, one object per tab; per-frame values (progress, scroll, drag) never in observed models | Avoids over-invalidation. |
| Storage | GRDB 7 (SQLite + FTS5) | Full-text omnibox search, async off-main writes, Sendable. SwiftData has no full-text search and degrades past ~100k rows. |
| Concurrency | Swift 6, default MainActor in UI modules only; storage/core nonisolated, `@concurrent` for heavy work | Keeps database work off the main thread. |
| Project | XcodeGen spec + one local SPM package with many targets | Agent-friendly, fast incremental builds, no `.pbxproj` merge pain (same as Rex DUO). |
| Deployment target | iOS 27.2 | Duo APIs start at 27.1, but `UIView.LayoutRegion.bar(onEdge:)` needs 27.2. Duo runs 27.3. |

Dependencies (whole list):
- GRDB.swift (MIT).
- mozilla/readability.js (Apache-2.0), bundled as a resource.
- duckduckgo/TrackerRadarKit (Apache-2.0) for tracker rules; EasyList compiled at build time.
- duckduckgo/autoconsent (MPL-2.0) for cookie banners (P1).
- No Nuke, no SwiftData, no AdGuard converter in the app (GPL), no SwiftUI WebView.

## 4. Architecture

One local package, targets:

- `BrowserCore`: tab/session models, URL fixup, address-bar intent rules, frecency ranking. Pure Swift, `swift test` on macOS in seconds.
- `Storage`: GRDB migrations; history, bookmarks, favorites, sessions, favicons; FTS5.
- `WebEngine`: shared `WKWebViewConfiguration`, web view pool and tiering, user scripts, snapshot service, `interactionState` + sessionStorage save/restore, navigation/UI delegates split DuckDuckGo-style.
- `ContentBlocking`: rule compile + cache by content hash; never compiled at launch.
- `Reader`: readability.js in an isolated `WKContentWorld`.
- `ShellUI`: container, URL bar, toolbar, gestures, transitions, Duo layout system.
- `TabGalleryUI`: collection view, thumbnail pipeline.
- `FeatureUI`: SwiftUI leaf screens.
- `DesignSystem`: springs, colors, type, icons, haptics.
- `PerfSignposts`: signpost names shared by the app and tests.
- `AI` (later): Foundation Models wrapper behind `LanguageModelSession`.

### Architecture rules (enforced, not aspirational)

1. **Layering is one-way.** App → ShellUI/TabGalleryUI/FeatureUI → WebEngine/ContentBlocking/Reader → Storage → BrowserCore. Lower layers never import higher ones. `BrowserCore` and `Storage` never import UIKit or WebKit, so their tests run on macOS with `swift test`. Package targets enforce the direction: an illegal import does not compile.
2. **One owner per piece of state.** `TabStore` owns the tab list and order. Each `Tab` (an `@Observable`) owns its own title, URL and load state. The `WebViewPool` owns web views. The UI never creates or keeps a `WKWebView` itself; it asks the pool.
3. **Protocols at seams that need tests or swaps**: storage, the web view pool, the search engine provider, the clock and the AI model. No protocol for things with one implementation and no test need.
4. **Main thread is for UI only.** No disk, network, database, JSON or image decoding on the main thread. Storage calls are `async`, and heavy work is `@concurrent`. A debug-build check flags main-thread I/O.
5. **Every user-visible interaction has a signpost** (`PerfSignposts`): launch, URL bar focus, keystroke → suggestions shown, tab switch, gallery open/close, fold/unfold settle, page commit and finish. If an interaction has no signpost, it is not done.
6. **Performance is part of every change.**
   - Every milestone and every later change runs the perf gate on the Duo before it merges. A budget breach blocks the merge, the same as a failing test.
   - Each merge records its numbers in `docs/perf-log.md`, so a slowdown can be traced to the exact merge.
   - Any new dependency, animation or background work states its perf cost in the merge notes.
7. **No speculative abstraction.** No DI framework, no coordinator framework, no reactive framework. Plain Swift types, initializer injection, `@Observable` and `async/await`.
8. **Docs that agents and humans read first:** `AGENTS.md` (rules above, build and test commands, the perf gate), `docs/architecture.md` (module map and data flow), `docs/perf-log.md`, `docs/decisions.md` (each decision and why: UIKit vs SwiftUI, GRDB, no TCA).

### Engine rules that drive the feel

1. **Launch:** first frame shows a native `UITextField` already focused. After that frame, create one offscreen `WKWebView` and load `about:blank` to warm the web and network processes (first web view costs 47–100+ ms; later ones 2–8 ms). Hand it to the first tab. Content rules attach before the first real navigation.
2. **Tab tiers:**

   | Tier | Which tabs | Holds |
   |---|---|---|
   | Live | visible + their left and right neighbours + a few recent (2 visible on the Duo split) | full `WKWebView`, attached or parked |
   | Kept | next few | detached; WebKit suspends it (default `inactiveSchedulingPolicy`, `.suspend`) |
   | Discarded | the rest | `interactionState` + sessionStorage blob + thumbnail |

   No throttle tier: copied configurations share one `WKPreferences`, so a per-tab policy would change every tab. The kept cap has a hard ceiling (Firefox crashed at ~50 live web views).
   On a memory warning, everything except visible tabs drops to Discarded (Firefox's fix for 7.8M watchdog kills).
   Never discard a tab that plays media, is in PiP or fullscreen, uses the camera or microphone, or is downloading, even on a memory warning.
3. **Thumbnails:** taken once when a tab leaves the screen, at ~2x the card size (`snapshotWidth` is in points and WebKit multiplies by screen scale, so 200 pt gave 3x), written off-main, decoded with `byPreparingForDisplay`. Never per cell. Full-size snapshots cost 70+ MiB.
4. **Collapsing toolbar without page relayout:** `obscuredContentInsets.bottom` follows the bar's resting state: the expanded height when the bar settles expanded, the collapsed height when it settles collapsed. It changes once, at the end of each snap, never per frame, and waits while the page bounces at the top (WebKit clamps overscroll on any inset change). A fixed collapsed inset would hide fixed-bottom page UI and the page's last lines under the expanded bar. Animate the bar with `transform`/`alpha` only. Set `setMinimumViewportInset(_:maximumViewportInset:)` to collapsed/expanded so CSS `svh`/`lvh` stay stable. Drive it from the scroll-view delegate, not KVO.
5. **Save and restore:**
   - Save `interactionState` after each load (debounced) and on detach. Flush every non-discarded tab on resign active, inside a background task.
   - `takeSnapshot`, `fetchData(of: .sessionStorage)` and `restoreData` get a ~300–500 ms timeout; on timeout, continue with `interactionState` only. Skip the sessionStorage fetch on a memory warning.
   - After setting `interactionState`, check `webView.url`; if it is nil, load the URL. A restored POST page asks before it resubmits.
6. **Crash recovery:** `webViewWebContentProcessDidTerminate` reloads the visible tab (crash-loop guard); while the app is in the background, it waits for become-active. A killed hidden tab is a discard, not a crash: keep its `interactionState`, mark it Discarded, and restore it in place on select.
7. **Speed tricks:** preconnect on link touch-down (injected `<link rel=preconnect>`), back-forward cache on, HTTPS upgrade via `preferredHTTPSNavigationPolicy`, JIT left on (`securityRestrictionMode = .none`).

### Data rules: blocking, reader, storage, suggestions

1. **Blocking has no gap on update:** when a list changes, the last compiled list with the same name stays attached until the new one compiles; then they swap and the old one is deleted.
2. **First launch blocks the most first:** `blocklist-01` holds the highest-value rules (EasyPrivacy network blocks + EasyList third-party domains) and compiles first.
3. **Cosmetic rules in one list,** placed first, so each frame gets one hide stylesheet. Measure on the Duo before dropping generic selectors.
4. **Reader check is small:** only `isProbablyReaderable` (4 KB) runs per page, as a user script at DOMContentLoaded in the reader world. The full Readability parse runs only when the check passes and the tab is visible, or on tap.
5. **Storage maintenance:** after Clear History, `PRAGMA wal_checkpoint(TRUNCATE)` then `VACUUM`, off main. Daily: prune old visits, cap history and favicon size, FTS `optimize`, `PRAGMA optimize`.
6. **Suggestions:** never send URL-like or intranet input to the remote engine; no remote suggestions in private tabs. Preconnect to the suggestion host on focus. A small prefix cache fills the list while a request is in flight.
7. **Omnibox ranking:** the top hit is site-level (`github.com` before a deep page) until the text reaches a path; typed visits weigh more than link clicks; the suggestion picked for an input ranks first the next time.

## 4b. Product principle: opinionated and simple

Plain is a fast, opinionated browser. It makes the decisions so users don't have to.

**The Settings screen holds these items and nothing else:**
- Search engine. Google by default, plus the popular engines and a custom one.
- Tab layout: Regular or Side tabs. Only shown where side tabs are possible.
- Archive tabs after: 12 hours, 1 day, 1 week (default), or never.
- Clear history and website data.

**Decided for the user, with no setting:**
- Ad, tracker and cookie-banner blocking is always on. The page menu has "Turn off on this site".
- HTTPS upgrade, preconnect and tab memory tiers.
- Desktop or mobile site: picked from the pane width. The page menu can override it, and the choice is remembered per site.
- Page zoom: remembered per site, automatically.
- Text size and dark mode follow the system.
- Haptics and motion follow the system's Reduce Motion setting.

**Not built:** themes, toolbar customization, gesture remapping, per-feature toggles.

**Rule for new settings:** a setting is added only when no single default can serve most people. When in doubt, decide in the logic.

## 5. Feel: interaction model and motion spec

Model: Arc Search's loop plus Safari's best gestures, minus their known flaws.

- Launch straight into search, keyboard up, favorites above the keyboard.
- Minimal bottom bar (outer screen): URL pill + tabs + actions.
- Swipe along the expanded bar to switch tabs; swipe past the last tab shows a "new tab" card first (fixes Safari's no-warning behavior). Swipe up from the bar opens the gallery.
- The collapsed pill takes taps only (tap expands). It sits in the home-indicator zone, where swipes belong to the system.
- Tab gallery: cards, flick up to close, tap to zoom in.
- Tabs auto-archive after a chosen time (12h / 1d / 3d / 7d / 30d / off), archive searchable.
- Gesture start zones stay out of the bottom 20 pt (Home indicator fights, an Arc complaint).
- Swipe back on a tab's first page goes back, never archives (an Arc complaint).

Motion principles: springs with no bounce by default; bounce only when a flick with momentum drives the motion; every animation can be grabbed mid-flight; nothing blocks input; rubber-band at every edge; haptics only on threshold-cross (selection) and commit (impact); Reduce Motion swaps zoom/slide for a 0.2 s crossfade.

| Interaction | Animation | Parameters | Haptic |
|---|---|---|---|
| URL bar focus | bar grows into search sheet | `.snappy(duration: 0.3)`, bounce 0, follows `keyboardLayoutGuide` | none |
| Switch tab by bar swipe | 1:1 tracking, then spring with gesture velocity. Preview: the neighbour's live web view, else a 2x full-screen snapshot kept for the two neighbours only. A snapshot of the glass bar slides, never live glass. | `.spring(duration: 0.28, bounce: 0.08)`, commit at 50% projected travel. Was 0.35 / 0.12 (2026-11-27): a touch quicker (95% of the way in ~0.18 s, was ~0.21 s), but its 2–3 pt overshoot on the Duo’s 951 pt inner page, or after a fast flick on any width, crept back for ~0.2 s; this one overshoots under half a point and rests in ~0.3 s on any width (docs/research/perf-gallery-swipe.md) | selection on commit |
| Swipe past last tab | rubber-band, new-tab card at 80 pt | as above | selection at threshold, light impact on commit |
| Open tab gallery | page zooms into its card and the cascade zooms in around it; custom snapshot animator. Swipe up from the bar: the card follows the finger (bottom edge under it, sideways 1:1), card-sized at 40% of the height, then rubber-bands (docs/research/arc-tab-switcher.md) | `.spring(duration: 0.42, bounce: 0.06)`, 80–120 Hz; commit on a flick > 600 pt/s up or a projection (0.99) past 30%. Was bounce 0 (2026-11-27): damping 0.94 keeps the pace through the first half and lands the last points sooner; its overshoot is under 0.2 pt (none visible), where the critically damped spring crept over its last half point for ~0.15 s (docs/research/perf-gallery-swipe.md) | none |
| Open tab | same custom animator in reverse, interruptible; not the system `.zoom` (tabs are re-parented web views, not pushed controllers); target cell hidden by tab ID; live web view swapped in at the end | `.spring(duration: 0.42, bounce: 0.06)` (the same spring both ways) | none |
| Close tab | swipe a card up: it follows the finger 1:1 from touch-down (the axis locks after 6 pt: within 60° of straight up lifts, flatter scrolls), no smoothing spring; projected throw, cards reflow. (docs/research/tab-drag-feel.md) | close at −40% height (projection 0.99) or > 500 pt/s up (was 800: a light flick fell short); throw `Spring(0.3, bounce 0)` and spring back `Spring(0.32, bounce 0.12)`, both frame by frame with the release velocity and catchable mid-flight; reflow `Spring(0.35, bounce 0.1)` frame by frame | soft impact |
| Suggestions change while typing | nothing slides: a row that stays in place is untouched, new rows fade in and old ones fade out where they stand, a row that changes place crossfades there; one change per frame, picked up mid-flight by the next keystroke; Reduce Motion: the list crossfades | linear crossfade, 0.12 s, from the on-screen opacity | none |
| Pull to refresh | rubber-band, arms at 80 pt | — | selection at arm |
| Toolbar collapse | tied to scroll; snaps on release, toward the release velocity when it is clear; a drag during the snap retargets from the on-screen position | `.smooth(0.25)` | none |
| Toolbar hide | reading on past the pill (120 pt, or a flick projected that far) sinks the pill 12 pt past the bottom edge as its text fades; the page inset follows at rest (docs/state-rules.md, "Chrome while reading") | `.smooth(0.35)`, frame by frame (`SpringDriver`) | none |
| Toolbar reveal | the whole bar springs back from the pill or hidden: 24 pt up (8 pt fast), a bottom-edge or status-bar tap, the page's end, a new page; a reveal during a hide retargets with its velocity; the page inset moves at the start, so a fixed footer rises with the bar | `.smooth(0.25)` | none |
| Back to the opener | Back on a link-opened tab's first page closes the tab: a snapshot of its page slides off toward the trailing edge (where Back sends a page) over the live opener, which slides in from 30% behind it, as a navigation pop; input is never blocked; Reduce Motion: a 0.2 s crossfade | `.spring(duration: 0.35, bounce: 0)` | none |
| Link preview | `UIContextMenuInteraction`; the live preview is capped (`LinkMenuRules.previewSize`) so the whole menu fits under it, or beside it in compact height | system | system |
| Fold / unfold | none custom; system bounds change | — | none |
| Sidebar: rail ↔ titles | the column's edge moves (a drag follows the finger 1:1, rubber-bands past the widest state); titles fade in over the first half of the way and the selection mark stretches with the edge; rows are never laid out again, the page gets one new frame. Portrait: it opens as a drawer over the page and the bar | `.spring(duration: 0.35, bounce: 0)`, bounce 0.12 after a flick > 600 pt/s; rests on the state nearest the width projected 0.18 s ahead | selection on Show Titles |
| Tab list comes or goes (second tab opened, back to one tab) | the strip drops in from under the bar (17 pt, 0.9 tall) and the sidebar slides in from its own edge, fading; leaving, a picture of it goes the same way back. Transform and opacity only; the page takes its new frame once, inside the same spring | `.spring(duration: 0.35, bounce: 0)`; Reduce Motion: 0.2 s crossfade | none |
| Tab picked in the sidebar or strip | the Lagoon mark fades out on the tab left and in on the tab chosen; nothing slides | `.snappy(0.15)` | none |
| Site icon arrives | fades in over the tab's letter where it stands; an icon already in memory is there with the row | 0.2 s crossfade | none |

Chrome: the pill and the button bar share one Liquid Glass container (`UIGlassContainerEffect`) with no extra layer shadow, plus the system scroll edge effect on the page edge under them.

All values are starting points, tuned on the Duo.

## 6. iPhone Duo layout system

Facts that shape it:
- Fold/unfold is a bounds + trait change in the same scene; nothing reloads if we don't reload.
- Fully open, the inner screen is one flat screen. The fold region is only active when partially open.
- The inner screen rotates: landscape 951×669 and portrait 669×951.
- Web pages cannot see the fold in a `WKWebView` (Viewport Segments / Device Posture are disabled). We pass fold geometry ourselves when needed.
- There is no "is this a Duo" check and no posture value. Layout comes from size class, `reservedRegions`, and the fold's direction.
- On the outer screen the system moves bars to a vertical side strip; the URL field cannot live there.

| State | Layout |
|---|---|
| Outer portrait (466×678, ~382 pt content) | System vertical side bar: Back, Forward, Tabs, Share, More (`.verticalPreferred`). Custom bottom URL pill that shrinks on scroll. One pane. |
| Outer landscape (678×466) | Same; primary pane only. |
| Inner landscape, flat (951×669) | Safari's model (docs/research/safari-duo.md): the system vertical bar is off and one top bar sits under the status bar (Back, Forward; the address; Tabs, Share, More), the page at full width under it. Tab Layout Above (default): a 34 pt strip under the bar from the second tab; Left/Right: a 52 pt rail. The bar shrinks to the address while reading. Split tabs on demand, one bar for both panes. |
| Inner portrait (669×951) | The same top bar and strip, one pane (no bottom bar). |
| Book pose (vertical fold, partially open) | Split panes snap to the two halves. Pills and toasts shift off the fold region (`reservedRegions(kind: .division)`) and avoid the inner camera (`.occlusion`); the page never moves. |
| Tabletop / laptop pose (horizontal fold) | No custom layout; the page keeps spanning the screen. Only floating controls avoid the fold. |
| Regular iPhones (375 / 402 / 440 pt) and resizable windows | Same code. Second pane only when width and height are both regular. |

### Tab layouts: side tabs (option) and regular tabs

- **Setting:** Tabs > Layout: "Regular" or "Side tabs". Regular tabs work everywhere. Side tabs apply only where the window is big enough. Elsewhere the app uses regular tabs and keeps the choice, so side tabs come back on unfold.
- **When side tabs are available:** horizontal AND vertical size class are both `.regular`. On phones that means the Duo's inner screen only, in landscape and portrait.
  - Outer screen: compact width, so no side tabs.
  - Inner screen in system Split View: compact width, so no side tabs.
  - Pro Max in landscape: regular width but compact height, so no side tabs. Checking width alone would wrongly allow it here.
  - iPad and iOS 27 resizable windows follow the same rule.
- **Why not screen size:** Apple's Duo guidance says never use `UIScreen.main`, the device type or orientation for layout. `UIScreen` is ambiguous with two screens, and iOS 27 windows can be resized. Size classes on the window scene's traits are the supported signal.
- **Mechanics:** read the root view controller's `traitCollection`, and use `registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self])` to switch the layout. The switch rides the system's fold/unfold bounds animation, with no custom animation and no web view reload. A minimum-width guard of about 640 pt protects against future odd sizes. It applies to the width left for pages after the sidebar, measured in layout, not to the window.
- **Side tabs design (inner screen):**
  - Leading sidebar with three states: Hidden, Rail (52 pt, site tiles only) and Expanded (~260 pt, pinned favorites on top and a tab list below, favicon + title).
  - Rail is forced while a split is showing. A fold (active vertical division) forces Rail or Hidden; Expanded then floats over the page. A 260 pt sidebar beside a split would leave ~345 pt per pane, narrower than the outer screen.
  - Collapse with a swipe or button. It also collapses on its own in inner portrait when the page needs the width.
  - Drag tabs to reorder, or drop one on the other pane to split.
  - It works with the split panes: the sidebar plus up to two pages.
- **Regular tabs on the Duo:**
  - Outer screen: Arc-style card gallery with flick-to-close and bar-swipe switching.
  - Inner screen: a grid with an even number of columns (2 or 4), so no card sits on the fold. It uses the same zoom transitions and gestures.

Built with: one `UIArrangementViewController` (`.split.axes(.horizontal)`) holding the two web panes; `reservedRegions(kind: .division, options: .includeInactive)` for the fold's position only (a flat fold's division has zero width), to pick column counts and the pill's side, never to inset content; `verticalBarEdge` + `UIView.LayoutRegion.bar(onEdge:)` for the side bar; `windowScene.displayLink` for 120 Hz.

Duo features, ranked:
1. Adaptive shell across all states (table above).
2. Fold-safe: same `WKWebView` objects stay in the same parents, only frames change. Each web view's final frame is set once, from the target size in `viewWillTransition(to:with:)`; `obscuredContentInsets` and the viewport insets are applied once in its completion. No snapshot cover for a fold: WebKit scales its tiles, then reflows. (Verify on the Duo that a fold calls `viewWillTransition`.)
3. Split tabs across the crease: "Open in other pane" from the link menu, drag a tab to the other pane, swap panes, long-press to move. A tab moves by re-parenting its web view under a snapshot cover, no reload. In a split, one pane is focused (the one touched last, marked on its pill); shared bar buttons act on it.
4. Supporting pane (~30%, 250 pt min): reader, find results, history or (later) summary next to the page. Built 2026-11-27 as the side pane (docs/decisions.md).
5. Desktop pages by default on the inner screen (content mode chosen at navigation start from pane width; never switched on fold, which would force a reload).
6. Per-window browser state (app-wide stores, per-scene tabs and restoration), so "Open in New Window" can ship later without a rewrite. Shipped 2026-11-27 with Open in New Window (docs/decisions.md).

Dropped: outer-screen "peek" (no API), hinge gestures (gimmick), tabletop video (WebKit's fullscreen player already splits around the fold; check once on the device).

## 7. Features and milestones

### Overnight (v0.1, in order; each milestone ends with build, tests, perf gate, install, commit)

**M0 — Skeleton and pipeline**
- Repo, XcodeGen spec, package targets, signing (team in the gitignored `Config/Signing.local.xcconfig`).
- Scripts: `build.sh`, `install-duo.sh` (devicectl install + launch), `shot.sh` (device screenshot per screen), `perf-gate.sh` (xcresult metrics vs budgets).
- Launch-time and hitch tests running on the Duo from the first milestone.

**M1 — Core browsing**
- Search-first launch, URL bar with intent rules (URL vs search), search suggestions, history + favorites (GRDB FTS5), favorites above the keyboard.
- Search engine picker in Settings (Google by default). Engines: Google, DuckDuckGo, Bing, Brave Search, Kagi, Ecosia, Startpage, Yahoo, Perplexity, ChatGPT, plus a custom engine (any URL with `%s`). Suggestions come from the engine's own endpoint where one works (Google, DuckDuckGo, Brave, Kagi, Startpage). Otherwise they come from DuckDuckGo, because Bing's endpoint is dead.
- Navigation, progress, back/forward gestures, pull to refresh, collapsing toolbar done the no-relayout way.
- Content blocking (EasyList + EasyPrivacy + tracker list), HTTPS upgrade.

**M2 — Tabs**
- Tab gallery with the custom snapshot open/close animator, flick to close, bar-swipe switching on the expanded pill (live or 2x neighbour preview), swipe up to the gallery, new-tab card.
- Toolbar: bottom inset follows the bar's resting state, interruptible velocity-aware snap, one shared glass container.
- Tab tiers, thumbnails, session restore after kill, recently closed, auto-archive + searchable archive.
- Private tabs (non-persistent store, no history).

**M3 — Duo layouts**
- Adaptive shell for every state in section 6, split tabs with one focused pane, fold safety, per-window state.
- Sidebar Hidden / Rail / Expanded; pills off the fold and the inner camera.
- Tab layout setting: regular tabs everywhere (card gallery outside, even-column grid inside) and side tabs on the inner screen only, gated by regular/regular size classes.
- Verified on the Duo in outer, inner landscape, inner portrait and partial fold; plus 375 / 402 / 440 pt simulators.

**M4 — P0 completeness**
- Popups, `window.open`, OAuth/SSO child tabs (Safari-like user agent so Google sign-in works).
- Downloads (`WKDownload`, Files-visible folder, Quick Look), file uploads/camera, camera/mic/location prompts remembered per site.
- JS alert/confirm/prompt, HTTP auth, cert-error interstitial, custom scheme confirmation, universal-link hand-off.
- Find in page, share sheet, link context menus + previews, desktop mode per site, page zoom, PDFs, inline video + PiP + fullscreen.
- Crash recovery, clear website data.

### After your review (v0.2+)

- Reader mode, Apple Translation (in-page, on-device), print/PDF export, per-site settings, cookie banners, dark mode for sites.
- Bookmarks UI, reading list, tab groups, profiles.
- App Intents / Shortcuts, Spotlight, search widget, Control Center control, Handoff.
- Supporting pane, "Open in New Window".
- On-device AI (section 8).
- Web-browser entitlement (default browser, passkeys, service workers) once Apple grants it.

## 8. On-device AI (later, optional)

- Engine: Apple Foundation Models. On this class of device it runs Apple's 20B sparse model at ~70–86 tok/s with no download. Not frontier for knowledge, strong for summarize/extract/structure.
- Features: summarize page (Readability first, map-reduce over chunks, streamed bullets, prewarm on page load), ask the page (chunk + embed + retrieve), smart tab titles, translation via Apple's Translation framework (not an LLM).
- Browse for Me: results come from a search results page read in a hidden tab, with no API key: DuckDuckGo's lite page by default, the user's engine when it works (owner's choice, 2026-11-26). Fetch the top 5 pages on the phone, extract, synthesize on-device with citations. A Brave Search API key can be added later as an opt-in.
- Optional "Deep" mode: Qwen3.5-4B via MLX (~3 GB download) behind the same `LanguageModelSession` interface. Per-app memory ceiling is ~6 GB, so 4B at 4-bit is the limit.

## 9. How the overnight build runs

- I orchestrate from this Mac, one implementation agent per milestone, in order (M0 to M4). I review each milestone's diff before it merges.
- Machines: the Mac paired with the Duo does all device installs and on-device perf tests. Other build Macs only add simulator and build capacity. They are shared with other work, so check load and running simulators before using one, work in your own build folder, and never touch other simulators or folders.
- UI framework choice (reviewed 2026-11-26): no TCA, because its per-event store actions add overhead on scroll and gesture paths. Not all-SwiftUI, because the web view is UIKit anyway and the hot paths need direct control. Optional proof: in M2, build the tab gallery in both UIKit and SwiftUI and keep whichever passes the hitch budget.
- Every milestone must pass: `swift test`, simulator UI smoke tests (outer + inner + regular iPhone sizes), perf gate on the Duo, then install on the Duo and take screenshots of both screens.
- Each passing milestone gets installed, so the Duo always holds the newest working build.
- If a milestone fails its gate after a few fix attempts, I stop at the last good build and write down exactly what failed.
- Morning: a short report with what shipped, budget numbers per milestone, screenshots, and known issues.

## 10. Risks

- **Web-browser entitlement**: Apple grants it by hand; unclear for non-App-Store apps. Without it: no default-browser setting, passkeys only on owned domains, no AutoFill Passwords button on web login fields, no service workers. Everything else works. See `docs/research/sign-in.md`.
- **Password AutoFill**: needs the entitlement in practice (measured on the simulator); no third-party browser can trigger "Save password?". Test on device.
- **Web Push**: not available in WKWebView.
- **Extensions**: `WKWebExtension` exists, but there is no store access. Deferred.
- **Overnight scope**: M0–M4 is a lot for one night. Order is chosen so a stop at any milestone still leaves a usable browser.
- Unverified until measured on the Duo: WebContent memory limits, cheapest snapshot method, preconnect gain, two-window behavior on close.

## 11. Decisions needed from you

1. **Name.** DECIDED: Plain Browser (home-screen label "Plain"; plainbrowser.com + plainbrowser.app free; bundle id dev.abrahamgonzalez.plainbrowser). Icon + color identity in progress.
2. **Default search engine.** DECIDED: a Settings option, like Arc. Google is the first-launch default.
3. **Go for overnight scope M0–M4** as written.
4. **Tonight, on the Duo:** plug it in, stay on home Wi-Fi, set Auto-Lock to Never (Settings > Display & Brightness > Auto-Lock). Perf tests need it awake and unlocked.
5. **Later:** file the web-browser entitlement request (I prepare it, you submit).
