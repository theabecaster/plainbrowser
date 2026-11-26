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
