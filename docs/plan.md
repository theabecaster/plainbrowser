# Plain Browser — build plan

Status: approved 2026-11-26. Build in progress.
Inputs: 7 research reports (WebKit performance, motion/feel, feature completeness + reference browsers, on-device AI, stack/build pipeline, iPhone Duo design, naming).

## 1. Bottom line

Build a UIKit-shell browser on `WKWebView`, designed Duo-first, with performance gates that fail the build on regressions.
Overnight target: a daily-usable v0.1 on the Duo (search-first launch, tabs, gestures, Duo split tabs, blocking, history, all P0 edge cases).
Reader, translation, AI, widgets and polish come in follow-up passes after you test it.

Correction from research: Arc Search was not fully pulled from iOS. Its AI features, sign-in and sync were switched off on 2026-11-23, and the app lives on as a "lite" browser. Desktop Arc ends 2026-12-22.

## 2. Goals and hard budgets

The build fails if a budget is broken. Budgets are measured on the Duo, never the simulator.

| Metric | Budget | How measured |
|---|---|---|
| Cold launch to a focused search field | < 300 ms target, fail at 400 ms | `XCTApplicationLaunchMetric` + signpost when the field becomes first responder |
| Hitch ratio (scroll, tab gallery, transitions) | < 5 ms/s, fail at 10 ms/s | `XCTHitchMetric`, `XCTOSSignpostMetric`, `xctrace` Animation Hitches |
| Frame rate | 120 Hz on all motion | `CADisableMinimumFrameDurationOnPhone`, `CAFrameRateRange(80,120,120)` for big motion |
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
| Deployment target | iOS 27.1 | All Duo APIs start there. Duo runs 27.3. |

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
   | Live | visible + ~3 recent (2 visible on the Duo split) | full `WKWebView` |
   | Suspended | next few | detached, `inactiveSchedulingPolicy = .suspend` |
   | Discarded | the rest | `interactionState` + sessionStorage blob + thumbnail |

   On a memory warning, everything except visible tabs drops to Discarded (Firefox's fix for 7.8M watchdog kills).
3. **Thumbnails:** taken once when a tab leaves the screen, `snapshotWidth` ~200 pt, written off-main, decoded with `byPreparingForDisplay`. Never per cell. Full-size snapshots cost 70+ MiB.
4. **Collapsing toolbar without page relayout:** set `obscuredContentInsets` once to the collapsed size and change it only when the bar settles. Animate the bar with `transform`/`alpha` only. Set `setMinimumViewportInset(_:maximumViewportInset:)` so CSS `svh`/`lvh` stay stable. Drive it from the scroll-view delegate, not KVO.
5. **Crash recovery:** `webViewWebContentProcessDidTerminate` reloads the visible tab (crash-loop guard), flags background tabs to reload on select.
6. **Speed tricks:** preconnect on link touch-down (injected `<link rel=preconnect>`), back-forward cache on, HTTPS upgrade via `preferredHTTPSNavigationPolicy`, JIT left on (`securityRestrictionMode = .none`).

## 4b. Product principle: opinionated and simple

Plain is a fast, opinionated browser. It makes the decisions so users don't have to.

**The Settings screen holds these items and nothing else:**
- Search engine. Google by default, plus the popular engines and a custom one.
- Tab layout: Regular or Side tabs. Only shown where side tabs are possible.
- Archive tabs after: 12 hours, 1 day (default), 1 week, or never.
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
- Swipe along the bar to switch tabs; swipe past the last tab shows a "new tab" card first (fixes Safari's no-warning behavior).
- Tab gallery: cards, flick up to close, tap to zoom in.
- Tabs auto-archive after a chosen time (12h / 1d / 3d / 7d / 30d / off), archive searchable.
- Gesture start zones stay out of the bottom 20 pt (Home indicator fights, an Arc complaint).
- Swipe back on a tab's first page goes back, never archives (an Arc complaint).

Motion principles: springs with no bounce by default; bounce only when a flick with momentum drives the motion; every animation can be grabbed mid-flight; nothing blocks input; rubber-band at every edge; haptics only on threshold-cross (selection) and commit (impact); Reduce Motion swaps zoom/slide for a 0.2 s crossfade.

| Interaction | Animation | Parameters | Haptic |
|---|---|---|---|
| URL bar focus | bar grows into search sheet | `.snappy(duration: 0.3)`, bounce 0, follows `keyboardLayoutGuide` | none |
| Switch tab by bar swipe | 1:1 tracking, then spring with gesture velocity | `.spring(duration: 0.35, bounce: 0.12)`, commit at 50% projected travel | selection on commit |
| Swipe past last tab | rubber-band, new-tab card at 80 pt | as above | selection at threshold, light impact on commit |
| Open tab gallery | page zooms into its card | `.spring(duration: 0.42, bounce: 0)`, 80–120 Hz | none |
| Open tab | system `.zoom` transition, interruptible | system | none |
| Close tab | projected throw, cards reflow | close at −40% height or > 800 pt/s; throw `.spring(0.3, bounce 0.15)`; reflow `.snappy(0.3)` | soft impact |
| Pull to refresh | rubber-band, arms at 80 pt | — | selection at arm |
| Toolbar collapse | tied to scroll, snaps at scroll end | `.smooth(0.25)` | none |
| Link preview | `UIContextMenuInteraction` | system | system |
| Fold / unfold | none custom; system bounds change | — | none |

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
| Inner landscape, flat (951×669) | Vertical bar off (Safari's precedent). Collapsible tab sidebar on the leading edge. Each pane has its own top URL pill. Split tabs on demand. |
| Inner portrait (669×951) | System horizontal bars, one pane; stacked second pane off by default. |
| Book pose (vertical fold, partially open) | Split panes snap to the two halves; floating controls avoid the fold region. |
| Tabletop / laptop pose (horizontal fold) | Video or page on top half, controls + tab strip on bottom half. |
| Regular iPhones (375 / 402 / 440 pt) and resizable windows | Same code. Second pane only when width and height are both regular. |

### Tab layouts: side tabs (option) and regular tabs

- **Setting:** Tabs > Layout: "Regular" or "Side tabs". Regular tabs work everywhere. Side tabs apply only where the window is big enough. Elsewhere the app uses regular tabs and keeps the choice, so side tabs come back on unfold.
- **When side tabs are available:** horizontal AND vertical size class are both `.regular`. On phones that means the Duo's inner screen only, in landscape and portrait.
  - Outer screen: compact width, so no side tabs.
  - Inner screen in system Split View: compact width, so no side tabs.
  - Pro Max in landscape: regular width but compact height, so no side tabs. Checking width alone would wrongly allow it here.
  - iPad and iOS 27 resizable windows follow the same rule.
- **Why not screen size:** Apple's Duo guidance says never use `UIScreen.main`, the device type or orientation for layout. `UIScreen` is ambiguous with two screens, and iOS 27 windows can be resized. Size classes on the window scene's traits are the supported signal.
- **Mechanics:** read the root view controller's `traitCollection`, and use `registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self])` to switch the layout. The switch rides the system's fold/unfold bounds animation, with no custom animation and no web view reload. A minimum-width guard of about 640 pt protects against future odd sizes.
- **Side tabs design (inner screen):**
  - Collapsible leading sidebar of about 260 pt, with pinned favorites on top and a tab list below (favicon + title).
  - Collapse with a swipe or button. It also collapses on its own in inner portrait when the page needs the width.
  - Drag tabs to reorder, or drop one on the other pane to split.
  - It works with the split panes: the sidebar plus up to two pages.
- **Regular tabs on the Duo:**
  - Outer screen: Arc-style card gallery with flick-to-close and bar-swipe switching.
  - Inner screen: a grid with an even number of columns (2 or 4), so no card sits on the fold. It uses the same zoom transitions and gestures.

Built with: one `UIArrangementViewController` (`.split.axes(.horizontal)`) holding the two web panes; `reservedRegions(kind: .division, options: .includeInactive)` to reserve fold space ahead of time; `verticalBarEdge` + `UIView.LayoutRegion.bar(onEdge:)` for the side bar; `windowScene.displayLink` for 120 Hz.

Duo features, ranked:
1. Adaptive shell across all states (table above).
2. Fold-safe: same `WKWebView` objects stay in the same parents, only frames change; final frame set once, transient sizes ignored, heavy work after ~150 ms settle.
3. Split tabs across the crease: "Open in other pane" from the link menu, drag a tab to the other pane, swap panes, long-press to move. A tab moves by re-parenting its web view under a snapshot cover, no reload.
4. Supporting pane (~30%, 250 pt min): reader, find results, history or (later) summary next to the page.
5. Desktop pages by default on the inner screen (content mode chosen at navigation start from pane width; never switched on fold, which would force a reload).
6. Tabletop video (later; check whether WebKit's fullscreen player adapts on its own first).

Dropped: outer-screen "peek" (no API), hinge gestures (gimmick).

## 7. Features and milestones

### Overnight (v0.1, in order; each milestone ends with build, tests, perf gate, install, commit)

**M0 — Skeleton and pipeline**
- Repo, XcodeGen spec, package targets, signing with team R2PVQ496X7.
- Scripts: `build.sh`, `install-duo.sh` (devicectl install + launch), `shot.sh` (device screenshot per screen), `perf-gate.sh` (xcresult metrics vs budgets).
- Launch-time and hitch tests running on the Duo from the first milestone.

**M1 — Core browsing**
- Search-first launch, URL bar with intent rules (URL vs search), search suggestions, history + favorites (GRDB FTS5), favorites above the keyboard.
- Search engine picker in Settings (Google by default). Engines: Google, DuckDuckGo, Bing, Brave Search, Kagi, Ecosia, Startpage, Yahoo, Perplexity, ChatGPT, plus a custom engine (any URL with `%s`). Suggestions come from the engine's own endpoint where one works (Google, DuckDuckGo, Brave, Kagi, Startpage). Otherwise they come from DuckDuckGo, because Bing's endpoint is dead.
- Navigation, progress, back/forward gestures, pull to refresh, collapsing toolbar done the no-relayout way.
- Content blocking (EasyList + EasyPrivacy + tracker list), HTTPS upgrade.

**M2 — Tabs**
- Tab gallery, flick to close, zoom open, bar-swipe switching, new-tab card.
- Tab tiers, thumbnails, session restore after kill, recently closed, auto-archive + searchable archive.
- Private tabs (non-persistent store, no history).

**M3 — Duo layouts**
- Adaptive shell for every state in section 6, split tabs, fold safety.
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
- Supporting pane, tabletop video.
- On-device AI (section 8).
- Web-browser entitlement (default browser, passkeys, service workers) once Apple grants it.

## 8. On-device AI (later, optional)

- Engine: Apple Foundation Models. On this class of device it runs Apple's 20B sparse model at ~70–86 tok/s with no download. Not frontier for knowledge, strong for summarize/extract/structure.
- Features: summarize page (Readability first, map-reduce over chunks, streamed bullets, prewarm on page load), ask the page (chunk + embed + retrieve), smart tab titles, translation via Apple's Translation framework (not an LLM).
- Browse for Me: needs search results. Options: Brave Search API (~$5/month credit, fully allowed) or self-hosted SearXNG on a home server (free). Fetch top 5 pages on the phone, extract, synthesize on-device with citations.
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

- **Web-browser entitlement**: Apple grants it by hand; unclear for non-App-Store apps. Without it: no default-browser setting, passkeys only on owned domains, no service workers. Everything else works.
- **Password AutoFill**: suggestions work in WKWebView; saving new passwords is flaky. Test on device.
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
