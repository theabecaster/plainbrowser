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
| `BrowserCore` | nonisolated (`TabStore` MainActor) | Foundation | `AddressBarInput` (URL vs search rules), `SearchEngine`, `TabStore` (tabs, windows, panes, recently closed, auto-archive) and its value types (`TabModel.swift`), `TabPersistence` seam |
| `Storage` | nonisolated | GRDB | `AppDatabase` (migrations, async reads/writes), `HistoryVisit`, `TabSessionWriter` (the one tab writer), `loadTabSession`, archive reads and search, `TabStateStore` |
| `WebEngine` | MainActor | WebKit | `WebViewPool` (owns every `WKWebView`: warm-up, tiers, popups, crash recovery), `Tab` (observed page state), `TabWebViewHandler` (navigation/UI delegate), `NavigationRules` (pure policy), `DownloadCoordinator`, `ThumbnailService`, `EngineChoices`, seams in `EngineProtocols` |
| `ContentBlocking` | nonisolated | CryptoKit | `RuleListSource` (content-hash identifiers for compiled lists) |
| `Reader` | nonisolated; WebKit types MainActor | WebKit | `ReaderExtractor` (Readability in its own content world), `ReaderRenderer` (page template), `ReaderSchemeHandler` (`plain-reader:` scheme), `ReaderArticle` |
| `ShellUI` | MainActor | UIKit, WebKit, Storage, FeatureUI, WebEngine, ContentBlocking, Reader | `BrowserViewController` (page, URL pill, search sheet, page buttons; the tab on screen in `+Tab`, the engine's questions in `+EngineHost`), `BrowserSession` (pool, `EngineTabs`, `ContentBlocker`, `ReaderExtractor`, wired once), `EngineTabs` (engine `Tab`s in step with BrowserCore's `TabStore` by id), Storage adapters for the engine seams (`SiteStores`), `ReaderPresenter`, `PageStateView`, `AddressBarData` seam + `LiveAddressBarData`, `FeatureSheets` (Settings, History, favorites editor), `ChromeModel` (collapse, pull to refresh, chrome geometry: plain values tested on macOS) |
| `TabGalleryUI` | MainActor | UIKit | `TabGalleryViewController` (cards, grid, flick to close, reorder, menus), `TabGalleryDataSource` seam (the shell implements it over `TabStore`) + `TabGalleryDemoData` fake, `TabGalleryTransition` (snapshot animator page <-> card), `ThumbnailPipeline` (off-main decode), `TabGalleryLayout`/`TabGalleryMetrics`/`CardFlick` (plain values tested on macOS) |
| `FeatureUI` | MainActor | SwiftUI | `SettingsView`, `HistoryView`, `FavoritesEditor`, `AboutView` and their `@Observable` models; store protocols in `Stores.swift` |
| `DesignSystem` | MainActor | UIKit, SwiftUI | `Palette` (brand + semantic colors), `Spacing`/`Radius`/`Metrics`, `Motion` (named springs, Reduce Motion crossfade), `SpringDriver` (frame-by-frame spring at 80–120 Hz), `Haptic`, `Glass` (the one Liquid Glass helper and its container) |
| `PerfSignposts` | nonisolated | os | signpost subsystem, category and names |

`BrowserCore` and `Storage` never import UIKit or WebKit, so `swift test` runs their tests on macOS.
`swift test` builds every target, so files that import UIKit are wrapped in `#if canImport(UIKit)`
and compile to nothing on macOS.

## Data flow

### Launch

1. `main.swift` begins the `launch` signpost interval, then calls `UIApplicationMain`.
2. `SceneDelegate` creates the window with a `UINavigationController` (navigation bar hidden)
   around `BrowserViewController`, one `BrowserSession` and one `LiveAddressBarData`. It starts
   opening the database in a task off the main thread; the address bar, the sheets and the
   session's stores all wait on that one task.
