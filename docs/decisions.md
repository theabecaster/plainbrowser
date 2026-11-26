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
- **Split into lists of at most 35k rules.** All three lists are converted together, as one
  Adblock list would be. Blocking lines are dealt round-robin into parts, and every part gets all
  exception lines (`@@`, `#@#`, `$badfilter`), because WebKit's `ignore-previous-rules` only
  reaches rules in the same compiled list. Result: 4 lists of ~33.9k rules, 135.5k in all,
  16 MB of JSON.
  - Measured on the iOS 27.2 simulator (iPhone 17), cold compile per list, alone: 25k rules
    1.0–1.7 s, 35k 1.8–2.8 s, 45k 2.2–3.8 s, 70k 3.5–3.9 s, one 126k list 5.6 s. Every size
    reloaded (lookup from a new process) in under 3 ms, so the iOS 18 failure above 45k did not
    reproduce on the simulator. 35k keeps a 10k margin under that reported limit with only 4
    lists. Check on the device.
- **Compile only when missing, never at launch.** Identifier `<name>-<first 16 hex of SHA-256>`.
  `ContentBlocker.prepare()` looks each list up (about 1 ms for all 4, warm) and compiles only a
  miss: first launch and app updates that change a list (about 6–9 s for all 4 on the
  simulator, off the main thread; WebKit compiles on its own queue). Old `blocklist-*` entries
  are then removed from the store.
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
  and alpha only, and the page's `obscuredContentInsets` stays at the collapsed size
  (docs/plan.md, engine rule 4).
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
