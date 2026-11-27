# Decisions

Each entry: what was chosen, and why. Newest last.

## UIKit shell, SwiftUI for leaf screens, no TCA (2026-11-26)

- **Chosen:** the shell (URL field, web views, tab gallery, gestures, transitions) is UIKit.
  Low-frequency screens (settings, history, bookmarks) are SwiftUI in `FeatureUI`, hosted with
  `UIHostingController`.
- **Why not all SwiftUI:** the page is a UIKit `WKWebView` either way. SwiftUI's `WebPage` lacks
  popups, downloads, `interactionState`, snapshots and scroll-view access. The hot paths (scroll,
  tab switching, gallery) need direct control of layers and gesture timing, and SwiftUI still
  hitches more there.
- **Why not TCA:** every gesture and scroll event would go through store actions and state diffs,
  which costs time on the paths we budget most tightly. Plain types, `@Observable` and async/await
  cover what we need.

## GRDB for storage (2026-11-26)

- **Chosen:** GRDB.swift 7 (MIT), the only third-party dependency so far. Used only by `Storage`.
- **Why:** SQLite with FTS5 gives the omnibox full-text search over history (budget: p95 < 16 ms
  on 100k rows). GRDB's async reads and writes run on its own queue, never the main thread, and
  its types are `Sendable` for Swift 6.
- **Why not SwiftData or Core Data:** no full-text search, and SwiftData degrades past ~100k rows.
- **Perf cost:** statically linked; nothing opens the database at launch in M0.

## XcodeGen and one local package (2026-11-26)

- **Chosen:** `project.yml` generates `Plain.xcodeproj` (not tracked). All code lives in
  `Packages/PlainKit`, one target per module.
- **Why:** a readable spec instead of `.pbxproj` merges, which matters with several agents working
  at once. Package targets enforce the one-way layering at compile time. Small targets keep
  incremental builds fast, and the core targets test on macOS with `swift test` in seconds.
- **Cost:** `swift test` builds every target on macOS, so UIKit files are wrapped in
  `#if canImport(UIKit)`. Test plans name the UI test target by XcodeGen's generated ID, which is
  stable as long as the target name does not change.

## Launch screen is a plain color, not the brand gradient (2026-11-26)

- **Chosen:** `UILaunchScreen` shows `LaunchBackground`, the same color as the first frame
  (`Palette.background`).
- **Why:** launch is search-first and budgeted at 300 ms. A gradient-and-mark launch screen
  (Brand/identity.md) would flash into a different-looking first frame. Revisit in polish, with the
  first frame designed to match.

## Signpost names in their own module (2026-11-26)

- **Chosen:** `PerfSignposts` holds the subsystem, category and names. The app and the UI test
  target both link it.
- **Why:** an `XCTOSSignpostMetric` with a misspelled name measures nothing and passes. Sharing the
  constants makes that impossible.

## Perf gate on simulators until device checks start (2026-11-26)

- **Chosen:** `scripts/perf-gate.sh` defaults to a simulator (`plain-perf-duo`). There it fails on
  a test failure or a regression of more than 20% against the previous `sim` row in
  `docs/perf-log.md`. The absolute budgets in `perf/budgets.json` apply only with `--device`.
- **Why:** simulator numbers are not comparable to device budgets, but tracking them per change
  builds the habit and catches large regressions until the device runs the gate.

## Content blocking lists (2026-11-26)

- **Chosen sources, all bundled as generated WebKit JSON:**

  | List | License | Why it is allowed |
  |---|---|---|
  | EasyList | GPL-3.0-or-later or CC BY-SA 3.0+ (dual) | We use the GPL option; GPLv3 combines with AGPL-3.0 (GPLv3 §13). |
  | EasyPrivacy | same as EasyList | same. |
  | EasyList Cookie List (`fanboy-cookiemonster.txt`) | CC BY 3.0 (its own header) | Permissive with attribution; kept in `NOTICE.txt`. |

  Sources, versions and attribution ship in `ContentBlocking/Resources/BlockLists/NOTICE.txt`.
- **Not bundled:** DuckDuckGo's tracker blocklist (TDS) data is CC BY-NC-SA 4.0. The
  non-commercial term is not compatible with the AGPL, so the tracker rules come from EasyPrivacy
  instead. (TrackerRadarKit's code is Apache-2.0, but it is only useful with that data, so it is
  not a dependency.) uBlock-only and ABP-only lines (`!#if` blocks, `!#include`) are skipped.
- **Converter:** AdGuard SafariConverterLib 4.3.1 (GPL-3.0), pinned exactly, run at build time by
  `tools/blocklists` (its own Swift package). It is never linked into the app, which keeps the
  plan's "no AdGuard converter in the app". Its own dependencies (swift-argument-parser
  Apache-2.0, PunycodeSwift MIT, swift-psl MIT with Mozilla's PSL data MPL-2.0) are build-time only.
  Rerun `tools/blocklists/generate.sh`; output is byte-identical for the same downloads
  (`SWIFT_DETERMINISTIC_HASHING=1`), so an unchanged list keeps its hash and is never recompiled.
- **Split into lists of at most 35k rules, by value (2026-11-26, design audit).** All three
  lists are converted together, as one Adblock list would be, and every list gets all exception
  lines (`@@`, `#@#`, `$badfilter`), because WebKit's `ignore-previous-rules` only reaches rules
  in the same compiled list. The lists come out in three groups:
  1. `blocklist-01` (`FixedChoices.priorityBlocklist`): filled to 35k rules with the
     highest-value network rules: third-party domain blocks from EasyList and EasyPrivacy, then
     EasyPrivacy's other domain blocks, then its other network rules. It compiles first, so a
     first launch blocks trackers after about 0.8 s instead of after every list.
  2. `blocklist-02` (`FixedChoices.cosmeticBlocklist`): every cosmetic rule (47.5k lines become
     15.7k rules, 13.7k `css-display-none`). One hide stylesheet per frame; cosmetic churn
     recompiles one list. The tool fails if they stop fitting in one list.
  3. The rest of the network rules, dealt round-robin into even parts.
  Result: 5 lists, 134.7k rules, 16 MB of JSON. Cold compile per list on the iOS 27.2 simulator
  (iPhone 17, `ContentBlockerTests.compileTimePerList`): 01 35k rules 0.84 s, 02 15.7k cosmetic
  1.61 s, 03–05 28k each 1.10–1.17 s; all five 5.9 s.
  - Measured on the iOS 27.2 simulator (iPhone 17), cold compile per list, alone: 25k rules
    1.0–1.7 s, 35k 1.8–2.8 s, 45k 2.2–3.8 s, 70k 3.5–3.9 s, one 126k list 5.6 s. Every size
    reloaded (lookup from a new process) in under 3 ms, so the iOS 18 failure above 45k did not
    reproduce on the simulator. 35k keeps a 10k margin under that reported limit with only 4
    lists. Check on the device.
- **Compile only when missing, never at launch.** Identifier `<name>-<first 16 hex of SHA-256>`.
  `ContentBlocker.prepare()` looks each list up (about 1 ms for all 4, warm) and compiles only a
  miss: first launch and app updates that change a list (about 6–9 s for all 4 on the
  simulator, off the main thread; WebKit compiles on its own queue). While new lists compile,
  the previously compiled `blocklist-*` lists stay attached as stand-ins, so an update never
  leaves pages unblocked; when every new list is in, they are detached in one step and removed
  from the store (all at once, because an update can move rules between lists). After a failed
  compile the stand-ins stay and the next launch retries. (DuckDuckGo's `LastCompiledRulesStore`
  does the same.)
- **Per-site off detaches the lists instead of adding an allow-list rule list.** Measured: a
  separate list with `ignore-previous-rules` for a domain does not unblock rules in other lists
  (WebKit evaluates each compiled list on its own). Appending the allow-list to every list would
  mean recompiling all 135k rules on each toggle. So `ContentBlocker.apply(to:forMainFrameURL:)`
  removes the lists from that web view's `WKUserContentController` on an allowed site and adds
  them back on any other. This needs one `WKUserContentController` per web view (a WebEngine
  follow-up); on a shared controller it would turn blocking off in every tab. The allowed sites
  persist through the small `SiteAllowListStore` protocol, which a Storage adapter implements.
- **Perf cost:** 16 MB of JSON in the app bundle (about 8x smaller compressed in the IPA). The JSON is
  read only to compile, never on a warm launch.

## Shell chrome: bottom pill, vertical bar, no-relayout collapse (2026-11-26)

- **Chosen:** the root is a `UINavigationController` with its navigation bar hidden. The page
  buttons are its toolbar items with `axisBehavior = .verticalPreferred`, and the toolbar shows
  only where `verticalBarEdge` is not `.unspecified`.
- **Why:** only bars a navigation or tab bar controller owns move into the Duo's vertical bar; a
  custom view or standalone `UIToolbar` never does (Apple's vertical bar guidance). Checked on the
  iOS 27.2 Duo simulator: the four items land in the trailing column, with the keyboard up too.
- **Elsewhere a custom glass bar, not the system toolbar:** hiding a system toolbar changes the
  page's safe area, which relayouts the page on every collapse. The custom bar moves by transform
  and alpha only. The page's bottom `obscuredContentInsets` follows the bar's resting state,
  switched once per snap (never during the top bounce), so the expanded bar never covers
  fixed page footers (docs/plan.md, engine rule 4; docs/research/design-audit.md).
- **Address bar data behind a protocol (`AddressBarData`):** the shell never touches GRDB or the
  network. `LiveAddressBarData` joins Storage, settings and `SuggestionClient`; tests and later
  wiring (tabs, private mode) can swap it.
- **Desktop Site (stopgap):** a desktop Safari user agent on the tab's web view, until WebEngine's
  navigation delegate sets `preferredContentMode` per navigation and the choice is remembered per
  site.
- **ATS:** `NSAllowsArbitraryLoadsInWebContent`, because a browser opens http pages. The app's own
  requests (suggestions) stay under ATS.
- **Perf cost:** DesignSystem links SwiftUI for `UIView.animate(_: Animation)` (system framework,
  in the shared cache). No work added before the first frame: the database opens off main after
  the window shows, and haptic generators and the suggestion client are made on first use.

## Integration 1: sheets, live settings, one history writer (2026-11-26)

- **ShellUI imports FeatureUI.** The shell presents Settings, History and the favorites editor,
  so it builds their models (`FeatureSheets`). Both are UI-layer targets and FeatureUI never
  imports ShellUI, so the graph stays one-way. The app target stays a thin wrapper.
- **`AppDatabase` owns the one `HistoryRecorder`.** The recorder writes through the database's
  `DatabaseWriter`, so the database can hold it without a reference cycle. Its public history
  deletes (`deleteHistory(for:)`, `clearHistory(since:)`) go through it, which lets
  `AppDatabase` conform to `HistoryStoring` directly while a delete still drops visits waiting in
  the buffer. The conformance is in an extension because the declaration form hits a compiler bug.
- **Visits are recorded per back-forward item, at load end.** KVO on `isLoading`, deduplicated by
  `backForwardList.currentItem`, until WebEngine's navigation delegate reports commits (Lane C).
  Reloads and same-document (pushState) changes are not new visits for now.
- **Settings reach the shell after each save,** through a `SettingsStoring` adapter, rather than a
  re-read when Settings closes, so the order of saves is the order they apply.

## Deployment target iOS 27.2 (2026-11-26)

- **Chosen:** iOS 27.2, up from 27.1, because `UIView.LayoutRegion.bar(onEdge:)` (Duo vertical bar layout) needs 27.2.

## Reader: Mozilla Readability 0.6.0, own content world, no reader settings (2026-11-26)

- **Chosen:** `mozilla/readability` 0.6.0 (latest release, 2025-03-03), Apache-2.0, bundled
  unmodified as `Reader/Resources/Reader/Readability.js` and `Readability-readerable.js`, with
  its license (`Readability-LICENSE.md`) and attribution (`NOTICE.txt`) shipped next to them.
  Apache-2.0 code may be combined into an AGPL-3.0 work (Apache-2.0 is GPLv3-compatible).
  SHA-256: `Readability.js` 34dcab3d…f174, `Readability-readerable.js` a98d2880…de65.
- **Why Readability:** it is what Firefox uses, it is maintained, and it has a large test corpus.
  Plain's tests use four of its saved pages (`Tests/ReaderTests/Fixtures`, from the same
  release's `test/test-pages`) and its expected titles and bylines.
- **Isolation:** it runs only in the `WKContentWorld` named in `ReaderWorld`, never the page
  world, so page scripts cannot see or replace it.
- **Two steps, so browsing pays almost nothing:** only `Readability-readerable.js` (about 4 KB)
  runs on every page, as a main-frame user script at document end (DOMContentLoaded). It runs
  `isProbablyReaderable` and posts "reader available" to `ReaderExtractor.onAvailability`. The
  full `Readability.js` (about 90 KB) is injected into that document's reader world only when
  the user opens reader mode, and the article is kept for repeat opens of the same page.
- **Main thread:** the page returns one JSON string; decoding runs `@concurrent`. Bundle reads and
  template rendering run `@concurrent` too.
- **Sanitizing:** Readability is not a sanitizer (its SECURITY.md says so). Before the article
  leaves the page, the reader world cleans it in an inert `<template>`: no `meta`, `base`, frames,
  plugins, forms, styles or SVG animation, no event handlers or inline styles, and no
  `javascript:`/`data:` URLs except `data:` images. The reader page adds a second layer: page
  JavaScript off and a CSP with `default-src 'none'`, `base-uri 'none'` and `form-action 'none'`.
- **Reader view:** a template and stylesheet served from the `plain-reader:` scheme, with page
  JavaScript off and a content security policy that allows no scripts. No reader settings: text
  size follows Dynamic Type (`-apple-system-body`), colors follow light and dark mode, the
  measure is 66ch, and Lagoon Blue marks links, quotes and the header rule. Link text keeps the
  body color, with the accent as the underline, because #2973FF on the paper background is
  about 4:1, under the 4.5:1 body-text minimum.
- **Perf cost:** a 4 KB check per page load, off the main thread in the web content process.
  94 KB of JavaScript in the bundle, read on first use. Simulator (iPhone 17, iOS 27.2): opening
  reader mode extracts in 7–68 ms including the Readability injection (most pages 7–18 ms); a
  non-article page returns nil in about 4 ms; a repeat open of the same page is under 1 ms;
  rendering and loading the reader page about 50 ms warm.

## Web engine: tab tiers, handlers and seams (2026-11-26)

- **The pool owns every web view; tabs never hold one.** `WebViewPool` keeps a slot per tab with
  a web view (web view, its own `WKUserContentController`, delegate, KVO). The shell's `TabStore`
  owns `Tab` objects; the pool holds them weakly. The shell shows a page with
  `attach(_:to:)` (adds the web view to a container it owns) and never sees the `WKWebView`.
- **One configuration copy and one `WKUserContentController` per web view**, sharing one website
  data store. Content blocking's per-site off detaches lists from a single controller (see
  "Content blocking lists"). Popups take the configuration WebKit passes in (or `window.opener`
  breaks) and get a fresh controller on it; `window.opener` still works (tested).
