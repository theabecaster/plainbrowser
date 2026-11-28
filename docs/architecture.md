# Architecture

Plain is a thin app target over one local Swift package, `Packages/PlainKit`. The package's target
graph enforces the layering: a target can import only what it lists, and no lower layer lists a
higher one, so an upward import does not compile.

## Module map

```
Plain (app target: main.swift, AppDelegate, SceneDelegate, Intents/)
  └─ ShellUI ─────────┐   TabGalleryUI   FeatureUI        UI layer, MainActor by default
       │              │        │             │
  WebEngine  ContentBlocking  Reader  SystemSync          engine layer
       └── Intelligence (Reader + WebEngine: on-device summaries)
       │              │        │             │
       └──────────── Storage ────────────────┘            persistence (GRDB), nonisolated
                         │
                    BrowserCore                           pure rules and models, nonisolated

  Leaves, usable from any layer above BrowserCore: DesignSystem (UI), PerfSignposts (os only),
  PlainShared (Foundation only)

PlainWidgets (widget extension: the bundle and the controls)
  └─ WidgetUI ── PlainShared, DesignSystem
```

The widget extension never links Storage, WebEngine or GRDB: it reads the favorites file the app
writes to the App Group (`SharedFavoritesFile`).

| Target | Isolation | Imports | Holds today (M0) |
|---|---|---|---|
| `BrowserCore` | nonisolated (`TabStore` MainActor) | Foundation | `AddressBarInput` (URL vs search rules), `SearchEngine`, `TabStore` (tabs, windows, panes, recently closed, auto-archive) and its value types (`TabModel.swift`), `TabPersistence` seam, `ControlRules`/`GalleryRules` (docs/state-rules.md as plain values: which control shows, dims or hides in each state) |
| `Storage` | nonisolated | GRDB | `AppDatabase` (migrations, async reads/writes), `HistoryVisit`, `TabSessionWriter` (the one tab writer), `loadTabSession`, archive reads and search, `TabStateStore` |
| `WebEngine` | MainActor | WebKit | `WebViewPool` (owns every `WKWebView`: warm-up, tiers, popups, crash recovery), `Tab` (observed page state), `TabWebViewHandler` (navigation/UI delegate), `NavigationRules` (pure policy), `DownloadCoordinator`, `ThumbnailService`, `EngineChoices`, seams in `EngineProtocols`, `PageTranslation` (Translate Page's scripts in their own world, `PageTranslator` seam, `+Translation` on the pool), `PageExport` (print formatter, paginated PDF) |
| `ContentBlocking` | nonisolated | CryptoKit, WebKit | `ContentBlocker` and `RuleListSource` (content-hash identifiers for compiled lists), `CookieBanners` (DuckDuckGo autoconsent in its own world, per-site off, `SiteCookieBannersStore` seam) |
| `Reader` | nonisolated; WebKit types MainActor | WebKit, DesignSystem (`PaperTexture` only) | `ReaderExtractor` (Readability in its own content world), `ReaderRenderer` (page template), `ReaderSchemeHandler` (`plain-reader:` scheme), `ReaderArticle` |
| `Intelligence` | MainActor by default | Reader, WebEngine, BrowserCore, PerfSignposts, FoundationModels | `SummaryRun` (Browse for Me and Summarize Page: results page, sources in parallel within a time budget, fit to the context, stream), `SummaryModel` (`FoundationSummaryModel`: Apple's on-device model, guided generation; `ScriptedSummaryModel` for tests), `HiddenBrowsing` (results and sources in the pool's hidden views, one non-persistent store per run), `SummaryPrompt` |
| `ShellUI` | MainActor | UIKit, WebKit, Storage, FeatureUI, TabGalleryUI, WebEngine, ContentBlocking, Reader | `BrowserViewController` (page, URL pill, search sheet, page buttons; the tab on screen in `+Tab`, the engine's questions in `+EngineHost`, the gallery in `+Gallery`, the tabs button, archive and link menu in `+Tabs`, zoom, PDF and downloads in `+PageFeatures`), `TabSwipe` (bar swipe between tabs, swipe up to the gallery), `GalleryTabs` (the gallery's data source over `EngineTabs`), `ShellToast`, `BrowserSession` (pool, `EngineTabs`, `ContentBlocker`, `CookieBanners`, `ReaderExtractor`, the translator, wired once), `PageTranslators` (`AppleTranslator` over the Translation framework; a Debug stand-in for UI tests), `EngineTabs` (engine `Tab`s in step with BrowserCore's `TabStore` by id), Storage adapters for the engine seams (`SiteStores`), `ReaderPresenter`, `PageStateView`, `AddressBarData` seam + `LiveAddressBarData`, `FeatureSheets` (Settings, History, Reading List, favorites editor, Downloads, archive), `PageSheet` (the page sheet: address row, tiles, rows), `+AddressFocus` (what the focused field shows before typing, the copied link, editing the page's address), `ChromeModel` (collapse, pull to refresh, chrome geometry: plain values tested on macOS), the Duo layout: `DuoLayout` (panes, sidebar, chrome lane, folds: plain values tested on macOS), `PanesController` (`UIArrangementViewController` with two `PaneSlot`s), `+Panes` (split, focus, fold resize), `+SideTabs` and `SideTabs` (the sidebar's data source), `+SidePane` and `SidePane` (Reader, Find and History beside the page), `AppStores`/`AppTabs` (what every window shares), `Windows` and `+Windows` (Open in New Window, switching) |
| `TabGalleryUI` | MainActor | UIKit | `TabGalleryViewController` (app-switcher cascade on compact width, sideways grid pages on regular width, one `UIScrollView` whose cards are placed every frame by position and transform only; swipe up to close, menus), `TabCardView`, `CardMotion` (springs for gaps, new cards and scroll shifts on one update link), `TabGalleryReorder` (drag to reorder, edge auto-scroll), `EmptyTabView` + `MarkView` (the start screen with the spinnable Stem mark; the shell shows it for an empty tab), `TabGalleryDataSource` seam (the shell implements it over `TabStore`) + `TabGalleryDemoData` fake, `TabGalleryTransition` (snapshot animator page <-> card; zooms the cards about the card; `track`/`release` for the swipe up from the bar), `ThumbnailPipeline` (off-main decode), `TabGalleryLayout`: `CascadeCurve`/`TabGalleryMetrics`/`CardSwipe` (plain values tested on macOS; numbers in `docs/research/arc-tab-switcher.md`), side tabs: `SideTabsViewController` + `SideTabCell`, `SideTabsDataSource` seam, `SidebarState`/`SidebarDrag` (plain values), the Above strip: `TabStripViewController` + `TabStripCell` |
| `FeatureUI` | MainActor | SwiftUI | `SettingsView`, `HistoryView`, `ReadingListView`, `FavoritesEditor`, `AboutView` and their `@Observable` models; store protocols in `Stores.swift`; the first-run intro (`Intro/`) and the launch splash (`Splash/`: `LaunchSplash`, `SplashArt`, `SplashTimeline`, `SplashRenderer`, plain values tested on macOS; Core Animation and Metal, no SwiftUI) |
| `DesignSystem` | MainActor | UIKit, SwiftUI | `Palette` (brand + semantic colors), `Spacing`/`Radius`/`Metrics`, `Motion` (named springs, Reduce Motion crossfade), `SpringDriver` (frame-by-frame spring at 80–120 Hz), `Haptic` (eight kinds on per-window generators, throttled and recorded; `ThresholdLatch` for both-ways thresholds), `Glass` (the one Liquid Glass helper and its container), `Paper` (the textured Paper background: `apply(to:)`, `PaperBackground`) and `PaperTexture` (the tile, CoreGraphics only) |
| `PerfSignposts` | nonisolated | os | signpost subsystem, category and names |
| `PlainShared` | nonisolated (`CommandInbox` MainActor) | Foundation, BrowserCore (TestIsolation) | `PlainCommand` (what the system asks for), `PlainLink` (`plainbrowser:` links both ways), `CommandInbox` (App Intents to the scene), `AppGroup`, `SharedFavorite`/`SharedFavoritesFile` (the App Group file), `SearchWidgetContent` |
| `SystemSync` | actor | Storage, PlainShared, BrowserCore, CoreSpotlight, WidgetKit | `SystemSync` (follows `AppDatabase.favoritesChanges()`: Spotlight, the App Group file, widget timelines; Clear History empties Spotlight), `SpotlightIndexing` seam + `CoreSpotlightIndex`, `WidgetReloading` seam, `SystemActivity` (Handoff and Spotlight activities to commands) |
| `WidgetUI` | views MainActor | SwiftUI, WidgetKit, PlainShared, DesignSystem | `SearchWidget` (small, medium, Lock Screen), `SearchProvider` (one entry, `.never`), `SearchWidgetView` and its parts (`DawnWindow`, `SearchField`, `FavoriteDisc`) |

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
   Before that it reads the window's `LaunchHint` (user defaults, `LaunchMemory`) and picks the
   opening screen with `LaunchRules.opening`; with a last tab it starts decoding the tab's saved
   picture off the main thread (`LaunchPicture`) and hands the `LaunchPlan` to the browser.
3. `BrowserViewController.viewIsAppearing`, before the first frame commits: with no last tab it
   makes the search field first responder (`launch.searchFieldReady`); with one it puts the
   picture over the page container (waiting at most 40 ms for the decode, `launch.pictureWait`)
   with the bar resting and following the hint, or, after 4 hours away, the search field over it
   with the frost (`+Launch`). The app ends `launch` (message: the opening screen).
   **The launch splash** (a cold launch's first scene; `SplashGate`) is a second window above
   the browser's (or the intro's), made in the same turn, so it is in the app's first frame. The
   browser underneath is built exactly as without it. The first touch ends the splash and is
   not passed on; later ones go through the splash window to the app. As the scene connects, before the browser is
   built, `LaunchSplash.init` starts two jobs off the main thread: the splash's three pictures
   drawn with Core Graphics (`SplashArt`: the icon's field, the mark, the dawn in its window;
   they depend only on the icon and the screen's scale) and the GPU kit (`SplashKit`: shaders
   compiled from source, two pipelines, the pictures as textures, the mesh's index buffer). The
   first frame takes the pictures only if they are drawn by then (it never waits; a launch that
   outran them has no splash) and shows them as three layers. The dive starts `splashMinimumTime` after the
   process started and at least `splashHandoff` after the first frame. If the kit is ready
   `splashRendererLead` before that, `SplashRenderer` draws its still first frame off the main
   thread (the same pixels as the layers), the main thread swaps it in within one transaction,
   and a render thread clocked by a `CAMetalDisplayLink` draws the dive: one sheet (a ring mesh
   around the P's counter) whose cut edge rolls back while the camera goes through. Otherwise
   Core Animation plays a plain iris on the render server (`LaunchSplashView.playIris`). Either
   way the main thread only schedules; nothing of the dive runs on it.
4. After the first frame commits (a display link's first callback), `BrowserSession.start()`
   warms one offscreen `WKWebView`, which starts the WebContent and Networking processes, then,
   off the main thread: the remembered Desktop Site choices, the reader check's source, the rule
   lists (`ContentBlocker.prepare()`, compiled only on a miss) and the last session's tab
   (`EngineTabs.restoreSession()`: `loadTabSession`, then `TabStore(session:persistence:)`; every
   saved tab is in the list, none has a web view; `launch.restoreTab`). The selected tab is made
   with `pool.makeSavedTab`, which reads its state file off main when it first attaches. Then, at
   background priority, state files and thumbnails no row names are deleted (`pruneFiles`).
5. The restored tab is attached under the picture or the search sheet (it gets the warm web view
   and restores history, scroll and sessionStorage). The picture fades once the page has loaded
   (`launch.pictureHandoff`). Under a fresh search, closing the sheet shows the page and a
   submitted address opens a new tab; under a plain launch search (no picture), the restored tab
   shows through the frost the same way.
6. Leaving: `sceneWillResignActive` asks the browser to remember the page on screen
   (`rememberForLaunch`: a 2x snapshot, encoded and written off the main thread, and the hint);
   `sceneWillEnterForeground` hands the time away to `appDidReturn`, which opens a fresh search
   after 4 hours (`LaunchRules.onReturn`).

### The address bar

1. The URL pill rests at the bottom; a tap grows it into the search sheet (`Motion.urlFocus`, the
   pill rides `keyboardLayoutGuide`). The field is the same view as the pill.
2. Each keystroke asks `AddressBarData.suggestions(for:update:)`. `LiveAddressBarData` reads
   history, favorites and the reading list (`AppDatabase.addressBarCandidates`), shows them, then merges the
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

- **Buttons.** Back, Forward, Tabs, Share and More are the navigation controller's toolbar items with
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
  (`Tab.beginFind`), Show Reader (only on a readerable page) or Hide Reader, Save PDF to Files
  (only on a PDF), Share, Copy Link, the Zoom row (− / percentage / +, remembered per site; it
  keeps the menu open and updates it in place from the pill and the glass bar), Desktop Site
  (`Tab.setContentModeOverride`, remembered per site), Turn Off / Turn On Blocking on This Site
  (remembered per site, applied with a reload), Add to (or Remove from) Favorites, then Downloads
  (while there are any), History, Edit Favorites and Settings… in their own last section. More is
  always enabled: without a page the menu holds only that last section.
- **State rules.** `+Rules` describes the screen as a `ChromeState` and applies what
  `ControlRules` answers: each bar button shown, dimmed or hidden in place (`ButtonBar.setVisibility`),
  the tabs slot's face, the page and tabs menus' items, the gestures and the start screen's
  shortcuts. The gallery does the same with `GalleryRules`. No view decides visibility itself.
- **Tabs button.** Two faces (docs/state-rules.md §3): Tabs opens the gallery whenever it has a
  card (one page tab included), hidden on the start screen with nothing else open. A long press is the tabs
  menu: New Tab, New Private Tab, Previous / Next Tab ("Or swipe the address bar"), Show All Tabs
  ("Or swipe up from the address bar"), Reopen Closed Tab, Archived Tabs, Close Tab (with a Reopen
  toast). A one-time TipKit tip teaches the long press (`TabsMenuTip`); More carries the same
  items on top.
- **Empty tabs.** An empty tab exists only while on screen: `show(_:)` drops one it leaves
  (`EngineTabs.discard`, no Reopen), New Tab reuses one, the gallery never lists one.
- **Toast.** `ShellToast` floats above the pill for a few seconds: Reopen after Close Tab, a
  finished or failed download (Show opens Downloads), a link opened in the background (Show).

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
  the default store), then the app's hook (Spotlight, see System integration).
- **History writes.** `AppDatabase.historyRecorder` is the one writer. Visits are recorded when a
  load ends on a new back-forward item (a failed or stopped load is not recorded twice); title
  changes only once that item is recorded, so a title never renames an earlier visit. History
  reads and deletes first write what the shell has queued (`ShellHistoryStore`). A private tab records nothing (`recordsHistory(for:)`).

### System integration (v0.2)

docs/research/system-integration.md has the API facts and choices.

1. **One way in.** Everything the system asks for is a `PlainCommand`: App Intents (Shortcuts,
   Siri, Spotlight action tiles, the controls) send one to `CommandInbox`; widget taps are
   `plainbrowser:` links (`PlainLink`); Spotlight results and Handoff pages are activities
   (`SystemActivity`). `SceneDelegate` queues them until the browser is up (a search also waits
   for the saved engine), skips the intro for them, then calls `BrowserViewController.perform`,
   which ends where a tap would: a new tab with the field, a page, or the gallery.
2. **Intents** live in the app target (`Plain/Intents`), so their metadata is extracted there.
   `OpenPlainIntent`, the controls' action, is compiled into the app and the widget extension and
   runs only in the app (`allowedExecutionTargets`). Open Favorite's entity query reads the App
   Group file, never the database.
3. **Favorites leave the app one way.** `SystemSync` follows the favorites table through a GRDB
   `ValueObservation` (`AppDatabase.favoritesChanges`), so no writer calls it. Each change writes
   the App Group file, replaces Plain's Spotlight domain, reloads widget timelines and updates the
   App Shortcuts' parameters. Operations run one at a time, to the end, in order. What Spotlight
   took is remembered apart (`spotlight.json`, written only on success), so a failed index is
   retried. An unchanged list on launch costs two small file reads. It starts
   `FixedChoices.systemSyncLaunchDelay` after the database opens, at background priority.
   The app makes it with `SystemSync.live`: in an isolated test run the App Group is the run's own
   folder and Spotlight, widget reloads and App Shortcuts are stand-ins (Handoff is skipped too).
4. **Clear History and Data** ends with `FeatureSheets.didClearBrowsingData`: Spotlight is
   emptied (and iOS's saved activities), then the favorites, which the clear keeps, go back.
5. **Handoff.** `tabChanged` and `clearPage` call `updateHandoff`: the responder's
   `userActivity` is a browsing-web activity for the page on screen, or nil for a private tab,
   the start screen, a failed load or the reader. Never eligible for search or prediction.
6. **Widgets** (`PlainWidgets` target, views in `WidgetUI`) read the App Group file in their
   timeline provider; the app reloads them on change, so the timeline never refreshes itself.

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
| `launch` | interval | `main` → first screen ready: search field first responder, or the last tab's picture and resting bar (message: opening screen) |
| `launch.pictureDecode` / `launch.pictureWait` | interval | the last tab's picture decoding off main from scene connect / the first frame waiting for it (only when not ready) |
| `launch.pictureHandoff` | interval | restored page attached under the picture → picture faded ("loaded", "timedOut", "failed", "dropped") |
| `launch.pictureSave` | interval | the picture encoded and written off main when the app resigns active |
| `launch.freshSearch` | event | a fresh search opened over the last tab ("launch" or "return") |
| `launch.splashBuild` | interval | the launch splash's main-thread work before the first frame (window, layers, the icon read); inside `launch.firstFrame` |
| `launch.splash` | interval | the splash on screen: first frame → gone (message: "metal", "iris", "crossfade", "skipped", "left"; an event "missed" when the pictures were late and no splash showed) |
| `launch.splashDive` | interval | the dive: its renderer chosen → the app filling the screen |
| `launch.splashFrames` | event | the GPU dive's frame timing: frames, intervals, late frames, CPU encode and GPU time |
| `launch.searchFieldReady` | event | search field first responder |
| `nav.commit` | interval | provisional navigation start → commit |
| `nav.finish` | interval | provisional navigation start → finish or failure |
| `address.submit` | interval | Return or a suggestion tap → load handed to the web view |
| `urlBar.focus` | interval | tap on the pill → field first responder, sheet layout applied |
| `search.suggestions` | interval | keystroke → local suggestions on screen |
| `toolbar.collapse` | interval | bar starts moving → bar settled |
| `toolbar.snap` | interval | finger lifts (or a tap or load expands the bar) → bar at rest ("settled"), or a drag grabs it ("grabbed") |
| `toolbar.pageInset` | event | page's bottom inset switched to the resting bar ("expanded" / "collapsed" / "hidden"); a reveal switches it as it starts |
| `cookieBanners.engine` | event | the cookie banner engine went into a page, and why ("site rule", "host", "page") |
| `ptr.arm` / `ptr.refresh` | event | pull crosses 80 pt / released armed |
| `pageMenu.open` | event | page menu built |
| `nav.back` / `nav.forward` | event | Back / Forward button |
| `share.open` | event | share sheet shown |
| `page.favorite` | event | Add to / Remove from Favorites |
| `settings.open` / `history.show` / `favorites.editorOpen` | event | sheet presented |
| `readingList.save` | interval | Read Later → page (and its reader copy) saved; message "copy" or "link" |
| `readingList.remove` / `readingList.show` / `readingList.open` / `readingList.edit` | event | Remove from Reading List, sheet presented, row opened, row marked or deleted |
| `readingList.load` | interval | Reading List rows read (open or search) |
| `readingList.offlineCopy` | interval | saved page failed to load → its copy handed to the reader |
| `reader.extract` | interval | reader request → article returned (or not readerable) |
| `reader.show` | interval | show article → rendered page handed to the reader web view |
| `tab.attach` | interval | `WebViewPool.attach` (tab switch) |
| `tab.restore` | interval | discarded tab's restore start → its page commits |
| `tab.discard` | interval | discard start (state read) → web view released |
| `tab.snapshot` | interval | thumbnail `takeSnapshot` → image returned |
| `tab.crash` | event | a tab's WebContent process terminated |
| `tab.open` / `tab.close` / `tab.select` | interval | shell, around the `TabStore` call → page on screen |
| `system.command` | event | a shortcut, Siri, widget, control or Spotlight result asked for a command (named in the message) |
| `tab.archive` | interval | shell, around `archiveIdleTabs` (launch, foreground) |
| `tab.unarchive` / `tab.reopen` / `tab.closeAll` | event | archive restore / Reopen Closed Tab / Close All Tabs |
| `tab.sessionLoad` / `tab.save` | interval | Storage: launch read / one batched write, off main |

| `linkMenu.build` | interval | WebKit asks for a link menu → menu built (includes the pressed-image lookup) |
| `linkMenu.action` / `linkMenu.preview` | event / interval | a link menu item chosen / a preview web view made |
| `page.zoom` / `page.save` | event | zoom changed (message: percent) / Save PDF to Files |
| `downloads.show` / `download.preview` / `download.showInFiles` | event | Downloads sheet, Quick Look, Show in Files |
| `page.reader` | event | Show Reader / Hide Reader |
| `contentBlocking.prepare` / `.compile` / `.siteToggle` | interval | lists loaded / one list compiled / per-site toggle applied |
| `launch.restoreTab` | interval | after the first frame: the saved tab list read and the selected tab handed to the page |
| `tab.swipe` / `tab.swipeEnd` | interval / event | bar swipe: finger starts moving → page settled / where it landed ("switched", "stayed", "newTab", "cancelled") |
| `tab.swipeSettle` / `tab.swipeHandoff` | interval | bar swipe: finger lifts → page visibly at rest and handed over / the neighbour's web view taking the page |
| `gallery.open` | event | gallery opened ("button", "swipe", "menu"); the zoom is `gallery.show` |
| `gallery.show` / `gallery.openTab` | interval | page zooms into its card / card grows into its page, until settled |
| `gallery.cardClose` / `gallery.scroll` / `gallery.reload` | interval | a card closed until reflowed / one scroll / a list applied |
| `archive.show` / `tab.privateMode` / `toast.show` | event | Archive screen / private toggle in the gallery / a toast |
| `archive.load` | interval | Archive screen: read the archive (or a search) and group it into sections |
| `split.open` / `split.close` | interval | Open in Other Pane (page, link, gallery, sidebar) / Close Pane, until the panes show |
| `split.swap` / `pane.focus` | event | Swap Panes / the focused pane changed (message: pane) |
| `fold.transition` | interval | `viewWillTransition(to:with:)` (fold, unfold, rotation) → its completion, insets applied (message: target size) |
| `sidebar.state` | interval | sidebar springs to Hidden, Rail or Expanded → at rest (message: state) |

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
3. **Engine in step:** `EngineTabs` makes engine `Tab`s on first use (a saved tab through
   `makeSavedTab`, which reads its state file when it first attaches) and follows each one's
   address, title and thumbnail (`TabWatch`, once per run loop turn) into `updatePage` and
   `setThumbnail`. Closing or archiving a tab drops its engine tab with
   `pool.close(_:keepingSavedState: true)`: its state file and thumbnail stay for Reopen Closed
   Tab and the archive, and Storage deletes them once no row names the tab. `isTabInUse` is the
   engine tab's `isBusy` (media, PiP, fullscreen, capture, download).
4. **Persistence:** every change hands `TabPersistence.enqueue` an ordered `TabChange`. Storage's
   `TabSessionWriter` writes 500 ms after the first change, off main, touching only changed rows;
   `flush()` on background. Private tabs never reach it.
5. **Auto-archive:** at launch and on each foreground, `archiveIdleTabs(after: settings.archiveAfter)`
   moves tabs not on screen for the interval to the archive, never pinned, visible, private or in-use
   tabs. Archived rows keep their state file; `searchArchivedTabs` (FTS5, title + address) and
   `archivedTabs` read it on demand. With each pass and on background, `pruneArchive()` deletes
   archived tabs older than 30 days (`FixedChoices.archivedTabLifetime`) with their state files, in
   the writer's chain off main; History keeps their pages. The newest 1,000 is the cap beside it.
   The Archive screen reads the whole archive (search: the best 200) and groups it into Today,
   Yesterday, This Week and Earlier off main (`ArchiveModel.group`).

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
The pool also owns `systemAccess` (`SystemAccessMonitor`: what iOS lets Plain use, read after the
first frame and on each return) and, only while camera, microphone or location is off for Plain,
the page-world `AccessRequestWatch`, which reports a page's request WebKit refused without asking
(`SystemAccessPresenter`, in `BrowserViewController+SystemAccess.swift`; the rules are
BrowserCore's `SystemAccess.swift`).

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

## Duo layouts (M3)

- **Layout.** Before every layout pass `updateDuoLayout()` builds a `DuoLayoutInput` from the root
  view (page area inside the safe area, size classes, `reservedRegions` for the fold and the
  camera) and applies the `DuoLayout` it returns: the sidebar's docked width, which pane slots
  the arrangement shows and how wide, and the lane the pill, search field and toast ride in.
  `docs/decisions.md` ("M3 Duo layouts") has the rules and why.
- **Panes.** `TabStore` owns which tab each pane shows and the focused pane (per window).
  `webContainer`/`pageClip` are the focused slot's, so the existing chrome, bar swipe, gallery
  zoom and reader act on the focused pane. `show(_:)` lets the store pick the pane first and keeps
  a tab attached while the other pane shows it; `syncPanes()` attaches or detaches the other
  pane's tab when it comes on screen or leaves (fold, split, close). Open in Other Pane comes from
  the page menu (with Swap Panes and Close Pane), the link menu, the gallery and the sidebar.
- **Folds.** `viewWillTransition(to:with:)` lays out once for the final size inside the
  transition's animation and applies page insets in its completion (`fold.transition`).
- **Tab Layout.** `DuoLayout.tabLayout` is the layout in effect: Left or Right shows
  `SideTabsViewController` on that side (where the page keeps 640 pt beside the rail), Above shows
  `TabStripViewController` across the top of the page area (also the fallback for Left and Right
  in inner portrait). Both are siblings of the panes, never inside the arrangement, read `SideTabs`
  (over `EngineTabs`), and reload with the gallery on every tab change. The shell owns the
  sidebar's width: drags track it, releases spring it.
- **Windows.** Each window is a scene with its own `BrowserSession` (web view pool, reader).
  What all windows share is made once by the app (`AppServices` in the app target): the database,
  `LiveAddressBarData`, `FeatureSheets` and `AppStores` (`AppTabs`, the one `TabStore` for every
  window; the per-site stores; the content blocker). The scene passes its saved window id;
  `AppTabs.claim` decides the window it shows, and `EngineTabs` reads and changes only that
  window. The id, the sidebar state and the side pane live in `UISceneSession.userInfo`
  (`SceneState`). `Windows` asks for a new window (`activateSceneSession`) and lists the others.
- **Side pane.** `DuoLayout.sidePaneColumn` places it (trailing 30%, a split's second pane, or the
  far side of an active fold); `+SidePane` docks it, slides it and runs its edge swipe;
  `SidePaneController` holds Reader (`ReaderPresenter`), Find (`PageFind` in WebEngine) and
  History (FeatureUI's `HistoryView`).

## Tab gallery, bar swipe and private tabs (M2)

- **Gallery:** the tabs button (or a swipe up from the expanded bar) adds `TabGalleryViewController`
  as a child over the page, under the chrome and the search sheet. `TabGalleryTransition` zooms a
  snapshot of the page into the selected card; the chrome slides down a little and fades as the
  gallery's own bar arrives. A swipe drives the same transition with `update(progress:)` and
  `finish(at:)`. Opening a card attaches its web view under the gallery at once and grows the
  card's thumbnail into the page, then the gallery leaves and the live page shows. New Tab goes
  straight to the search field; the last tab closed does too (or back to the regular list when
  only private tabs closed). `GalleryTabs` is the data source: lists, thumbnails from the pool's
  `ThumbnailService`, actions handed to the browser (`GalleryHost`).
- **Bar swipe (`TabSwipe`):** a pan on the expanded pill and the glass bar (never the collapsed
  pill). Sideways, the page container moves 1:1; the neighbour is its own web view re-parented
  into a preview container when it has one, else a 2x full-screen snapshot taken when it left
  the screen (kept for the two neighbours only, `TabsUIState.previews`), else its thumbnail. The
  glass stays still; the pill's host label slides inside it. Release springs frame by frame
  (`SpringDriver`, `Motion.tabSwitchSpring`) with the finger's velocity; it commits when the
  projected travel passes half the width. A finger grabs a settling page. Past the last tab a New
  Tab card rubber-bands in (80 pt to open). The tabs menu has Next Tab / Previous Tab, naming the
  gesture.
- **Private tabs:** `TabStore` keeps them in the window's private list and never persists them.
  The pool gives them one shared `WKWebsiteDataStore.nonPersistent()` (dropped when the last one
  closes, `endPrivateSession()`), never the warm web view, in-memory per-site choices, no state
  files and memory-only thumbnails. The chrome takes `Palette.privateGlassTint`; history and the
  address bar's remote suggestions stay off.
- **Archive:** `archiveIdleTabs(after:)` runs once the saved tabs and the settings are in, and on
  each return to the foreground; hidden tabs are asked about media first (`refreshMediaState`).
  The Archive screen (FeatureUI) reads `searchArchivedTabs`; restore and delete go through
  `TabStore`.

