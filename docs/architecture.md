# Architecture

Plain is a thin app target over one local Swift package, `Packages/PlainKit`. The package's target
graph enforces the layering: a target can import only what it lists, and no lower layer lists a
higher one, so an upward import does not compile.

## Module map

```
Plain (app target: main.swift, AppDelegate, SceneDelegate)
  └─ ShellUI ─────────┐   TabGalleryUI   FeatureUI        UI layer, MainActor by default
       │              │        │             │
  WebEngine  ContentBlocking  Reader         │            engine layer
       │              │        │             │
       └──────────── Storage ────────────────┘            persistence (GRDB), nonisolated
                         │
                    BrowserCore                           pure rules and models, nonisolated

  Leaves, usable from any layer above BrowserCore: DesignSystem (UI), PerfSignposts (os only)
```

| Target | Isolation | Imports | Holds today (M0) |
|---|---|---|---|
| `BrowserCore` | nonisolated | Foundation | `AddressBarInput` (URL vs search rules), `SearchEngine` |
| `Storage` | nonisolated | GRDB | `AppDatabase` (migrations, async reads/writes), `HistoryVisit` |
| `WebEngine` | MainActor | WebKit | `WebViewPool` (owns every `WKWebView`, warm-up), `NavigationSignposter` |
| `ContentBlocking` | nonisolated | CryptoKit | `RuleListSource` (content-hash identifiers for compiled lists) |
| `Reader` | nonisolated | — | `ReaderWorld` (content world name) |
| `ShellUI` | MainActor | UIKit, WebKit | `BrowserViewController` (search field + page) |
| `TabGalleryUI` | MainActor | — | `TabGalleryLayout` (even-column rule) |
| `FeatureUI` | MainActor | SwiftUI | `AboutView` |
| `DesignSystem` | MainActor | UIKit | `Palette` (Paper & Lagoon colors) |
| `PerfSignposts` | nonisolated | os | signpost subsystem, category and names |

`BrowserCore` and `Storage` never import UIKit or WebKit, so `swift test` runs their tests on macOS.
`swift test` builds every target, so files that import UIKit are wrapped in `#if canImport(UIKit)`
and compile to nothing on macOS.

## Data flow

### Launch

1. `main.swift` begins the `launch` signpost interval, then calls `UIApplicationMain`.
2. `SceneDelegate` creates the window with `BrowserViewController` and one `WebViewPool`.
3. `BrowserViewController.viewIsAppearing` makes the search field first responder before the
   first frame commits. It emits `launch.searchFieldReady`; the app ends `launch`.
4. `viewDidAppear` schedules `WebViewPool.warmUp()` on the next main run loop turn: one offscreen
   `WKWebView` loads `about:blank`, which starts the WebContent and Networking processes.

### Submitting an address

1. Return in the field → `AddressBarInput(text)` classifies it as `.url` or `.search`.
2. `destination(searchingWith: .google)` gives the URL to load.
3. The first load takes the warm web view from the pool (`dequeueWebView()`), attaches
   `NavigationSignposter`, and adds it above the field. Later loads reuse it.
4. `NavigationSignposter` emits `nav.commit` (start → commit) and `nav.finish` (start → finish or
   failure) for every main-frame navigation.

## Signposts

Subsystem `dev.abrahamgonzalez.plainbrowser`, category `perf`. Names live in
`PerfSignposts.Signposts`, which the app and the UI tests both import, so a metric always measures
exactly what the app emits.

| Name | Kind | From → to |
|---|---|---|
| `launch` | interval | `main` → search field first responder |
| `launch.searchFieldReady` | event | search field first responder |
| `nav.commit` | interval | provisional navigation start → commit |
| `nav.finish` | interval | provisional navigation start → finish or failure |