- **Tiers:** live = attached; suspended = detached with a web view, up to 8 web views in all
  (`EngineChoices.maxWebViews`), most recent first; the rest are discarded to `interactionState`
  plus sessionStorage (~1 KB each in tests), kept in the `Tab` and written to Storage's
  `TabStateStore` as a binary plist. No per-tab `inactiveSchedulingPolicy`: copied configurations
  share one `WKPreferences`, so a per-tab value is really global and each write sends a
  preferences update to every WebContent process (design audit). WebKit's default `.suspend`
  applies to every detached page. Attaching during an in-flight discard cancels it.
- **Never discarded:** tabs playing media (picture in picture included), capturing camera or
  microphone, in fullscreen, or with a download running; they are kept beyond the limit.
- **Saved for relaunch continuously**, not only on discard: `interactionState` 1 s after each
  main-frame finish or detach (UI-process data, wakes nothing), and every tab with sessionStorage
  on `willResignActive` inside a background task. Writes are serialized per pool.
- **Every WebKit reply has a 400 ms timeout** (`fetchData`, `restoreData`, `takeSnapshot`): a
  frozen or killed process may never answer. A memory-warning discard skips the sessionStorage
  fetch so it wakes no suspended process.
- **Restore checks itself:** if `interactionState` does not decode (WebKit drops it silently), the
  saved URL loads instead. A page that was a form result (POST) asks the shell before sending the
  form again; on "no" history comes back and `tab.isAwaitingResubmit` waits for a reload.
- **A killed process is not always a crash.** A hidden tab's process kill (iOS reclaims suspended
  processes) discards the tab, so it restores in place. A visible tab reloads at once, or when the
  app is active again; only those reloads count toward the crash-loop limit.
- **`window.close()`** closes only tabs a page opened.
- **Scroll restore lag (measured):** WebKit copies the scroll position into the history item a few
  hundred ms after scrolling stops (not at 200 ms, always by 350 ms on the simulator). A tab
  discarded within that window comes back at its previous scroll position. Real discards hit tabs
  hidden far longer, so no workaround.
- **Warm-up:** `loadHTMLString("")` on the warm web view leaves no back/forward item (measured),
  so the first tab's Back never goes to a blank page.
- **KVO only where WebKit has no delegate signal:** `url`, `title`, `canGoBack/Forward` (same-
  document navigations), `isLoading`, `estimatedProgress`, `hasOnlySecureContent`. Security and
  errors come from navigation delegates. Progress is outside observation (`Tab.onProgress`).
- **Desktop or mobile is decided at navigation start** from the pane (container bounds, else
  `defaultPaneSize`): shorter side ≥ 600 pt is desktop (Duo inner screen yes; outer screen, split
  half, phone landscape no). Never switched on resize. Desktop mode also sets `customUserAgent`
  to Mac Safari's, because WebKit appends `applicationNameForUserAgent` (`Mobile/15E148`) even in
  desktop mode (measured).
- **Navigation handlers split by concern**, after DuckDuckGo's `apple-browsers` navigation
  middleware (Apache-2.0): an idea only, no code copied. Pure policy lives in `NavigationRules`.
- **Abuse limits** (popups 2 per 2 s, dialogs 5 per 20 s, external apps 2 per 10 s per tab) follow
  firefox-ios `PopupThrottler` (MPL-2.0): idea and numbers only, no code copied.
  `javaScriptCanOpenWindowsAutomatically = false` makes WebKit ask only for gesture popups.
- **Universal links: left to WebKit.** `.allow` on a tapped navigation already makes WebKit try
  the app link (design audit), so the engine adds no check and no wait on link taps. No private
  "allow without app link" policy is used.
- **Certificate errors:** the shell shows the interstitial; "visit anyway" trusts that exact leaf
  certificate for the host until quit, then reloads. Nothing is persisted.
- **Seams:** Storage's concrete `TabStateStore` (no protocol needed). New protocols where Storage has
  nothing yet: `SitePermissionStore` (async), `SiteContentModeStore` (sync, in-memory map, because
  it is read on every navigation start), `UserContentRules` (`ContentBlocker` already matches it).
  In-memory defaults exist for both stores, also usable for private tabs.
- **Permissions in tests:** in a hostless test process WebKit never calls the camera or location
  delegate (no app authorization), so the pool's remember-per-site logic is tested directly.
- **Thumbnails at 2 px per point** of the card width (400 px wide), not the screen's 3x: 2.25x
  fewer pixels in memory and on disk. The snapshot starts before the view leaves the window.
- **Downloads keep running in the background** inside `beginBackgroundTask` while any is active.
- **Perf (iPhone 17 simulator, iOS 27.2, loaded machine):** attach a live tab median 1.4–1.5 ms;
  discard 0.3 ms without the sessionStorage fetch, 6.5–15 ms with it; restore a discarded tab:
  attach call 4–20 ms, page back 400–490 ms (new WebContent process, local server), scroll back
  with it; thumbnail snapshot 0.75 ms main-thread wait, JPEG encode + write 2–3 ms off main;
  thumbnail read + decode from disk 23–53 ms off main.

## Toolbar snap, page inset and glass container (Lane H, 2026-11-26)

- **The snap runs frame by frame, not as a Core Animation spring.** `SpringDriver` (DesignSystem)
  samples `Motion.toolbarSnap` (`Spring.smooth(0.25)`) from a `UIUpdateLink` tied to the view,
  with `CAFrameRateRange(80, 120, 120)`, and applies transform and alpha. Why: the value on screen
  is always known, so a drag that starts mid-snap continues from it with no jump and no
  presentation-layer reads, and a retarget keeps the current velocity. UIKit's
  `UIView.animate(Animation)` has no frame-rate range, so this is also where the 120 Hz request
  lives. Cost: two transforms and an alpha per frame on the main thread for 0.25 s, the same work
  the scroll already does 1:1.
- **Snap starts at release** (`scrollViewWillEndDragging`), toward the release velocity when it is
  clear (0.2 pt/ms), with the bar's own speed under the finger carried over (capped at 8 progress/s).
  It runs alongside the page's deceleration; coasting into the top brings the bar back. A page
  that starts loading under the finger brings the bar back when the finger lifts, so the drag
  keeps the bar. Under Reduce Motion the snap is a 0.2 s crossfade of the chrome.
- **Page inset follows the resting bar** (plan, engine rule 4): `PageInsetState` switches
  `obscuredContentInsets.bottom` between the collapsed and expanded chrome once per rest, and
  waits while the page is pulled past its top or bottom; a new snap drops a change still waiting.
  A reveal (the inset grows) switches it as the snap starts instead (follow-ups, 2026-11-27). WebKit already extends a fixed footer's
  background to the screen edge under the bar (measured on the simulator).
- **One glass container, no shadow.** `Glass.makeContainer` wraps `UIGlassContainerEffect` in a
  view that passes touches through, so it can cover the screen. Merge spacing 4 pt, under the
  6 pt gap, so the resting pill and bar stay two shapes.
- **Scroll edge effect per control.** An interaction on the full-screen container stretched the
  edge effect over the whole page (seen with the hard style), so the pill and the bar each carry
  one. WebKit hides the bottom effect itself where it shows a fixed footer's color extension. The
  style is `.hard`: the page area under the resting bar is obscured anyway (the inset follows the
  bar), and an opaque edge stops body text refracting through the glass. The soft style left that
  text legible as ghost lettering in the pill (design review, rounds 1 and 2), and `.automatic`
  showed no effect at all on WebKit's scroll view. The hard edge follows the collapsed pill too.
- **Glass tint 0.88 (light) / 0.84 (dark), up from 0.78 / 0.72:** the design review saw body
  text refracted through the pill as ghost lettering; the denser paper tint keeps the host legible.
- **Collapsed pill: taps only.** `AddressPill.isCompact` turns away every recognizer except its
  own tap, and the page menu waits for the expanded pill.

## Tab model and persistence (2026-11-26)

- **`TabStore` in BrowserCore, values only.** It holds `TabEntry` values (id, URL, title, opener,
  pin, private, times, thumbnail file) keyed by `TabID`, not engine `Tab` objects, so every rule
  is tested on macOS. The shell keeps engine tabs in step by id. Page state stays in the engine's
  `Tab` (one owner); the store only keeps the URL and title it needs for relaunch and archive search.
- **Windows and panes from the start.** Each window has its own tabs and one or two panes with a
  focused one, so M3's split and "Open in New Window" need no model change. A tab is never in two
  panes (one web view).
- **Persistence through one seam, `TabPersistence`.** `enqueue` is synchronous and ordered (a lock
  and a buffer, no actor hop, so changes never reorder); a newer session replaces an older one
  still waiting. Writes run off main, 500 ms after the first change, in one transaction, and touch
  only rows that changed (a title change writes one row instead of 100).
  A failed write is retried in place (3 tries, 100 ms apart) so later writes never land first.
  Restoring from the archive is its own change (`unarchive`), so a restored tab leaves the
  archive even when the sessions around it are coalesced away.
- **Archive rows stay in the `tab` table** with `isArchived`, searched through an FTS5 index synced
  to it (diacritics removed, word prefixes). The archive is not loaded at launch.
- **Recently closed is a stack of batches** (one close, Close All Tabs or a closed window), so
  reopen brings back what one action closed, each tab after the tab that preceded it. Its state
  file is kept until the batch leaves the stack.
- **Tab ids are text.** GRDB 7 only honours `databaseUUIDEncodingStrategy(for:)`; the earlier
  `static let` was ignored and stored 16-byte blobs, which raw SQL could not match. No tab rows
  were written by the app before this change.
- **Signposts:** BrowserCore stays Foundation-only, so the shell emits `tab.open/close/select/archive`
  around its calls; Storage emits `tab.sessionLoad` and `tab.save`.
