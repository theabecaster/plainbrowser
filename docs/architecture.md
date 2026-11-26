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
| `WebEngine` | MainActor | WebKit | `WebViewPool` (owns every `WKWebView`: warm-up, tiers, popups, crash recovery), `Tab` (observed page state), `TabWebViewHandler` (navigation/UI delegate), `NavigationRules` (pure policy), `DownloadCoordinator`, `ThumbnailService`, `EngineChoices`, seams in `EngineProtocols` |
| `ContentBlocking` | nonisolated | CryptoKit | `RuleListSource` (content-hash identifiers for compiled lists) |
| `Reader` | nonisolated; WebKit types MainActor | WebKit | `ReaderExtractor` (Readability in its own content world), `ReaderRenderer` (page template), `ReaderSchemeHandler` (`plain-reader:` scheme), `ReaderArticle` |
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
  History, Edit Favorites and Settings… in their own last section. More is always enabled:
  without a page the menu holds only that last section.

### Sheets and settings

- **Presenting.** `FeatureSheets` (ShellUI) builds the FeatureUI models over the database and
  wraps each view in a page-sheet `UIHostingController`; `BrowserViewController` presents it.
  Settings and History come from the page menu; the favorites editor from a long press on the
  favorites strip ("Edit Favorites", after which the search field opens again) or the page menu. A History row
  closes the sheet and loads its page.
- **Live settings.** `LiveSettingsStore` saves through `AppDatabase`, then hands the saved
  `BrowserSettings` to `LiveAddressBarData.apply`, so the next search and suggestion request use
  the new engine. Tab layout and archive interval are stored and held there for the tab features.
- **Clear History and Data.** `LiveBrowsingDataClearer`: history through the recorder, favicons,
  then `WKWebsiteDataStore.default().removeData` for every type (the pool's configuration uses
  the default store).
- **History writes.** `AppDatabase.historyRecorder` is the one writer. Visits are recorded when a
  load ends on a new back-forward item (a failed or stopped load is not recorded twice); title
  changes only once that item is recorded, so a title never renames an earlier visit. History
  reads and deletes first write what the shell has queued (`ShellHistoryStore`). `BrowserViewController.recordsHistory` is the seam for private tabs.

### Reader

1. While building a tab's configuration, the shell calls `ReaderExtractor.install(in:)`. It adds
   only `Readability-readerable.js` (about 4 KB) as a main-frame user script at document end, in
   the reader content world. Each page reports `isProbablyReaderable` through
   `onAvailability`, and `isAvailable(in:)` returns the last report for the current URL.
2. When the user opens reader mode, `article(in:)` injects the full `Readability.js` into that
   document's reader world and parses a clone of the page. The page returns one JSON string,
   decoded off the main thread. The article is kept per web view and URL for repeat opens.
3. `ReaderSchemeHandler.install(in:)` sets up the reader web view's configuration (the
   `plain-reader:` scheme, page JavaScript off) before the pool creates it. `show(_:in:)` renders
   the template off the main thread and loads `plain-reader://article/<id>`. The page and
   `reader.css` come from the handler, with a no-script content security policy.

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
| `reader.extract` | interval | reader request → article returned (or not readerable) |
| `reader.show` | interval | show article → rendered page handed to the reader web view |
| `tab.attach` | interval | `WebViewPool.attach` (tab switch) |
| `tab.restore` | interval | discarded tab's restore start → its page commits |
| `tab.discard` | interval | discard start (state read) → web view released |
| `tab.snapshot` | interval | thumbnail `takeSnapshot` → image returned |
| `tab.crash` | event | a tab's WebContent process terminated |

## Web engine

The shell creates one `WebViewPool` and sets itself as `pool.host` (`EngineHost`: child tabs,
JavaScript dialogs, HTTP auth and certificate errors, external apps and universal links,
permission prompts, downloads, form resubmission). Tabs come from `pool.makeTab(id:restoring:)`; `TabStore` keeps them.

1. **Show a tab:** `pool.attach(tab, to: paneView)`. A discarded tab restores sessionStorage, then
   `interactionState`. `pool.detach(tab)` stores a thumbnail and applies the tier limits.
2. **Navigate:** `tab.load(url)`, `goBack()`, `reload()`. `TabWebViewHandler.decidePolicyFor`
   handles downloads, external schemes, desktop/mobile (pane size or the site's override), content
   rules (`UserContentRules.apply` on the tab's own controller). Universal links are WebKit's.
3. **State out:** `Tab` properties (`@Observable`), progress through `tab.onProgress`, thumbnails
   through `pool.thumbnail(for:)` when `tab.thumbnailRevision` changes.
4. **Session restore:** pass Storage's `TabStateStore` to the pool. It writes each tab after
   loads and detaches (debounced), on discard and on `willResignActive` (`saveAllTabs()`). At
   launch, decode each file with `TabRestorationState(encoded:)` and pass it to
   `makeTab(id:restoring:)`.

