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
  switched when a snap ends (never during the top bounce), so the expanded bar never covers
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
  waits while the page is pulled past its top or bottom; a new snap drops a change still waiting. WebKit already extends a fixed footer's
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

## Xcode Cloud as the TestFlight fallback, free tier only (2026-11-26)

- **Chosen:** `scripts/testflight.sh --cloud` / `--auto` archive on Xcode Cloud when this Mac is
  busy with builds, tests and perf runs. Local archiving stays the default. Only the 25 compute
  hours a month included in the developer membership are used, never a paid plan.
- **Why Xcode Cloud:** it is the only hosted macOS builder that costs nothing on top of the
  membership. It signs with the team's cloud-managed certificates, so it needs no secrets in the
  repo.
- **Cloud archives, this Mac uploads.** Xcode Cloud stamps every build it distributes with its own
  counter (1, 2, 3...), which would sort below our `yyMMddHHmm` builds. So the workflow does not
  distribute. The script downloads the archive, sets the same build number a local build gets,
  and uploads it the usual way. Export and upload are light work for a busy Mac.
- **Manual start only, guarded.** The workflow has no triggers, so it never spends hours on its
  own. `setup` disables every other workflow, and `start` refuses past 20 hours in the last 31
  days. Without a subscription Apple can't bill: at 25 hours, builds stop until the next month.