- **Perf (macOS `swift test`, file database, 100 open + 1,000 archived, median of 30):**
  `loadTabSession` 1.5–1.6 ms off main; `TabStore(session:)` 0.14 ms on main (p95 0.17 ms, budget
  5 ms); archive search over 1,000 rows 1.3–1.4 ms.

## Integration 2: the shell on the web engine (2026-11-26)

- **`BrowserSession` wires the engine once.** It builds the pool with Storage-backed stores,
  `ContentBlocker` as its `UserContentRules`, Reader's check as its `PageScripts`, and
  `EngineTabs`, which keeps engine `Tab`s in step with BrowserCore's `TabStore` (the one owner of
  the list) by id. Before the database opens the store is in memory; tabs opened then join the
  loaded session. The app target only passes the database task and the tab-state folder. A plain
  type with initializer injection, no container.
- **Adapters live in ShellUI.** `SitePermissionStore`, `SiteContentModeStore` (WebEngine) and
  `SiteAllowListStore` (ContentBlocking) are implemented over Storage in the shell, the one layer
  that sees both: Storage stores plain strings and never imports the engine. Three tables in one
  migration (`v5.siteSettings`). The content-mode map loads once after launch and answers from
  memory, as the engine reads it at every navigation start.
- **The shell never keeps a page's web view.** It follows the `Tab` with Observation (coalesced
  per run loop turn); the engine reports visits (`Tab.onVisit`, once per back-forward item),
  finds on page and sets insets. `pool.webView(for:)` exists only to hand a page to Reader's
  extractor, which needs a `WKWebView`.
- **The reader view is not a tab.** The pool makes it (`makeAuxiliaryWebView`, same data store
  and identity, no content rules or tab handler) so configuration stays in one place; the shell
  holds it only while it shows and releases it on close (about 2-8 ms to make one again).
  Shown over the page in the same container, so closing it returns to the page untouched.
- **Readerable check installed synchronously.** `PageScripts.install` runs while the pool builds a
  controller, so the 4 KB source is read once off the main thread (`ReaderExtractor.prepare()`);
  the warm web view, made before that read ends, gets the script when it is ready.
- **Last tab restored after the first frame, under the search sheet.** Launch stays search-first
  (docs/plan.md, engine rule 1): the field is focused in the first frame. The last selected tab's
  row and state file are read off the main thread after warm-up; the tab attaches under the
  sheet (taking the warm web view), so closing the sheet shows the page already back. A page the
  user opens before that wins and nothing is restored. Only the selected tab comes back until M2.
- **Desktop Site per site through `setContentModeOverride`.** The desktop user-agent stopgap is
  gone. A choice equal to what the pane picks anyway is stored as no choice, so a site follows
  the pane again (Duo inner vs outer).
- **Blocking toggle reloads.** WebKit applies rule lists per navigation, so "Turn Off Blocking on
  This Site" detaches the lists from every controller at once and reloads the page.
- **Engine questions are system alerts, one at a time** (`PromptQueue`), over any sheet. If an
  alert can't be presented, its safe answer (cancel, deny) returns, so the engine never waits
  forever. Permission answers are remembered per origin by the pool; the app asks iOS only when a
  site first needs camera, microphone or location (usage strings in Info.plist).
- **A page that can't show says so in one sentence** (`PageStateView`): crashed again after the
  engine's reloads, failed to load (Plain's words per error code), or a restored form result
  waiting. One button: Reload or Try Again.
- **Downloads in Files.** `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` make
  Documents/Downloads Plain's folder in the Files app. A finished download says where it is and
  offers Quick Look.
- **Popups become tabs in the store and take the screen** (one tab on screen until M2); Back on a
  popup's first page closes it and returns to its opener.
- **Suggestion preconnect after the first frame.** The launch focus calls `prepareForTyping()`
  before the first frame; the preconnect (and the suggestion client's URL session) waits for
  `firstFrameDidCommit()`. Typed visits (`VisitKind.typed`) are the address bar's loads: an
  address, a search or a picked suggestion; a picked page suggestion is remembered for its input.
- **Restore stops the warm-up load first.** A tab restored at launch takes the warm web view,
  whose empty warm-up page may still be loading while its WebContent process starts (a second on
  a loaded simulator). Committing after the restore, it left a blank page over the restored
  history; the pool now stops any load in flight before applying `interactionState`.
- **Fixed with it:** the geolocation delegate method had the wrong selector
  (`initiatedBy` instead of `initiatedByFrame`), so WebKit never asked; it now does.
- **Perf cost:** after the first frame only. Lookups for compiled rule lists take about 1 ms; the
  content-mode map and the tab restore are single reads off main. No work added before the
  search field is focused.

## Xcode Cloud as the TestFlight fallback, free tier only (2026-11-26)

- **Chosen:** `scripts/testflight.sh --cloud` / `--auto` archive on Xcode Cloud when this Mac is
  busy with builds, tests and perf runs. Local archiving stays the default. Only the 25 compute
  hours a month included in the developer membership are used, never a paid plan.
- **Why Xcode Cloud:** it is the only hosted macOS builder that costs nothing on top of the
  membership. It signs with the team's cloud-managed certificates, so it needs no secrets in the
  repo.
- **Xcode Cloud uploads, internal only.** The cloud build goes straight to TestFlight, so a busy
  Mac does no signing, export or upload. Internal-only builds skip Beta App Review but can't reach
  external groups; those still get local builds.
- **Cost: build numbers.** Xcode Cloud stamps every build it uploads with its own counter
  (1, 2, 3...), which sorts below our `yyMMddHHmm` local builds. App Store Connect accepts it for
  iOS. Setting the next cloud build number above the local ones (App Store Connect only, no API)
  keeps TestFlight in order.
- **Manual start only, guarded.** The workflow has no triggers, so it never spends hours on its
  own. `setup` disables every other workflow, and `start` refuses past 20 hours in the last 31
  days. Without a subscription Apple can't bill: at 25 hours, builds stop until the next month.

## App icon: the Coin mark (2026-11-26)

- **Chosen:** a cream paper ring around the dawn, its top-right edge folded in (coral side up),
  with a short stem that hides a P (`Brand/identity.md`). It replaces the letter-P icon.
- **Why:** the owner wanted a symbol people recognize, not a letter. The P stays as a detail you
  find second. The icon is generated (`Brand/tools/gen_icon.py`) so every change is reproducible,
  and the tinted appearances are tuned so the mark stays crisp on the home screen's tinted styles.
- **Not kept:** the window, page, Duo, loupe, pinwheel, boat and fold concepts from the review
  rounds. They were rendered for review only and never committed.

## M2 shell wiring: tabs, gallery, bar swipe, private tabs (2026-11-26)

- **Every saved tab comes back, none loads.** The whole list is restored at launch; engine tabs
  are made on first use. A saved tab (`pool.makeSavedTab`) holds only its address until it first
  attaches, then reads and decodes its state file off the main thread before restoring. Why: 100
  saved tabs cost 100 small objects at most, and nothing touches disk or WebKit before a tab is
  opened. While the file is being read, nothing may overwrite it with less (saves, discards and
  closes skip that tab).
- **Closing or archiving keeps the state file and thumbnail** (`close(_:keepingSavedState:)`,
  polish backlog M2a): Reopen Closed Tab and archive restore bring back history and scroll. The
  current state is written first. Storage's `TabSessionWriter` deletes files no row names; at
  launch, thumbnails outside `referencedTabIDs()` are pruned at background priority.
- **The bar swipe moves the page, not the glass.** The motion table says a snapshot of the glass
  slides; here the glass stays where it is and only the pill's host label slides inside it (the
  current one out, the neighbour's in). Same rule underneath (never move live glass), cheaper (no
  glass snapshot, which would need a render pass per swipe start), and the bar never seems to
  leave. The neighbour preview is its live web view re-parented into a preview container (no
  reload, cancelled swipes detach it again) or a 2x snapshot taken as it left the screen.
- **The swipe spring runs frame by frame** (`SpringDriver`, `Motion.tabSwitchSpring`), like the
  toolbar snap: the release velocity carries in, and a finger can grab the page mid-flight
  without a jump. Commit at half the projected travel (UIScrollView's normal deceleration).
- **The swipe ends when the page is visibly at rest, not at the spring's settle.** The driver ran
  the spring to within 0.001 pt of the target: on a 400 pt page about 0.85 s, of which the last
  0.5 s moves under a point, while the new tab waited for the hand-off (pill text, touches). Now
  `SpringDriver(restDistance:)` lands on the target once the page is within 0.5 pt and its spring
  velocity covers less than 0.5 pt over the frame (`Signposts.visualSettle`, the gallery's rule),
  then hands off. Velocity, not the last sample's change, so a start near the target with a
  flick's momentum never reads as rest. The jump is below a pixel step the eye can follow. The spring is unchanged (0.35 s, bounce 0.12,
  the motion table's row).
- **One pan recognizer per bar view** decides by its first velocity: sideways switches tabs, up
  opens the gallery (the same `TabGalleryTransition`, finger-driven). It never begins on the
  collapsed pill or during a snap (`acceptsBarGestures`).
- **The gallery is a child view controller over the page**, under the chrome and the search sheet,
  not a presented one: the page's web view stays where it is, so opening a card re-parents nothing
  and Back/Forward state never moves. The chrome fades and slides 24 pt down with the zoom.
- **Opening a card grows the card's thumbnail**, not a live snapshot of the page: the web view was
  just attached under the gallery and may not have drawn; the thumbnail is already decoded in
  memory. The live page shows when the gallery leaves.
- **Private tabs share one non-persistent data store** made with the first private tab and dropped
  (with its data) when the last one closes. Their per-site choices (zoom, Desktop Site,
  permissions) live in memory for that session; reading falls back to the regular choices. No
  state files, thumbnails on disk, history, typed-input learning or remote suggestions.
  `TabStore` already keeps them out of persistence.
- **The private tint is a quiet dusk violet** (`Palette.privateGlassTint`,
  `privateBackground`): on the glass, behind the status bar and in the private gallery. No badge
  or banner (docs/ui-reference.md).
- **The archive runs when both the tab list and the settings are in**, then on each foreground.
  Before an archive pass, hidden tabs with a web view ask WebKit about media, so a tab playing
  sound stays (`isTabInUse` = `Tab.isBusy`).
- **Downloads toast instead of an alert.** A finished download no longer interrupts: a toast says
  so with Show (the Downloads sheet), and the page menu lists Downloads while there are any.
- **Page zoom per site in Storage** (`v6.sitePageZoom`), answered from an in-memory map loaded
  after the first frame, like Desktop Site.
- **Perf cost:** a bar swipe start attaches at most one web view (about 1.5 ms) or adds one image
  view; a tab switch adds one WebKit snapshot of the page leaving (2x, kept only for the two
  neighbours, about 5 MB each decoded). The gallery is built when opened and released when it
  closes. Engine-tab watches are one Observation per tab with an engine tab.

## Tab gallery: the app-switcher cascade on a plain scroll view (2026-11-26)

- **Chosen:** the gallery works like Arc Search's switcher, which copies the iPhone app switcher:
  one row of page-shaped cards, later tabs on top, the left ones bunched and slightly smaller,
  swipe a card up to close, tap to zoom in. Numbers and sources: `docs/research/arc-tab-switcher.md`.
- **Built on a `UIScrollView`, not a `UICollectionViewLayout`.** Every card's position depends on
  the scroll offset, so a collection layout would have to invalidate on every bounds change and
  re-apply attributes to every visible cell each frame. Here the scroll view only supplies the
  physics (deceleration, rubber band, the projected stop rounded to a card), and the gallery
  places its few visible cards itself from `scrollViewDidScroll`: `center`, `transform`, z order,
  a title's alpha and a mask width, no layout pass. Cards are pooled views. Main-thread work per
  120 Hz frame while scrolling 100 tabs: p95 1.6 ms on the simulator.
- **What it costs:** the gallery does its own reuse, prefetch, hit testing (the top card takes the
  touch where cards overlap), VoiceOver order and three-finger scroll, and drag-to-reorder with a
  drop interaction instead of the collection view's. Changes animate with `CardMotion` (one spring
  per moving value, stepped on one update link), so a scroll or a second close joins a running
  reflow without a jump; a diffable data source would animate each change on its own.
- **Regular width keeps a grid, now paged sideways.** Arc has no big-screen layout; the iPad app
  switcher is a sideways grid. Four columns by two rows in landscape (two by two in portrait), one
  page per flick, columns even so the middle gap sits on the fold. The same swipe up closes.
- **The open zoom scales the cards with the page.** At the page end the cards are scaled about the
  tapped card until it covers the page, so its neighbors slide past the screen edges as it grows,
  the way the app switcher reads as a zoomed-out view of the apps.
- **Close by swiping up, not sideways.** Sideways now scrolls. Close also stays in the card menu
  ("Close Tab — or swipe the card up") and as a VoiceOver action; the card has no X button, as in
  Arc and the app switcher.
- **The swipe up from the bar is the home-indicator swipe.** `TabGalleryTransition` gained
  `track(translation:)` and `release(velocity:)` (additive; `update(progress:)`/`finish(at:)`
  stay): the page follows the finger in 2D as a card and the transition decides where a release
  lands, by projection, with the shell's `gallerySwipeCommit`/`galleryFlickSpeed`. The shell's bar
  swipe hands it the raw translation and velocity, two calls in `TabSwipe`.
- **A dark, blurred backdrop.** The gallery is a layer over the page (the shell keeps the page
  under it), so a thin dark blur of the page, dimmed, stands behind the cards, as the app
  switcher and Arc do. One `UIVisualEffectView` that never moves; the cards scroll above it.
- **Never an empty switcher.** With no tabs, the tabs button and the swipe up open the search
  field. An empty tab shows the start screen (`EmptyTabView`: the Stem mark drawn in layers, which
  spins under a finger; one sentence; Search while the keyboard is down), and the search sheet is
  clear over it. A new tab's card is the mark on paper. The views live in TabGalleryUI, next to the
  card that shares the mark; the shell installs the start screen in three lines.


## First-run intro (2026-11-26)

- **Chosen:** a short intro on first launch only, replacing "no onboarding" (the owner's choice;
  docs/ui-reference.md, "First run"). Steps: the Stem mark assembling, the promise, what's inside,
  pick your icon, the blocking demo, the default-browser step (gated), then a dissolve into the
  search field. Skip on every step. Structure and rhythm follow Arc Search's intro; the look is
  Plain's own (below, "Intro styling"). The reasoning is in docs/research/intro.md.
- **Its own window above the browser's.** On first launch the scene shows only the intro; the
  browser is built when the intro finishes, so its search field takes focus and the keyboard rises
  while the intro fades off the top. After the intro was seen, launch runs one user-defaults read
  (`IntroGate.shouldShow`, key `PlainIntroSeen`) and nothing else of the intro: no views, layers
  or images are made. `-PlainIntroSeen YES` (the argument domain, Release too) marks it seen for
  the perf and smoke tests; isolated runs (`-PlainInMemoryStore`/`-PlainTestStore`, any build)
  skip it unless the Debug `-PlainShowIntro` or `-PlainRespectIntroSeen` is given.
- **Splash in Core Animation, steps in SwiftUI.** The mark is the icon's own geometry (ported from
  `Brand/tools/gen_icon.py`) as shape and gradient layers; the fold is a half turn of a
  `CATransformLayer` about the crease, with a double-sided coral back. Every splash and field
  animation runs on the render server at up to 120 Hz (`preferredFrameRateRange` 80–120). The
  steps are low-frequency static screens, so SwiftUI: its blur, opacity and offset transitions are
  Core Animation filters too.
