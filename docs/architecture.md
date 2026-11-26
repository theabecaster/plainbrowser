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
| `ShellUI` | MainActor | UIKit, WebKit, Storage, FeatureUI | `BrowserViewController` (page, URL pill, search sheet, page buttons), `AddressBarData` seam + `LiveAddressBarData`, `FeatureSheets` (Settings, History, favorites editor), `ChromeModel` (collapse, pull to refresh, chrome geometry: plain values tested on macOS) |
| `TabGalleryUI` | MainActor | — | `TabGalleryLayout` (even-column rule) |
| `FeatureUI` | MainActor | SwiftUI | `SettingsView`, `HistoryView`, `FavoritesEditor`, `AboutView` and their `@Observable` models; store protocols in `Stores.swift` |
| `DesignSystem` | MainActor | UIKit, SwiftUI | `Palette` (brand + semantic colors), `Spacing`/`Radius`/`Metrics`, `Motion` (named springs, Reduce Motion crossfade), `Haptic`, `Glass` (the one Liquid Glass helper) |
| `PerfSignposts` | nonisolated | os | signpost subsystem, category and names |

`BrowserCore` and `Storage` never import UIKit or WebKit, so `swift test` runs their tests on macOS.
`swift test` builds every target, so files that import UIKit are wrapped in `#if canImport(UIKit)`
and compile to nothing on macOS.

## Data flow

### Launch

1. `main.swift` begins the `launch` signpost interval, then calls `UIApplicationMain`.
2. `SceneDelegate` creates the window with a `UINavigationController` (navigation bar hidden)
   around `BrowserViewController`, one `WebViewPool` and one `LiveAddressBarData`. It opens the
   database in a task off the main thread and hands it to the address bar when ready.
3. `BrowserViewController.viewIsAppearing` makes the search field first responder before the
   first frame commits. It emits `launch.searchFieldReady`; the app ends `launch`.
4. `viewDidAppear` schedules `WebViewPool.warmUp()` on the next main run loop turn: one offscreen
   `WKWebView` loads `about:blank`, which starts the WebContent and Networking processes.

### The address bar

1. The URL pill rests at the bottom; a tap grows it into the search sheet (`Motion.urlFocus`, the
   pill rides `keyboardLayoutGuide`). The field is the same view as the pill.
2. Each keystroke asks `AddressBarData.suggestions(for:update:)`. `LiveAddressBarData` reads
   history and favorites (`AppDatabase.addressBarCandidates`), shows them, then merges the
   engine's suggestions (`SuggestionClient`) with `AddressBarSuggestions.merge` and shows again.
   The best row sits nearest the field. An empty field shows favorites above the keyboard.
3. Return or a row tap → `AddressBarInput(text)` → `destination(searchingWith:)` with the saved
   engine.
4. The first load takes the warm web view from the pool (`dequeueWebView()`), attaches
   `NavigationSignposter`, and puts it under the chrome. Later loads reuse it.
4. `NavigationSignposter` emits `nav.commit` (start → commit) and `nav.finish` (start → finish or
   failure) for every main-frame navigation.
5. A finished load is recorded through `AppDatabase.historyRecorder` (batched, off main).

### Page chrome

- **Buttons.** Back, Forward, Share and More are the navigation controller's toolbar items with
  `.verticalPreferred`. Where `verticalBarEdge` reports a vertical bar (iPhone Duo), the toolbar
  shows and the system puts them in its side column. Elsewhere the toolbar stays hidden and the
  same actions sit in the glass `ButtonBar` under the pill.
- **Collapse without relayout.** The web view fills the view under the chrome. Its
  `obscuredContentInsets.bottom` is the collapsed chrome and changes only with geometry
  (rotation, fold, bar mode), never while scrolling; `setMinimumViewportInset` gets the collapsed
  and expanded sizes. The scroll-view delegate moves the pill and bar 1:1 with transform and alpha
  (`ChromeCollapse`), then snaps with `Motion.toolbarSnap` when the scroll stops.
- **Pull to refresh.** The same delegate tracks a pull past the top; at 80 pt it arms with a
  selection haptic, and a release while armed reloads.
- **Page menu.** From More and a long press on the pill: Reload, Find on Page
  (`findInteraction`), Share, Copy Link, Desktop Site, Add to (or Remove from) Favorites, then
  History and Settings… in their own last section. More is always enabled: without a page the
  menu holds only History and Settings….

### Sheets and settings

- **Presenting.** `FeatureSheets` (ShellUI) builds the FeatureUI models over the database and
  wraps each view in a page-sheet `UIHostingController`; `BrowserViewController` presents it.
  Settings and History come from the page menu; the favorites editor from a long press on the
  favorites strip ("Edit Favorites"), after which the search field opens again. A History row
  closes the sheet and loads its page.
- **Live settings.** `LiveSettingsStore` saves through `AppDatabase`, then hands the saved
  `BrowserSettings` to `LiveAddressBarData.apply`, so the next search and suggestion request use
  the new engine. Tab layout and archive interval are stored and held there for the tab features.
- **Clear History and Data.** `LiveBrowsingDataClearer`: history through the recorder, favicons,
  then `WKWebsiteDataStore.default().removeData` for every type (the pool's configuration uses
  the default store).
- **History writes.** `AppDatabase.historyRecorder` is the one writer. Visits are recorded when a
  load ends on a new back-forward item (a failed or stopped load is not recorded twice); titles
  as they arrive. `BrowserViewController.recordsHistory` is the seam for private tabs.

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
| `address.submit` | interval | Return or a suggestion tap → load handed to the web view |
| `urlBar.focus` | interval | tap on the pill → field first responder, sheet layout applied |
| `search.suggestions` | interval | keystroke → local suggestions on screen |
| `toolbar.collapse` | interval | bar starts moving → bar settled |
| `ptr.arm` / `ptr.refresh` | event | pull crosses 80 pt / released armed |
| `pageMenu.open` | event | page menu built |
| `nav.back` / `nav.forward` | event | Back / Forward button |
| `share.open` | event | share sheet shown |
| `page.favorite` | event | Add to / Remove from Favorites |
| `settings.open` / `history.show` / `favorites.editorOpen` | event | sheet presented |