3. `BrowserViewController.viewIsAppearing` makes the search field first responder before the
   first frame commits. It emits `launch.searchFieldReady`; the app ends `launch`.
4. After the first frame commits (a display link's first callback), `BrowserSession.start()`
   warms one offscreen `WKWebView`, which starts the WebContent and Networking processes, then,
   off the main thread: the remembered Desktop Site choices, the reader check's source, the rule
   lists (`ContentBlocker.prepare()`, compiled only on a miss) and the last session's tab
   (`EngineTabs.restoreLastTab()`: `loadTabSession`, then `TabStore(session:persistence:)`,
   then the selected tab's state file; `launch.restoreTab`).
5. Search stays first: the field keeps focus. The restored tab is attached under the search sheet
   (it gets the warm web view and restores history, scroll and sessionStorage), so closing the
   sheet shows the page; a submitted address loads in it, on top of its history.

### The address bar

1. The URL pill rests at the bottom; a tap grows it into the search sheet (`Motion.urlFocus`, the
   pill rides `keyboardLayoutGuide`). The field is the same view as the pill.
2. Each keystroke asks `AddressBarData.suggestions(for:update:)`. `LiveAddressBarData` reads
   history and favorites (`AppDatabase.addressBarCandidates`), shows them, then merges the
   engine's suggestions (`SuggestionClient`) with `AddressBarSuggestions.merge` and shows again.
   The best row sits nearest the field. An empty field shows favorites above the keyboard.
3. Return or a row tap → `AddressBarInput(text)` → `destination(searchingWith:)` with the saved
   engine.
4. The first load goes to the tab on screen, or a new one (`TabStore.open` through `EngineTabs`) that the pool attaches
   to the page container (it takes the warm web view). The shell never holds the web view: it
   follows the `Tab` (`TabObservation`, Observation tracking, at most once per run loop turn) for
   the pill, the buttons and the page state, and `Tab.onProgress` for the progress bar.
5. The engine's `NavigationSignposter` emits `nav.commit` and `nav.finish` for every main-frame
   navigation.
6. `Tab.onVisit` reports a load that ended on a new back-forward item; the shell records it
   through `AppDatabase.historyRecorder` (batched, off main), as `.typed` when the address bar
   asked for it. A picked page suggestion is remembered for its input (`recordPickedSuggestion`).
   Focus preconnects to the suggestion host; cached suggestions fill the list while the engine
   answers.

### Page chrome

- **Buttons.** Back, Forward, Share and More are the navigation controller's toolbar items with
  `.verticalPreferred`. Where `verticalBarEdge` reports a vertical bar (iPhone Duo), the toolbar
  shows and the system puts them in its side column. Elsewhere the toolbar stays hidden and the
  same actions sit in the glass `ButtonBar` under the pill.
- **Collapse without relayout.** The web view fills the view under the chrome. The scroll-view
  delegate moves the pill and bar 1:1 with transform and alpha (`ChromeCollapse`). When the finger
  lifts, the bar snaps toward the release velocity (`Motion.toolbarSnap`), run frame by frame by
  `SpringDriver` (a `UIUpdateLink` at 80–120 Hz) alongside the page's deceleration; a drag that
  starts mid-snap takes the bar from its on-screen position. When the bar rests,
  `obscuredContentInsets.bottom` switches once to the expanded or collapsed chrome
  (`PageInsetState`), waiting while the page bounces past an edge, so fixed footers and the
  page's end stay clear of the resting bar. `setMinimumViewportInset` gets the collapsed and
  expanded sizes, so `svh`/`lvh` never move.
- **Glass.** The pill and the button bar sit in one `Glass.makeContainer` view
  (`UIGlassContainerEffect`), with no layer shadow. Each carries a
  `UIScrollEdgeElementContainerInteraction` for the page's bottom scroll edge effect (WebKit
  hides it where it extends a fixed footer's color instead). Collapsed, the pill takes taps only.
- **Focus hook.** Focusing the address field calls `AddressBarData.prepareForTyping()` (a no-op by
  default), the place for a suggestion-host preconnect.
- **Pull to refresh.** The same delegate tracks a pull past the top; at 80 pt it arms with a
  selection haptic, and a release while armed reloads.
- **Page menu.** From More and a long press on the pill: Reload, Find on Page
  (`findInteraction`), Show Reader (only on a readerable page) or Hide Reader, Share, Copy Link,
  Desktop Site (`Tab.setContentModeOverride`, remembered per site), Turn Off / Turn On Blocking on
  This Site (remembered per site, applied with a reload), Add to (or Remove from) Favorites, then
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

1. The pool calls its `PageScripts` (the shell's `ReaderPageScripts`) for every tab's own
   `WKUserContentController`; it adds Reader's check with `installPrepared(in:)` (the source is
   read once off the main thread by `prepare()`; a controller made earlier gets it when ready). It
   adds only `Readability-readerable.js` (about 4 KB) as a main-frame user script at document
   end, in the reader content world. Each page reports `isProbablyReaderable` through
   `onAvailability`, and `isAvailable(in:)` returns the last report for the current URL.
2. When the user opens reader mode, `article(in:)` injects the full `Readability.js` into that
   document's reader world and parses a clone of the page. The page returns one JSON string,
   decoded off the main thread. The article is kept per web view and URL for repeat opens.
3. The page menu offers Show Reader only when `isAvailable(in:)` is true for the page.
   `ReaderPresenter` asks the pool for an auxiliary web view (`makeAuxiliaryWebView`, not a tab)
   with `ReaderSchemeHandler.install(in:)` on its configuration (the `plain-reader:` scheme, page
   JavaScript off). `show(_:in:)` renders the template off the main thread and loads
   `plain-reader://article/<id>`; the view fades in over the page when it has loaded. The page and
   `reader.css` come from the handler, with a no-script content security policy.
4. In the reader only reader URLs load; a tapped link closes it and opens in the tab. Back, Hide
   Reader or the page navigating closes it, and the page under it is as it was.

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
| `toolbar.snap` | interval | finger lifts (or a tap or load expands the bar) → bar at rest ("settled"), or a drag grabs it ("grabbed") |
| `toolbar.pageInset` | event | page's bottom inset switched to the resting bar ("expanded" / "collapsed") |
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
| `tab.open` / `tab.close` / `tab.select` | interval | shell, around the `TabStore` call → page on screen |
| `tab.archive` | interval | shell, around `archiveIdleTabs` (launch, foreground) |
| `tab.unarchive` / `tab.reopen` / `tab.closeAll` | event | archive restore / Reopen Closed Tab / Close All Tabs |
| `tab.sessionLoad` / `tab.save` | interval | Storage: launch read / one batched write, off main |

| `linkMenu.build` | interval | WebKit asks for a link menu → menu built (includes the pressed-image lookup) |
| `linkMenu.action` / `linkMenu.preview` | event / interval | a link menu item chosen / a preview web view made |
| `page.zoom` / `page.save` | event | zoom changed (message: percent) / Save PDF to Files |
| `downloads.show` / `download.preview` / `download.showInFiles` | event | Downloads sheet, Quick Look, Show in Files |
| `page.reader` | event | Show Reader / Hide Reader |
| `contentBlocking.prepare` / `.compile` / `.siteToggle` | interval | lists loaded / one list compiled / per-site toggle applied |
| `launch.restoreTab` | interval | after the first frame: last session's tab read and handed to the page |

## Tabs

`TabStore` (BrowserCore, MainActor, `@Observable`) is the single owner of the tab list. Engine
`Tab`s, web views, state files and thumbnails use the same `TabID`.

1. **Launch:** off main, `database.loadTabSession()` reads windows, open tabs and the recently
   closed stack (not the archive). On main, `TabStore(session:persistence: database.tabSession)`
   builds the store. Measured on macOS with 100 open + 1,000 archived tabs: read 1.5–1.6 ms off
   main, store build 0.14 ms on main (budget 5 ms).
2. **Model:** windows in order; each has regular tabs (pinned first), private tabs, and one or two
   panes, each showing a tab or the start page, with one focused pane. `open`, `select`, `close`,
   `closeAllTabs`, `move`, `setPinned`, `split`/`closePane`/`focusPane`/`swapPanes`,
   `reopenLastClosed`, `restoreArchived`. Rules and their reasons are in `FixedChoices` ("Tabs").
3. **Engine in step:** the shell calls `updatePage` and `setThumbnail` when the engine's `Tab`
   changes, and answers `isTabInUse` (media, PiP, fullscreen, capture, download) for the archive.
4. **Persistence:** every change hands `TabPersistence.enqueue` an ordered `TabChange`. Storage's
   `TabSessionWriter` writes 500 ms after the first change, off main, touching only changed rows;
   `flush()` on background. Private tabs never reach it.
5. **Auto-archive:** at launch and on each foreground, `archiveIdleTabs(after: settings.archiveAfter)`
   moves tabs not on screen for the interval to the archive, never pinned, visible, private or in-use
   tabs. Archived rows keep their state file; `searchArchivedTabs` (FTS5, title + address) and
   `archivedTabs` read it on demand. The archive keeps the newest 1,000.

## Web engine

The shell creates one `WebViewPool` and sets itself as `pool.host` (`EngineHost`: child tabs,
JavaScript dialogs, HTTP auth and certificate errors, external apps and universal links,
permission prompts, downloads, form resubmission; `BrowserViewController+EngineHost.swift`,
system alerts one at a time). Engine tabs come from `pool.makeTab(id:restoring:)` with the
`TabStore`'s ids; `EngineTabs` maps them and reports page changes (`updatePage`). A popup the pool
made joins the store with its own id (`TabStore.open(id:)`).
`BrowserSession` builds the pool with Storage-backed stores (`SiteStores.swift`): permissions
(`StorageSitePermissionStore`), Desktop Site (`StorageSiteContentModeStore`, an in-memory map
loaded after launch), content blocking (`ContentBlocker` as `UserContentRules`, its allow-list in
`StorageSiteAllowListStore`) and Reader's check (`ReaderPageScripts`).

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

5. **Page features (M4):**
   - *Link menu:* `TabWebViewHandler` answers `contextMenuConfigurationFor` with
     `WebViewPool.contextMenuConfiguration`. Items come from `LinkMenuRules`; the pressed image
     from a passive `pointerdown` listener in the engine's content world (WebKit's public element
     info has the link only). Open in New Tab / Background / Other Pane and Share go to the host
     (`LinkMenuPresenter`, defaults for every requirement); Copy Link, Download Linked File, Save
     Image and Copy Image run in the engine. The preview is a delegate-less web view from the pool;
     tapping it loads the link in the tab.
   - *Page zoom:* `tab.zoomIn()/zoomOut()/resetZoom()`, `tab.zoomPercent`; steps in
     `FixedChoices.pageZoomSteps`; remembered per site in `SitePageZoomStore` and applied at each
     main-frame commit.
   - *Find:* `tab.beginFind()` shows the system find bar (`isFindInteractionEnabled` on every web view).
   - *PDF:* `tab.isPDF` from the main-frame response; `tab.saveToDownloads()` runs a `WKDownload`.
   - *Media:* a script in every frame reports play and picture in picture; each report also asks
     WebKit (`requestMediaPlaybackState`), which sees players the page never attached. KVO gives
     fullscreen and capture. `tab.isBusy` combines them with downloads; `tab.refreshMediaState()`
     before an automatic archive or close.
   - *Downloads UI:* FeatureUI's `DownloadsView` and `FilePreviewController` (Quick Look) read
     `DownloadListSource`/`DownloadListItem`, which `DownloadCoordinator`/`Download` match exactly.