- **The blocking demo reflows instead of wiping** between two pictures: the clutter leaves piece
  by piece and the article closes up, which shows what blocking does to a page.
- **Icon colorways:** Dawn (the app icon), Night, Coral and Paper, each an Icon Composer document
  from the same generator (`gen_icon.py --all`), compiled as alternate icons
  (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`; actool takes `.icon` documents and writes
  `CFBundleAlternateIcons`, checked in the built Info.plist). The picker's previews are ictool
  renders in FeatureUI's resources (`Brand/tools/icon_previews.sh`), decoded off the main thread.
  Settings gets one row, App Icon.
- **Default-browser prompts gated off** (`FixedChoices.defaultBrowserPromptsEnabled = false`):
  without Apple's default-browser entitlement Plain cannot be picked as the default, so the prompts
  would point at a choice that is not there. Both prompts are built and tested
  (`-PlainForceDefaultBrowserPrompts` in Debug). The button opens the Default Apps settings
  (`openDefaultApplicationsSettingsURLString`). The empty-tab card is `DefaultBrowserCard` in
  FeatureUI for the start screen to host: ShellUI installs the start screen (`EmptyTabView`) and
  already imports FeatureUI, so it can place `makeDefaultBrowserCard` there when
  `DefaultBrowserPrompts.showsEmptyTabCard()` says so. No module dependency changes.
- **Brand art colors** (`DesignSystem.BrandArt`): the mark's and the dawn's colors live in
  DesignSystem, used only by the mark and the intro. The demo page's fake ads keep their own loud
  colors on purpose.
- **Perf cost:** after the intro was seen, one defaults read on the launch path. FeatureUI's
  resource bundle adds four 180 px PNGs (150 KB), read only by the picker.

## M3 Duo layouts: panes, side tabs, folds (2026-11-26)

- **One layout model, from geometry only.** `DuoLayout` (ShellUI, plain values tested on macOS)
  decides from the root view's page area (safe area: status bar, the system's vertical bar), its
  size classes and `reservedRegions` (`.division` with `.includeInactive`, `.occlusion`): whether
  side tabs and a split can show, the sidebar's state and docked width, the pane frames and the
  chrome's lane. No device, `UIScreen` or orientation checks. It runs before every layout pass.
- **One pill, over the focused pane.** The plan's "each pane has its own top pill" became the
  existing bottom pill riding a lane over the focused pane (the brief: keep the existing chrome).
  The pill, search field, toast and button bar all act on the focused pane; a touch in the other
  pane focuses it and the pill slides over (`Motion.urlFocus`). The focused pane gets a 2 pt
  `Palette.accentOnGlass` ring and both panes a 6 pt gutter, only while a split shows.
- **Split on the crease, panes beside the fold.** Flat, the primary pane's width is set to the
  crease (when both panes keep 375 pt), so a later book pose barely moves them. Partly folded,
  `UIArrangementViewController` gets no fixed width and places one pane on each side of the fold
  itself: with a fixed width that crosses an active fold it hides both panes (seen on the
  simulator). A split needs two 375 pt panes (`FixedChoices.splitMinimumPaneWidth`), so inner
  portrait (669 pt) shows one pane.
- **Slot `i` shows pane `i`.** The two `PaneSlot` view controllers never trade panes; where only
  one pane can show (outer screen, inner portrait, no split) the focused pane's slot sits alone in
  a plain full-size container beside the arrangement: partly folded, the arrangement shrinks a
  lone view to one side of the fold (or hides it when its width is fixed), and a single page must
  keep spanning the screen. The web view stays in its slot's container through a fold; only the
  slot moves between the two hosts. The other pane's tab is detached (suspended, a live tier when it
  comes back) and re-attached on unfold. Swap and Close Pane re-parent web views without a reload.
- **The other pane keeps the expanded bar's bottom inset**, so a focus switch never relayouts
  either page; only the focused page's inset follows the collapsing bar.
- **Tab Layout is Above, Left or Right** (owner feedback, replacing Regular / Side Tabs): a tab
  strip across the top of the page area, or a sidebar on the left or the right. Left is the
  default (`FixedChoices.defaultTabLayout`: the inner screen has spare width beside a page and
  little height, and the system's vertical bar is on the right). Older stored values map on read:
  "sideTabs" to Left, "regular" to the default. The app switcher (swipe up from the bar, Show All
  Tabs) stays in every layout; the Tabs button opens it with Above and hides or shows the sidebar
  with Left and Right.
- **Tab Layout gates on the page, not the window.** It applies where both size classes are
  regular and the page is at least 640 pt wide; elsewhere (outer screen, iPhones) the app switcher
  is the only tab list and the Settings row is disabled with a footer saying why. A sidebar also
  needs 640 pt left beside its 64 pt rail: on the Duo that is inner landscape (867 pt beside the
  vertical bar); inner portrait leaves 605 pt, so Left and Right show the strip there and the
  setting is kept. The strip (48 pt, `FixedChoices.tabStripHeight`) pushes the panes down; a split
  stays on the crease under it. Expanded (260 pt) would leave 607 pt in inner landscape, so there it floats over the
  page (with a shadow) while the page keeps the rail's width; it docks where it leaves 640 pt.
  Rail is the widest state during a split or a book pose.
- **The sidebar resizes without relayout.** Rows are laid out at the expanded width and clipped
  by the sidebar; a drag moves only the sidebar's width (pages keep theirs), and the release
  springs to the nearest state (`SidebarDrag`, `Motion.sidebarSettle`, bounce only after a flick)
  and then docks once, inside the spring, so each web view gets one new frame.
- **Right mirrors Left.** The sidebar pins to the trailing edge of the safe area (inside the
  system's vertical bar), widens toward the page, floats Expanded from the right, and its rows
  keep the tile first. A drag's direction is flipped, the states and springs are the same.
- **The strip reads the same data source as the sidebar** (`SideTabsDataSource`): tap to show,
  long press for Open in Other Pane and Close Tab, drag to reorder within a list, a close button on
  the focused tab, + at the end (long press: New Private Tab), private tabs after the regular ones,
  tinted. Fixed 170 pt tabs that scroll sideways, the focused one scrolled into view.
- **Tiles until site icons are stored.** Rail rows show the site's first letter ("W" for
  en.wikipedia.org) on a tile; a favicon replaces it when Storage's icons reach the shell.
- **Fold safety.** `viewWillTransition(to:with:)` fires on fold and unfold (verified on the
  simulator: 951x669 to 466x678 and back). Inside its animation the layout is decided for the
  final bounds and laid out once (web views follow their pane by autoresizing, one frame each);
  page insets wait for the completion. Partly folding has no size change: it reaches the layout
  through the reserved regions (`updateViewConstraints`). Desktop or mobile stays the choice made
  at navigation start; a tab opened into a pane is attached before it loads, so the choice uses
  that pane's width.
- **Per-window state.** Each scene keeps its `TabStore` window id and its sidebar state in
  `UISceneSession.userInfo`; `EngineTabs` acts on that window only. No multi-window UI yet
  (`UIApplicationSupportsMultipleScenes` is off), so a scene without a saved id, or whose window
  is gone, takes the first saved window: that is the one scene's tabs. "Open in New Window" will
  need one app-wide `TabStore` and a new window for an unmatched scene (polish backlog).
- **Perf cost:** one more view controller (the arrangement) and two pane slots, made once. A
  split keeps two attached web views (both live; the pool already never discards attached tabs).
  Layout runs one `DuoLayout` value computation per layout pass and touches constraints only when
  it changes. The sidebar is built only when side tabs show.

## Intro styling: paper and a dawn window (2026-11-26)

- **Chosen:** the owner said the first intro copied Arc's look. The steps, words and rhythm stay;
  the look is Plain's. Paper is the ground (the launch color, so launch hands over with no change).
  The dawn from the mark (sky, coral sun, deep-blue planet, mint rim) shows through a window cut
  in the paper at the top. It is tall on the promise and default steps, with the mark on its sill,
  and a 56–76 pt band on the busy steps, and its sun climbs a little each step. Headlines are New
  York, the Reader's serif, with a coral stroke under the one word, cut at the fold's angle.
  Feature cards are paper sheets, small rings show the step, and the main button is Lagoon Liquid
  Glass.
- **Rejected: the horizon** (the dawn as a planet and sun at the foot of the paper, SF Pro
  Expanded). It felt closer to Arc's full-screen atmosphere, and the sun and dark planet fought the
  buttons. Codex compared both mockups against Brand/identity.md and Arc's frames and picked the
  window.
- **One signature motion:** after the splash the dawn opens out of the mark's own window into the
  page's window while the mark settles on its sill. Steps lift away like a sheet instead of
  blurring, so there is no blur pass at all now.
- **Core Animation for the dawn** (`DawnView`): the window and its sky, sun and planet are views
  whose frames move in one UIKit spring, and the sky's colors in a matching layer animation, so
  the render server runs them. The old field's drifting blooms are gone: nothing animates while a
  step is still.
- **Contrast:** the main button's fill is Lagoon a step deeper (`#2366F0`), so its white label
  holds 4.5:1 (Lagoon itself gives 4.2:1). The demo's tracker badge uses ink text on mint and coral.
- **The mark's shadow** on paper comes from a shadow path on its own layer
  (`StemMarkView(shadowed:)`), not a SwiftUI shadow, so it needs no offscreen pass.
- **One paper hook** (`IntroPaper`): the intro's ground view and its sheets' fill come from one
  place, so the shared paper texture (a parallel lane) is applied there and nowhere else in the
  intro. The intro builds no texture of its own.

## Sign-in: passkeys, passwords and the web-browser entitlement (2026-11-26)

Research and sources: `docs/research/sign-in.md`.

- **One entitlement does it.** On iOS, `com.apple.developer.web-browser` alone gives `WKWebView`
  passkeys for every site (Apple staff, forum 837755); the `.public-key-credential` key is macOS
  only. It also lets AutoFill's "Passwords" button show on web login fields: measured on the iOS
  27.2 simulator, a bare `WKWebView` in a plain app gets no button while a native field in the
  same app and Safari do. `Plain/Plain-WebBrowser.entitlements` holds the key, unused by the build
  until Apple grants it (signing with a managed entitlement the team lacks fails provisioning).
- **No password store of Plain's own** (`FixedChoices.passwordsFromSystemAutoFill`). Firefox,
  DuckDuckGo, Brave and Chrome keep one and register as an AutoFill provider so they can offer
  "save password", which `WKWebView` can't trigger for other apps. Plain leaves passwords to the
  system's Passwords app and the managers the user already chose: a second store is one more to
  keep in sync, to secure and to export. Saving new passwords stays the managers' job (their
  apps and extensions).
- **Until the grant, steer sites to passwords** (`FixedChoices.passkeysEnabled = false`). WebKit
  without the entitlement refuses every passkey request yet reports a platform authenticator in
  `getClientCapabilities()` (measured), so sites offer passkey buttons and prompts that only fail.
  A page-world script makes the passkey feature checks answer "no", so sites show their password
  sign-in, like in a browser without passkeys. It keeps `PublicKeyCredential` itself (removing it
  breaks scripts that reference the type) and wraps with `Proxy` so functions still read as
  native code to bot checks. A request made anyway is refused at once with
  `NotAllowedError`, the error WebKit gives, which WebKit answers only seconds later or at the
  request's timeout (measured); the site's fallback runs right away, and one toast per site per
  launch says why. Silent (conditional) requests go to WebKit untouched.
  The page world gets no message handler of Plain's: the script fires a DOM event that the
  engine's world relays. Cost: one small script per frame at document start, a few proxies, no
  work until a site asks for a passkey.
- **Not built: a native AutoFill bridge.** Plain could show its own key button on login fields,
  open a native username and password field that gets the system's Passwords button, and copy
  the picked account into the page. It would work today with every password manager, but it is
  a second sign-in UI that the entitlement makes redundant, it moves passwords through Plain's
  own code, and it needs a design pass. Revisit only if Apple refuses or delays the entitlement.
- **Links from other apps** open in a new tab (`BrowserViewController.open(externalURL:)`), in
  place of a sheet, the gallery or the previous page's open question (which gets its safe answer:
  cancel, deny). At
  launch they wait for the launch focus, so the search field never comes up over the page. While
  the first-run intro is up, the intro gives way unseen and shows again next launch: Apple
  requires the requested page, not an interstitial.

## Appearance and dark pages (2026-11-26)

Research and sources: docs/research/dark-mode.md.

- **Appearance is a setting** (System, Light, Dark; default System): the owner asked for it, and
  no single default fits someone who wants the browser darker or lighter than the phone. Every
  other browser that offers it (Firefox, DuckDuckGo, Brave) has the same three choices.
- **Windows, not views.** `AppAppearance` sets `overrideUserInterfaceStyle` on every window of
  every scene (System is `.unspecified`), so sheets, menus, alerts, the keyboard and the intro
  follow without code of their own. A change crossfades each window for 0.3 s; a window whose
  colors do not change is not animated.
- **A launch copy in user defaults.** The database (the one store of the setting) opens after the
  first frame, so the last applied choice is also kept under `PlainAppearance` and read as the
  scene connects. Without it a Dark user on a light phone would see a light first frame flip to
  dark. The database value replaces the copy as soon as it is read.
- **Web views get a trait override.** Pages follow their window's style live. A web view outside
  a window ignores `overrideUserInterfaceStyle` (measured), so the pool sets
  `traitOverrides.userInterfaceStyle` on each web view to the style the browser's window shows,
  and background tabs load in the right colors.
- **Dark pages is automatic, with a per-site switch** (`FixedChoices.darkPagesOn`). It runs only
  while the app is dark, never on a page that declares a dark `color-scheme`, asks for
  `only light`, has a readable `prefers-color-scheme: dark` rule, or already has a dark
  background. "Turn Off Dark Pages for This Site" is remembered per site (`darkPagesOff` table,
  in memory for private tabs) and applies without a reload.
- **Per-role darkening, not one root filter (changed 2026-11-27).** The first version put
  `invert(1) hue-rotate(180deg)` on `html`. On pages that mix dark and light sections (the owner
  on apple.com) it turned black heroes light and their white text near white on light, and
  flipped emoji and gradients. Now each color is changed by its role, as Chrome's and Safari's
  engines do: light backgrounds dark, dark text light, light borders grey, in OKLab with hue
  kept; dark backgrounds and light text stay exactly as made; pictures, video, canvases, frames,
  emoji and colored logos are never touched; text over a picture keeps the site's color; any
  text left under 4.5:1 is fixed. Style sheets get rewritten twins in the same cascade order;
  what they can't reach is fixed per element in idle time. Details and numbers:
  docs/research/dark-mode.md, section 9.
- **A focused engine of Plain's own, not Dark Reader.** Dark Reader (MIT, compatible with
  AGPL) is the proven rewrite, but it maps every color (dark backgrounds get darker, light text
  dimmer) where Safari leaves them, inserts `<style>` elements into the page's DOM (Plain keeps
  all styling in adopted sheets so hydrating frameworks never see it), needs its own fetch path
  for other origins, and is ~300 KB per page. Plain's engine (~1,300 lines in
  `DarkPagesEngine.swift`) takes its techniques (twin sheets, typed variable twins, mask
  backgrounds as foreground, inline-style handling), Chrome's role thresholds and Safari's
  stated rules. No code is copied, so nothing to bundle or credit in a license file.
- **Cost accepted for quality.** Script per page went from ~1 ms (filter) to 10–50 ms on real
  sites and 37–44 ms on the largest test pages, ~200 ms over a whole AP News load, measured in
  the simulator; the first paint waits for the sheet rewrite and one restyle (15–25 ms on the
  largest pages). The filter's GPU cost while scrolling is gone. The device perf gate is the
  check that this holds on the phone.
- **No flash.** A guard keeps the root dark (#181818) from document start while the page is judged; the
  judgement runs in the first rendering update after the head's sheets load. The guard and the
  darkening are constructed style sheets (`adoptedStyleSheets`), never DOM nodes, so hydrating
  frameworks never see them. A darkened page's overscroll area is set dark
  (`underPageBackgroundColor`).
- **The site list is baked into the script.** A page must know at document start whether it is
  off, and a user script cannot ask the app synchronously. The pool builds the script with the
  list and swaps it in every controller when the list changes (rare), keeping the other scripts.

## Paper texture (2026-11-26)

- **Chosen:** the Paper surfaces carry a faint, fine paper texture, so "plain" reads as plain
  paper. One seamless tile, generated in code (`DesignSystem/PaperTexture`), baked opaque onto the
  Paper color and drawn by Core Animation as a pattern in the layer's background color. Surfaces
  adopt it with one call: `Paper.apply(to:)` (UIKit), `PaperBackground()` (SwiftUI). The reader
  page tiles the same pixels as a CSS `background-image`.
- **Recipe:** a 256 px tile (about 85 pt at 3x), three layers on a torus so tiles meet without a
  seam, added to the base in 8-bit levels: *formation* (value noise on 16 and 8 px lattices,
  σ 0.45 levels), *tooth* (white noise softened by a [1 2 1] blur, σ 1.0) and *fibres* (121 short,
  tapered, nearly straight strands on a jittered grid so none cluster, peak 1–3 levels, 60 % darker,
  40 % lighter). Night paper on Deep Lagoon is about half as strong (σ 0.25 / 0.5), with mostly
  lighter strands. Day shadows move blue most (warm); night highlights move blue most (a cool
  sheen). A ±1 level triangular dither hides 8-bit steps. The sheet averages to `Palette.background`, so it still matches the launch screen.
  Tests hold it there: mean within 0.5 levels, 99.9 % of pixels within 9 (day) / 5 (night) levels,
  no seam step larger than any step inside the tile.
- **Why these numbers:** grain guides put "material, not dirt" at roughly 2.5–12 % noise opacity
  and warn that more reads as dirt ([shadcn grain](https://www.shadcn.io/background/grain),
  [Magic UI noise](https://magicui.design/docs/components/noise-texture)). iOS 7 Notes' visible
  paper is the failure to avoid ([iDownloadBlog](https://www.idownloadblog.com/?p=269870)). The
  same level step is a far larger relative contrast on navy, so night paper is weaker. Low
  frequencies show a tile's repeat first, so the formation stays small; the fibres carry the
  "paper" read.
- **Why a pattern color, not a layer or a shader:** an opaque pattern in `backgroundColor` adds no
  layer, no blending and no offscreen pass (those come from masks, shadows without a path and
  blur: [Apple, render-phase hitches](https://developer.apple.com/videos/play/tech-talks/10857)),
  and nothing runs per frame. A test checks the layer gets a `CGPattern` color with no contents,
  mask, shadow or rasterizing. The tile is made at the display scale, which
  `UIColor(patternImage:)` needs to stay sharp ([Stack Overflow 3217945](https://stackoverflow.com/questions/3217945)).
- **Memory:** width × height × 4, so 256 KB per tile, 512 KB with both appearances. The reader's
  PNG is made per request and not kept; WebKit holds one decoded 256 KB tile while the reader shows.
  Worst case under 800 KB.
- **Why generated, not bundled:** about 2 ms (optimized, on a Mac), off the main thread, once per
  appearance, instead of a ~70 KB PNG per sheet in the app and the reader, and one source for both.
  Until a tile is ready the surface is the flat color the tile averages to, so the swap can't be
  seen.
- **CSS:** a tiled PNG, not SVG `feTurbulence`, which re-runs the filter on repaint and pinned the
  CPU while scrolling ([Mozilla 422371](https://bugzilla.mozilla.org/show_bug.cgi?id=422371),
  [WebKit 287982](https://bugs.webkit.org/show_bug.cgi?id=287982)). The background scrolls with
  the page (no `fixed` attachment, which repaints every scroll).
- **Accessibility:** Increase Contrast (`accessibilityContrast == .high`, CSS
  `prefers-contrast: more`) and Reduce Transparency drop the texture to the flat color. WebKit has
  no `prefers-reduced-transparency` ([caniuse](https://caniuse.com/wf-prefers-reduced-transparency)),
  so the reader follows Increase Contrast only (polish backlog).
- **Not on:** web content, glass controls, the private-tab surfaces (their dusk violet stays flat)
  or anything that moves on its own. The texture never animates. The sheets got it later ("Sheets
  on paper", below).
- **Perf cost (simulator, machine load 350–850, so noisy):** perf gate before → after: launch
  4056 → 3648 ms, main → field 619 → 596 ms, gallery 1491 → 1484 ms. Gallery scroll of 100 tabs
  with 25 new-tab cards, main-thread work p95: 1.7–3.7 ms flat, 1.9–2.6 ms on paper. Start-screen
  footprint within noise (19.3–21.2 MB both).

## Browse for Me result source

- **Search results page in a hidden tab, no API key.** DuckDuckGo's lite page is the default because it is stable and light; the user's chosen engine is used when its page parses. Free, works for every tester, and needs no server. Trade-off: a page redesign can break parsing, so the parser is tested against saved pages. Brave Search API stays a later opt-in. (Owner's choice, 2026-11-26.)

## Sheets on paper (2026-11-26)

- **Chosen:** the owner asked for Settings, History, Favorites, Archive and Downloads "on paper,
  simple, in our own identity". Every FeatureUI sheet (Settings with Search Engine, App Icon and
  About; History; Favorites; Archived Tabs; Downloads) now sits on the textured Paper ground
  (`PaperBackground()`, day cream / night lagoon). Rows stay grouped, on flat paper cards a hair
  lighter than the ground (`Palette.paperCard`: `#FFFBF4` by day, `#11293D` by night) with ink
  hairlines (`Palette.paperHairline`). Text is ink (`Palette.ink`), supporting text the ink's
  secondary step (`Palette.inkSecondary`: ink at 72 % by day, paper at 76 % by night, well over
  4.5:1), actions and checkmarks Lagoon a step deeper on paper (`Palette.accentOnPaper`: `#2366F0` by day, 4.7:1 on
  the card; `#8DB6FF` by night), destructive the system red. Titles are New York like the intro's
  headlines; body text stays SF. About shows the name in the intro's display line with its coral
  fold.
- **Rejected: plain rows on the ground.** Without cards, History's days and Settings' footers would
  run together, and swipe actions would have no edge to slide from. Grouped cards read as
  sheets of paper on paper, the intro's look, and are one rule for every sheet.
- **Native, restyled:** the screens stay `List`s with their own swipe actions, search, edit mode,
  reorder, menus, Dynamic Type and VoiceOver. Only `.scrollContentBackground(.hidden)`, the ground
  behind, `.listRowBackground`, `.listRowSeparatorTint` and the title change (`paperSheet()`,
  `paperRows()`, `sheetTitle(_:)` in `FeatureUI/Style.swift`). The serif title is a `.principal`
  toolbar item, capped at accessibility1 like the system title; `navigationTitle` stays for the
  back button and VoiceOver. The system's large grouped-list radius stays (an exception to the
  6–10 pt rule, as for the system menus): matching it would mean drawing every card by hand.
- **Ink caveat:** the sheet's ink foreground replaces the system's footer gray and a button's
  tint, so footers, values (`ValueLabel`), Clear History and Use Custom Engine name their color.
- **Search field:** History's and Archive's search sits at the top, under the title, and
  scrolls away with the rows (`.searchable(placement: .navigationBarDrawer(displayMode:
  .automatic))`; pull down to bring it back), as in Safari's history. The system's floating bottom
  field showed a ghost of the row behind its glass on paper, even with a hard bottom scroll edge
  (follow-ups, 2026-11-27; lead's call). `.always` was tried: on iOS 27 the sheet's bar hides as the
  list scrolls and the kept field floats over the rows as glass, with the same ghost. The list's
  top scroll edge is hard, so rows under the bar fade out.
- **Duo outer screen:** the bar's leading button moves to the side column there, which left the
  system title off center ("Downloads"); the serif title is a `.principal` item, which the bar
  centers.
- **Accessibility:** Increase Contrast drops the texture (as everywhere), lifts the cards to white
  / `#1A3850`, and strengthens hairlines (38–42 %) and supporting text (88–90 %). Reduce
  Transparency drops the texture. The cards are opaque either way.
- **Performance:** the texture is the ground's pattern color only; a row is one opaque color, no
  layer, texture, shadow or mask. 1,000-row History scroll on the iPhone 17 simulator (Release,
  main-thread CPU per frame while the list tracks or decelerates, 3 runs of 36 fast swipes, the
  simulator draws at 60 Hz): before 1.57 / 1.80 / 1.96 ms, after 1.66 / 1.78 / 1.72 ms; worst
  frame 12.8–22.2 ms before, 12.8–14.5 ms after. The paper adds nothing measurable; the
  simulator can't show 120 Hz headroom, so the device perf gate and Instruments on the Duo are the
  check for that.
- **Read failures** (state rules §6, Sheets): History, Archived Tabs and Favorites show one
  sentence and Try Again in place of the list when a read fails, never the empty state and never
  stale rows. History's Clear dims only when history itself is empty: a search that finds nothing
  reads one visit to know.

## Translate Page: Apple Translation, text nodes in place (2026-11-27)

Research and sources: docs/research/translate.md.

- **Engine: Apple's Translation framework, on the device** (`FixedChoices.translationOnDevice`).
  No server sees the page, it works offline once a language is downloaded, and it costs nothing.
  Sessions are made without a view (`TranslationSession(installedSource:target:preferredStrategy:
  .lowLatency)`, iOS 26), one per language pair, reused per batch. Only a language that is not
  downloaded needs the system's download sheet, which the framework shows only from SwiftUI's
  `translationTask`: a 1-point invisible hosting controller is added to the browser for that one
  question and removed after it (`ShellUI/PageTranslators.swift`). The framework does not run in
  the simulator, so UI tests use a phrase-book stand-in (`-PlainTestTranslator`, Debug only).
- **Layering:** WebEngine owns the page side (`PageTranslation`: the language check, the
  translator script, `Tab.translation`) behind a `PageTranslator` seam; the shell owns the
  framework. The engine never imports Translation or SwiftUI.
- **Language:** a document-end script in its own content world sends `<html lang>` and up to 2,000
  characters of text; `NLLanguageRecognizer` decides off the main thread (confidence ≥ 0.6),
  falling back to `lang`. `PageLanguage.isRead` compares with `Locale.preferredLanguages` by
  language, and by script for Chinese. The item shows only when the device can translate the pair
  (`LanguageAvailability`), answered once per language per launch.
- **In place, text nodes only.** The translator writes each translation to the same text node's
  `nodeValue`: never new nodes, never HTML. Layout, links, event handlers and frameworks that hold
  those nodes (React, Vue) keep working (Google Translate's node replacement is what breaks React
  pages). Skipped: code, pre, form fields, `translate="no"`, `.notranslate`, contenteditable.
  Show Original writes every original back where the page has not changed it since; a test checks
  `innerHTML` is byte-identical afterwards.
- **Visible first, lazily.** An `IntersectionObserver` (1.5 screens ahead) feeds batches of at most
  1,500 characters or 40 pieces, two in flight; far text is translated only as it scrolls near. A
  throttled `MutationObserver` (250 ms) translates what the page adds or changes, and tells its
  own writes apart. Measured (iPhone 17 simulator, fake translator): a 3,000-paragraph page sends
  1,943 characters in 3 requests before anything is scrolled, first text in about 60 ms, and the
  translator's start (collect and watch) takes 6 ms in the page.
- **Trade-off: per-node context.** A sentence split by a link is translated in pieces. Apple's
  `translate(_: AttributedString)` (iOS 26.4) could carry the runs; that is in the polish backlog.
- **UI:** one page-menu item, "Translate Page" subtitled with the pair ("French to English"),
  which becomes "Show Original". The tab keeps translating its next pages in the same language
  until Show Original (`FixedChoices.translationFollowsTab`), as Chrome and Safari do. No banner:
  the one hint is a toast the first time ever a foreign page shows ("This page is in French",
  Translate), `FixedChoices.translateHintShownOnce`. A failed translation puts the page back and
  says so in a toast. Main frame only (frames: polish backlog).

## Print and Save as PDF: the print formatter, paginated (2026-11-27)

Research and sources: docs/research/print-pdf.md.

- **Print** is the system print sheet with the web view's `viewPrintFormatter()`: paper, copies,
  range and printers are the system's, and the page's `@media print` styles apply. Chrome and
  Firefox on iOS do the same.
- **Save as PDF is paginated**, from the same formatter through `UIPrintPageRenderer`, on Letter
  in the regions that use it and A4 elsewhere (`FixedChoices.letterPaperRegions`), with half-inch
  margins. Not `createPDF`: it draws the screen styles as one tall page (cut at 200 inches), which
  reads badly in every PDF viewer. The file (named for the page title) goes to the share sheet
  from a temporary folder that is removed when the sheet closes.
- **Lazy pictures** are told to load first (`loading=eager`, waiting at most 800 ms): WebKit prints
  a lazy picture that never scrolled into view as a blank box.
- **The reader prints the article**, not the page under it. Not on Start, while loading, or on an
  error or crashed page (state rules §4). A PDF tab prints, and keeps "Save PDF to Files" for the
  original file instead of Save as PDF.
- **In the share sheet** (since the follow-ups of 2026-11-27): Print and Save as PDF are Plain's
  own share sheet actions (`PageActivity`), where Safari and Chrome keep them, so the page menu
  fits the Duo's outer screen. They were first in Find on Page's row of the page menu ("Find",
  "Print…", "Save PDF"); with Show Reader and Translate Page on a foreign article the menu ran past
  the outer screen. A row of icons without captions was rejected in design review (Find and Save
  PDF were not told apart).
- **The same document:** an export marks the document with a token in the engine's world and checks
  it, the tab and the web view before the sheet shows, so a reload or a tab switch meanwhile drops
  the export instead of showing the wrong page.
- **Perf cost:** the formatter lays the document out in the page's process and the first drawn page
  waits for it on the main thread. Pages are drawn one per run-loop turn after that, and a document
  over 20 pages shows "Saving as PDF…" first (`FixedChoices.exportProgressPages`). Measured
  (iPhone 17 simulator): a 3,000-paragraph page (121 A4 pages) holds the main thread for 14 ms
  (layout) plus 423 ms (first page), 558 ms in all; a two-page article is imperceptible. Only ever
  from a menu tap. A long-document spinner is in the polish backlog.

## Cookie banners: DuckDuckGo autoconsent, reject first (2026-11-27)

Research and sources: docs/research/cookie-banners.md.

- **Chosen:** DuckDuckGo's autoconsent 18.12.0 (MPL-2.0), unmodified, bundled by
  `tools/autoconsent` (npm + esbuild, pinned) into `ContentBlocking/Resources/CookieBanners`: a
  129 KB script (engine and Plain's 40-line bridge) and 736 KB of rules. It finds the consent
  manager (OneTrust, Cookiebot, Didomi, Sourcepoint, TrustArc, Usercentrics and about 1,600
  rules for the long tail), clicks through to "reject all" including second-layer settings
  screens, and checks the result. Default on (`FixedChoices.cookieBannersHandled`); "Turn Off
  Cookie Banner Blocking" in Site Settings, remembered per site (`cookieBannersOff` table, the
  private session in memory).
- **License:** MPL-2.0 §1.12 lists the GNU AGPL 3.0 as a Secondary License and §3.3 allows the
  combination ("Larger Work"); no autoconsent file carries the "Incompatible With Secondary
  Licenses" notice. Obligations: the files stay MPL-2.0, unmodified, with the license
  (`MPL-2.0.txt`) and where the source of the exact version is (`NOTICE.txt`).
- **Not chosen:** a hand-written reject script for a dozen consent managers (first-layer buttons
  only; breaks on settings flows, US variants, iframes and shadow DOM; Firefox's list died of
  this maintenance), "I don't care about cookies" (GPL-3.0, but it accepts on some sites, the
  opposite of reject-first), Consent-O-Matic (MIT; autoconsent dropped its rules in v16), Firefox
  cookie banner reduction (removed in Firefox 155, rules archived), and hiding alone (Brave's
  approach, which Plain already has from the EasyList Cookie List: a hidden banner never says no,
  and scroll locks stay).
- **Wiring (DuckDuckGo iOS's pattern, an idea, no code taken):** one reply handler in Plain's own
  content world. Main frames get the engine only when the page shows a sign of a consent manager
  (see "Cookie banners: the engine only where a banner is", below); its `init` is answered with the
  generic rules plus only the site rules whose address pattern matches (matched off the main
  thread, 0.4 ms per page on a Mac). Subframes get a one-line script that reports the frame's
  address; only a frame a rule targets (Sourcepoint's dialog, about 20 hosts) gets the engine, so
  ad and video frames cost nothing. Eval steps (a consent manager's own API, for example
  `OneTrust.RejectAll()`) run in the asking frame's page world, wrapped to return only a Boolean.
  Heuristic detection is off: a wrong click is worse than a visible banner. A site whose banner
  comes back after every answer (3 in 60 s) is left alone for the launch.
- **With the cookie list:** the EasyList Cookie List stays in the blocking lists and hides banners
  autoconsent has no rule for. A banner it hides is invisible to autoconsent and stays unanswered
  (for consent that means "no"). Turning cookie banner blocking off for a site stops the
  answering; the hiding follows "Turn Off Blocking on This Site". Moving the cookie list into its
  own switchable list needs a regeneration of the blocking lists (polish backlog).
- **Perf cost (before the probe below):** a long article without a banner loads in 65–104 ms
  with the engine against 38–48 ms without, on the iPhone 17 simulator (parsing the 129 KB script
  at document start); a
  OneTrust banner is rejected about 0.8 s after the page starts (0.5 s of it is the engine's own
  wait for the banner's script). The rules are read off the main thread once after launch.

## Duo inner screen: Safari's top bar (2026-11-27)

Owner, after using the Duo: the tab bar took too much space and looked broken, the page should get
the screen, and the portrait bottom menu (the pill over a full-width button bar) looked horrible.
Safari on iPhone Duo is the model (`docs/research/safari-duo.md`).

- **Chosen: a top bar wherever Tab Layout applies** (both size classes regular, page ≥ 640 pt: the
  inner screen in both orientations, iPad-size windows). One row under the status bar: Back and
  Forward in a capsule at the leading end, the address pill in the middle (at most 560 pt), Tabs,
  Share and More in a capsule at the trailing end. Safari puts its bar at the top of the inner
  screen in both orientations with a full-width viewport (WebKit's Safari 27.1 table: 951 and 669
  CSS px), and thumbs holding the open Duo sit at its sides, near the row's ends. The outer screen
  and phones keep the bottom pill.
- **The system's vertical bar is off there** (`preferredVerticalBarBehavior = .disabled`, tied to
  the size classes only, as the header asks). It cost 84 pt of width beside every page and held the
  buttons on the far right only. Supersedes M3's "keep the vertical bar in inner landscape".
- **Floating, like the bottom pill.** The bar and strip float over the page (no band, the owner's
  rule for the pill) and move by transform and alpha only. The page's `contentInset.top` is the
  expanded bar's height (fixed while the bar collapses, so the page never jumps) and its obscured
  inset follows the resting state, as on the bottom. `obscuredContentInsets` alone does not move
  the scroll range (measured), so without the content inset the first lines sat under the bar.
- **While reading** the pill shrinks to 70% under the status bar showing the address; the buttons
  rise and fade, the strip slides up and fades. Tap the address to bring it back, as before.
- **Tab Layout Above is the default** (was Left). Safari shows tabs under the address bar on the
  inner screen; it looks the same in landscape and portrait (a sidebar never fit beside a portrait
  page, so Left showed a strip there anyway); it costs height only while two or more tabs are open
  and hides while reading. A stored Left or Right is kept.
- **The strip:** 34 pt, one glass surface, tabs share its width (140 to 280 pt each, then it
  scrolls), the focused tab a lifted paper card with its close button. It shows from the second tab
  (one tab has nothing to switch to) and comes in with the focused tab in view.
- **The rail is 52 pt** (was 64), close to Safari's vertical-tab strip, with 32 pt tiles.
- **Split:** one bar spans both panes and acts on the focused one (its ring shows which); a 475 pt
  pane is too narrow for a bar of its own. Partly folded, the bar keeps to the focused pane's side
  of the fold.
- **Editing:** the pill still rises above the keyboard with the search sheet, as on every screen,
  so suggestions stay nearest the thumb and the search sheet stays one design. Safari on iPad edits
  in place at the top; revisit if the owner prefers that.
- **No swipe up from a top bar** (it would pull away from the page); Tabs, the strip and the
  sidebar are at hand. A sideways swipe on the pill still switches tabs.
- **Back and Forward show only what applies.** Their capsule holds the buttons that show (Forward
  hides until there is somewhere forward, as on a phone) and grows away from Back, so Back never
  moves; on Start, with neither, it leaves no empty glass. Tabs, Share and More keep their slots.
  The design review called two dead arrows wasted width (round 1).
- **Narrow tabs drop the site's name** from the end of a title ("Web browser - Wikipedia" reads
  "Web browser" in the strip and the sidebar; `TabGalleryItem.compactTitle`): the tile already
  shows the site, and the words that tell tabs apart come first. The strip's edges fade where tabs
  continue. In a split the focus ring starts under the bar, which belongs to both panes.
- **Page area** (inner landscape 951x669, status bar 24 pt; % of the screen the page shows):

  | State | Before (M3) | After at rest | After while reading | Safari 27.1 |
  |---|---|---|---|---|
  | Landscape, one tab | 75.9% (84 pt bar column, 64 pt rail, bottom pill) | 88.9% | 91.2% | 87.4% / 92.7% |
  | Landscape, Above, 3 tabs | 75.4% (strip 48 pt, bar column, bottom pill) | 83.3% | 91.2% | |
  | Landscape, Left rail, 3 tabs | 75.9% | 84.1% | 86.2% | |
  | Portrait, Above, 3 tabs | 79.6% (strip 48 pt, pill over a 48 pt bar) | 88.2% | 93.8% | 91.2% / 94.8% (one tab) |
  | Portrait, one tab | 79.6% (the strip showed with one tab) | 92.2% | 93.8% | 91.2% / 94.8% |

- **Perf:** no new work per frame: the collapse sets three transforms and two alphas instead of two
  and one. The layout model adds one Boolean and a tab count kept on tab changes, not read per
  layout pass. The strip's item width is computed on layout and tab-count changes only.
- **Not verified on the device yet:** the Mac was locked, so Device Hub's fold could not be driven.
  Captures come from the simulator's resizable window at 951x669 and 669x951 (`docs/development.md`),
  which has no fold and no vertical bar of its own. Checks for the device are in the polish backlog.

## Scroll chrome: expanded, pill, hidden (2026-11-27)

- **Chosen:** three resting states. Scrolling down takes the bar to the pill 1:1 as before; reading
  on (120 pt past the pill, or a flick projected that far) sinks the pill past the bottom edge as its text fades
  (`Motion.toolbarHide`, `.smooth(0.35)`); a clear move up (24 pt, or 8 pt at 0.3 pt/ms), a tap
  on the bottom edge, a status bar tap, the page's end, the top or a new page brings the whole bar
  back (`.smooth(0.25)`). Research and sources: docs/research/scroll-chrome.md; rules:
  docs/state-rules.md, "Chrome while reading".
- **Why nothing remains:** a thin host label without glass is illegible over an arbitrary page, and
  with glass it is the pill again. The pill shows the host on the way down; the home-indicator
  strip is the way back by touch (taps reach the app there; swipes stay the system's).
- **Inset:** `PageInsetState` holds a `ChromeRest`; hidden obscures only the home-indicator strip
  (34 pt on iPhone 17, 16 pt minimum), so fixed footers rest just above the indicator. Still one
  change per rest, never per frame. The viewport range is now hidden to expanded.
- **Scroll range follows too:** measured on the iPhone 17 simulator, `obscuredContentInsets` moves
  fixed footers and the viewport but leaves the scroll view's `adjustedContentInset.bottom` at the
  safe area (34 pt), so a page's last lines stayed under the expanded bar at its end (true before
  this change too, behind the pill). The shell now sets `scrollView.contentInset.bottom` to the
  rest's inset less the safe area, in the same once-per-rest step (`followObscuredBottom`): a range
  change, not a relayout. When the bar comes back while the page rests at its very end, the page
  rises with it (`setContentOffset(animated:)`), never under the finger.
- **One driver, two springs:** `SpringDriver.animate(to:velocity:spring:)` takes a per-motion spring,
  so a reveal can retarget a hide mid-flight with its velocity. A drag grabs only motions between
  expanded and the pill; a hide or reveal finishes, and the drag can still turn it around.
- **Never hidden** while loading, on error pages, editing, finding, under VoiceOver or Switch
  Control (`ControlRules.chromeMayHide`), or on a page shorter than two screens.
- **Inner screen top bar:** the lead's top bar lane reads the same collapse progress. Past the
  pill (1 to 2) the tucked address rises off the top edge (`TopChromeGeometry.pillTransform`) and
  the top inset goes to `hiddenInset` (0); the viewport range is hidden to expanded there too. The
  top bar is clear of the home-indicator zone, so it hides fully like the bottom pill.
- **Performance** (iPhone 17 simulator, Release, 25 scripted swipes on the long test page; the
  simulator has no hitch data, so two proxies). The shell's work per scroll callback
  (`toolbar.scrollStep` signpost, ~3,500 callbacks): before mean 6.7–8.0 µs, p95 5.8–9.1 µs, max
  0.4–4.7 ms; after mean 7.1–7.9 µs, p95 11.4–11.9 µs, max 0.5–0.7 ms. Main-thread CPU per scroll
  frame (Time Profiler, 1/60 s buckets that hold a scroll callback; XCUITest's own queries are in
  it): before mean 5.5 ms, 554 frames over 16.7 ms; after mean 4.2 ms, 368 over 16.7 ms. No layout
  during motion: the edge strip toggles `isUserInteractionEnabled`, the pill moves by transform and
  alpha, and insets change once per rest. The device perf gate (`testPageScrollHitches`) is the
  check for 120 Hz.

## The page inset moves at the start of a reveal (2026-11-27)

- **Owner feedback:** coming back from the pill or hidden, the bar arrived first and then a fixed
  page footer jumped up into place, because the page's bottom inset switched when the snap ended.
- **Chosen:** a reveal (any snap toward more chrome than the inset shows) switches
  `obscuredContentInsets` and the scroll view's bottom inset as it starts
  (`PageInsetState.barHeading(to:)`); a hide still switches when the bar rests, so a footer is
  never under a bar still on screen. The top bar on the Duo's inner screen reads the same state.
  The bounce rule stays: while the page is pulled past an edge the change waits. A page resting
  at its end rises with the bar instead of after it.
- **Measured** (Duo outer screen simulator, `/footer` test page, 60 Hz): the inset change costs
  0.1–0.2 ms on the main thread; the 26 reveal frames show no interval over 17.5 ms, the same as
  before the change (16.7–17.7 ms). In the recorded frame strip WebKit moves the footer in the
  same frame the bar starts to rise (before: about 0.5 s later, after the pill had covered it),
  so no first-frame deferral was needed. The footer moves in one step (WebKit has no animated
  inset change); the bar then slides in under it.

## Page menu fits the Duo's outer screen (2026-11-27)

- **Problem:** on a readerable page in another language the page menu ran past the Duo's outer
  screen (466x678): the History, Favorites and Settings row was cut off. The menu opens from the
  vertical bar's More with about 473 pt of height.
- **Chosen:** Print and Save as PDF moved to the share sheet (decision above). That alone was not
  enough (measured: the last row still cut on the simulator), so the rows that apply together
  became captioned rows of up to three, like Reload, Share and Copy Link: Find on Page, Show
  Reader and Translate Page ("Find", "Reader", "Translate" / "Original") and the tabs items (New
  Private Tab, Reopen Closed Tab, Archived Tabs: "Private Tab", "Reopen Tab", "Archive"), each only
  when two or more apply. VoiceOver reads the full names and Translate Page's language pair. A
  single item keeps its full name and subtitle.
- **Trade-off:** in the row, Translate Page loses its visible "French to English" subtitle; the
  first-time toast names the language, and VoiceOver reads the pair.
- **Verified:** `PageFeatureTests.testPageMenuFitsTheScreen` opens the menu on a French article with
  a closed tab to reopen and checks that the first and last rows lie inside the menu without
  scrolling, on the Duo outer screen and the iPhone 17.
- **Not covered:** with a download this session as well, Downloads adds a row and the last row
  needs a short scroll on the outer screen (polish backlog).

## Cookie banners: the engine only where a banner is (2026-11-27)

- **Problem:** every main frame parsed the 129 KB autoconsent engine at document start, and its
  detection ran on every page: +20 ms per load on a long article loaded back to back, and the
  page's own first script 3–4 ms later in a fresh web view, on pages that never had a banner.
- **Chosen:** a probe of about 3 KB goes into main frames at document start instead. It posts the
  page's address once; a site turned off stops it, and a site with a rule of its own (about 900
  address patterns, matched off the main thread) gets the engine at once, so its banner is still
  hidden before it shows. Otherwise it watches for a consent manager: a resource from one of 33
  consent manager hosts (OneTrust, Cookiebot, Didomi, Usercentrics, TrustArc, Quantcast,
  Sourcepoint, consentmanager, Funding Choices and others; a `PerformanceObserver` on resource
  entries, buffered, so scripts and frames loaded before it count), or one of 40 banner
  containers (ids and classes only) at DOMContentLoaded, at load, and 1.7 s and 5 s after load
  (`FixedChoices.cookieBannerWatchMilliseconds`). The first sign puts the engine into that frame
  (`evaluateJavaScript` in Plain's world) and the probe stops. Subframes are unchanged.
- **Fallback:** the EasyList Cookie List stays on and hides the long tail the probe doesn't know
  (autoconsent's 700 generic rules are mostly one site's own banner). A banner from a known
  consent manager loses the engine's prehide (it may show for a moment before it is rejected);
  site rules keep it.
- **Measured** (`CookieBannerPageTests.costPerPage`, iPhone Duo simulator, 3 runs each): long
  article back to back (median of 5 loads), without cookie banner handling 29.0–29.7 ms, with the
  engine 48.9–50.4 ms; with the probe 30.7–31.5 ms against 29.8–30.3 ms without. In a fresh web
  view the page's first script ran at 4–5 ms with the engine, 1 ms without, and 1 ms with the
  probe. A OneTrust banner is still rejected: 1.24–1.31 s after the load started before, 1.26–1.32
  s after (the page found at DOMContentLoaded; the engine's own wait for the banner dominates). A
  banner a script adds after load, and a site rule's page, are covered by tests.

## Launch: the last tab first (2026-11-27)

Owner: "When I open Plain and I have tabs open, open to the last one, not a new-tab thing — or
maybe do that, but with the last tab in the back … It seems weird how it works right now, like
empty." Research in docs/research/launch.md; rules in docs/state-rules.md, "Launch and return".

- **The rule:** with a last tab, open to it, exactly as it was, bar resting, no keyboard (Safari;
  Chrome and Firefox under 4 hours). After 4 hours away (`FixedChoices.freshSearchAfter`, Chrome's
  and Firefox's tested line), a fresh search over it, keyboard up, the tab behind a paper veil,
  swipe down or tap outside to get back (Arc Search's sheet over the tab). No tabs: search first,
  as before. The same rule on a return from the background (the app still running). No setting:
  one time line covers "where was I" and "new errand".
- **Never empty:** the first frame paints the last tab's picture at full size, not paper. The
  database and the web view come back only after that frame, so the screen cannot wait for them:
  when the app resigns active, the shell takes a 2x full-width snapshot of the page
  (`WebViewPool.snapshot(of:width:)`, the bar swipe's preview size; the card thumbnail is the
  fallback) and writes it off the main thread beside the thumbnails
  (`Thumbnails/Launch/<window>-<save>.jpg`, a new name per save), then publishes a small
  `LaunchHint` naming it (tab id, address, Back/Forward, tab count, security, time) in user
  defaults, per window and per store, only once the write succeeded: a hint never names another
  page's picture. Every save and clear bumps a generation, so a snapshot that comes back late
  never undoes a newer save or a clear; the write runs inside `BackgroundWork` (ends exactly once,
  also when the system's time runs out). A window that left with no page stores an empty marker,
  so it opens to search rather than to another window's page; a scene the system made new (the
  app swiped away in the switcher) has no window id: as the app's only scene it takes the hint any
  window left last and restores that same window, so picture and page agree; a further new scene
  starts with search. Launch still checks the hint against the tab the session selects.
  A test store has its own keys, cleared by `-PlainResetStore`; the in-memory store keeps none.
  No picture at all (the page did not answer and no card thumbnail exists): no hint, search first.
- **Off the main thread:** the scene reads the hint (user defaults are already in memory) and
  starts decoding the picture on a background task before it builds the browser
  (`LaunchPicture`, `preparingForDisplay()` at the picture's own size). The first frame takes it
  if ready, else waits at most `FixedChoices.launchPictureWait` (40 ms) for the decode already
  running, else fades it in when it lands. The wait is a deliberate bounded exception to "main is
  for UI only": three frames of waiting under the launch screen beat a frame of bare paper; the
  decode finished before the first frame in every simulator run (`launch.pictureWait` never fired;
  see docs/perf-log.md).
- **No flash:** the picture sits over the page container, takes no touches, and stays above the
  restored web view until its page has loaded and had 100 ms to paint and restore its scroll, at
  most 3 s from the moment the picture went up (`launchPictureMaxHold`, enforced by its own timer
  even while the saved session is still being read), then crossfades out
  (`Motion.quick`). A drag on the page, a switch to another tab, a new address, Back, Forward or
  Reload uncovers it at once. Until the saved session is read, the bar follows the hint
  (`placeholderState`), so its buttons and address are already the restored page's and nothing
  moves. An HTTPS page that has not committed yet has no security verdict (`.none`) rather than
  "Not Secure": the restored page's address arrives before its load, which flashed "Not Secure —"
  in the resting bar for a few frames.
- **Fresh search opens a new tab:** a search from the fresh search over a page goes to a new tab
  (Chrome's New Tab Page), private if the page was, so the page the user came back to stays as it
  was in the tab list. A
  search from the pill on a page still loads in that tab.
- **The frost is a paper veil:** 70% paper over the page, no blur (`FrostView`). The system
  materials blurred the page past recognition (design review); the veil keeps its headings and
  layout readable as "the tab is still there" while the empty field and keyboard lead.
- **Swipe down closes the search field** everywhere, not only over a last tab: the sheet behaves
  like a sheet (Arc Search), and a tap outside still works.
- **Not kept:** private pages (never on disk), a split (two panes restore differently from one
  picture) and the reader (it does not restore). Those launch into search with the restored tab,
  if any, behind the frost.
- **Debug clock:** `-PlainAwayOffset <seconds>` runs the rules' clock ahead (Debug builds), so UI
  tests reach "4 hours away" without waiting.

## Duo inner screen: the bar in the status row (2026-11-27)

Owner, on the device (inner screen, landscape): "There's a huge bar on the top when I open the
Duo." And: "I want the URL bar at the level next to those things [the clock and battery]. I don't
want the wasted space on top." The device screenshot (951x669 pt): the top safe area is 81 pt, but
the status items sit only in the top-trailing corner (x 828–928, y 24–69). The bar sat under that
81 pt band on an opaque paper band, and the page started at 132 pt (20% of the screen). The
simulator's 24 pt status bar had hidden this.

- **Chosen: the row sits in the status zone, on the status items' row.** Back/Forward, the
  address and Tabs/Share/More are centered on the corner's vertical middle, and the row's trailing
  end stops 12 pt before the corner. Nothing above the row is Plain's: the page runs to the top
  edge under the zone and the floating glass (no band, the owner's rule for the bottom pill).
- **How the corner is found (no device geometry), in order:**
  1. `UIView.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))`, the iOS 26 guide for
     "bar-like content at the top of a scene" beside a corner element (iPadOS's window controls).
     Where system UI keeps to a corner, that guide's top is shorter than the safe area's and its
     leading or trailing inset is larger; the corner is the rect from that inset to the edge, from
     the guide's top down to the safe area's top (`StatusCorner.rect(width:safeTop:...)`).
  2. Else the camera the status items wrap: an occlusion region
     (`reservedRegions(kind: .occlusion, options: .includeInactive)`) inside the top safe area and
     in the outer quarter of the width. The simulator reports the Duo's inner camera as a 37 pt
     circle at x 884.7–921.7, y 29.3–66.3 (landscape; 602.7 in the 669 pt portrait window), the
     center of the device's battery ring (903.5, 47.6 in the owner's screenshot), and the device's
     81 pt safe area clears it. The corner is centered on the camera's row (at least a row high)
     and reaches `FixedChoices.statusItemsReach` (64 pt) past it toward the middle, for the clock.
     In the simulator's portrait window (safe top 82) the horizontal guide equals the safe area,
     so this second source is what places the row there; the device may report either.
  3. Neither: a full-width status bar (phones, the simulator's landscape window with its 20 pt
     safe area): no corner.
- **Layout math (`TopChromeGeometry`, root view coordinates, panes start at the top edge):**
  - In the zone: row center = corner.midY; rowTop = max(center − 22, corner.minY); the row ends
    12 pt before the corner. Strip top = row bottom + 4. At rest the page's top inset = the row's
    bottom + 4 (+ strip 34 + 4), and never above the corner's bottom: the scroll range's start.
    The obscured inset WebKit sees is 0 in every state (see "No band at the top" below; was this
    value at rest and the row's or the corner's bottom, 69 pt, while reading).
  - Device numbers, status items as measured (828–928 x 24–69, safe top 81): row 24.5–68.5, page
    top at rest 72.5 pt (was 132), 110.5 pt with the strip (was 170), 0 while reading (was 81,
    then 69). Safari: 84 pt at rest.
  - From the camera (source 2): row 25.8–69.8 around the camera's 47.8, the row's end at 808.7
    (the clock starts at 828), page at 73.8 pt.
  - From a guide corner spanning the zone (0–81): row 18.5–62.5, page at 81 pt (the corner's
    bottom), 104.5 pt with the strip, which then keeps clear of the corner like the row.
  - No corner (fallback): the row sits 2 pt under the safe area's top, as before, but floats over
    the page, which runs under the status bar: page top = safe top + 50 (+ 38 strip).
- **The scroll view leaves the safe area out under a top bar**
  (`contentInsetAdjustmentBehavior = .never`, `setPageTopStart`): with the pages at the top edge,
  UIKit would add the 81 pt safe area to the page's own top inset and push the page under the
  whole zone. The bottom keeps the home indicator's inset by hand (`pageBottomInset`), for the
  scroll range and for WebKit's obscured and viewport insets, so fixed footers rest above it.
- **The address takes the room between the capsules first, then centers** (fill priority over
  centering): beside the corner the row is lopsided, and a centered pill shrank to a stub in the
  669 pt portrait window. Where nothing is in the way it is still capped at 560 pt and centered.
- **Reading state:** in the zone the address shrinks in place (70%) on the row, the buttons and
  strip rise and fade; hidden lifts it off the top edge. Under a short status bar the pill tucks
  under it as before.
- **No band at the top in any state (2026-11-27, follow-up).** Owner, on the device with this build: "when
  I scroll, the text field and buttons hide properly but the bar stays … I don't like that bar
  that stays there. Do we even need it at all? When the text field and buttons are showing I
  think it might look fine without that bar, so let's get rid of it all." The band was the page's
  own top inset: Pill and
  Hidden kept `obscuredContentInsets.top` at the status row's bottom (69 pt), and WebKit, which
  "adjusts how fixed and sticky elements are rendered near edges with non-zero obscured insets"
  (WKWebView.h), placed a fixed header at 69 pt and filled the 69 pt above it with the header's
  color; on pages without one, the iOS 26 top scroll edge effect blurred and dimmed the same
  strip. Nothing of Plain's served the reader there: the controls had gone.
  - **Chosen: in the status zone the page's obscured top inset is 0 in every state**
    (`TopChromeGeometry.obscuredInset(rest:)`). Reading (Pill, Hidden), the page and its fixed
    header run to the top edge under the status items, as Safari's full-screen reading does; the
    shrunken address floats alone over it. The status items' own legibility is the system's. At
    rest only the floating glass is over the page: the first line still starts under the row
    because the scroll range starts there (`contentInset.top` = `expandedInset`, 72.5 pt, never
    above the corner's bottom), not because of an obscured inset. A first version kept 72.5 pt at
    rest; WebKit then filled the area above a sticky header with its color, a full-width band
    behind the controls (Codex design review, round 1: blocking). **Cost, accepted:** revealed
    over a page read part way down, the controls float over a fixed header (and an in-page
    anchor lands under the row), as the glass floats over the page everywhere else. Under a
    full-width status bar (no corner) the inset follows the rest as before. A split's other pane
    gets the same (it kept the expanded inset, and so the band; Codex code review).
  - **No scroll edge effect on the page or the reader, top or bottom**
    (`UIScrollView.hideChromeEdgeEffects`), on every attached page, the split's other pane and the
    reader. The bottom one was already off (the page runs under the pill); the chrome's
    `UIScrollEdgeElementContainerInteraction`s (pill, buttons, strip) fed only these hidden
    effects and are gone. The glass's own dense tint keeps the controls readable.
  - **Rail:** the sidebar's column (paper, separator, shadow) runs from the top edge. Where the
    status zone beside it is empty (Left, with the status items in the trailing corner), its first
    row (New Tab) sits on the top bar's row, so no empty paper stands above it; beside the status
    corner (Right) its rows start under the safe area. Before, its separator and shadow stopped at
    81 pt and the root view's paper showed above it.
  - Phones and the outer screen are unchanged: their pages start under the status bar, where no
    top edge effect showed, and their bottom inset rules are `ChromeGeometry`'s.
- **Portrait:** the same code; the guides and regions say where the status items are.
- **Split:** one row spans both panes, as before, and keeps clear of the corner. Partly folded, the
  row keeps to the focused pane's side of the fold and to the corner.
- **Rail (Left, Right):** its tabs start under the safe area's top; the column itself runs from
  the top edge ("No band at the top" above), so it reads as one from there.
- **The strip** spans the lane under the row where it starts below the corner (72.5 > 69 on the
  device); where it would start beside it, it stops where the row does (`stripClearance`). Under
  the corner it rises on its way out only to the corner's bottom while it fades, so it never
  passes over the clock (Codex review, round 2).
- **Diagnostics:** the safe area, both corner-adaptive guides, the margins guide and the
  occlusion regions are logged when the bounds or guides change (`duo` category, debug level), so
  the device's numbers can be read back. `-PlainStatusCorner x,y,w,h` (Debug) forces a corner on
  the simulator for captures.
- **Not verified on the device:** the simulator draws no status bar in its resizable window and
  reports the safe area differently. Captures use the window's real camera region (portrait) and
  the forced device corner (landscape).
