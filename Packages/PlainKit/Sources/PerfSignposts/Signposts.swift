import os

/// The signposts every user-visible interaction emits (AGENTS.md rule 5). The app emits them and
/// the UI tests measure them by these exact names, so both sides read them from here.
///
/// See them live: Instruments > os_signpost, subsystem `dev.abrahamgonzalez.plainbrowser`.
public enum Signposts {
    public static let subsystem = "dev.abrahamgonzalez.plainbrowser"
    public static let category = "perf"

    public static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// Interval from `main` entering to the first screen ready: the search field first responder,
    /// or the last tab's picture and resting bar in place (message: the opening screen).
    public static let launch: StaticString = "launch"
    /// Interval from `main` entering to the first display-link callback after the first window
    /// became visible: the run loop turn that showed the window is done and the main thread runs
    /// the next frame's work. The perf gate's cold launch (`launchMs`): Apple's
    /// XCTApplicationLaunchMetric records nothing for Plain on the device and only some runs on a
    /// simulator. Time before `main` (dyld, static initializers) is not in it.
    public static let launchFirstFrame: StaticString = "launch.firstFrame"
    /// Event: the search field became first responder at launch.
    public static let searchFieldReady: StaticString = "launch.searchFieldReady"
    /// Interval: the pool creating the warm web view after the first frame.
    public static let webViewWarmUp: StaticString = "webView.warmUp"
    /// Interval: generating one paper texture tile (DesignSystem `PaperTexture`), off the main
    /// thread, once per appearance.
    public static let paperTile: StaticString = "paper.tile"
    /// Interval: making the paper's pattern color from a generated tile, on the main thread, once
    /// per appearance and display scale.
    public static let paperPattern: StaticString = "paper.pattern"
    /// Interval: the user submitting the address bar, until the load is handed to the web view
    /// (parsing the input, getting a web view, starting the load).
    public static let addressSubmit: StaticString = "address.submit"
    /// Interval from a navigation starting to its first content committing.
    public static let navCommit: StaticString = "nav.commit"
    /// Interval from a navigation starting to it finishing (or failing).
    public static let navFinish: StaticString = "nav.finish"
    /// Interval: the History screen asking for visits (opening or typing a search), until the
    /// grouped rows are ready to show.
    public static let historyLoad: StaticString = "history.load"
    /// Interval: a History "Clear" choice, until the visits are gone and the list reloaded.
    public static let historyClear: StaticString = "history.clear"
    /// Interval: Settings > Clear History and Data confirmed, until the data is cleared.
    public static let clearBrowsingData: StaticString = "settings.clearData"
    /// Event: the user changed a setting (search engine, tab layout, archive interval or appearance).
    public static let settingsChange: StaticString = "settings.change"
    /// Event: a window crossfades to new colors (Settings > Appearance).
    public static let appearanceChange: StaticString = "settings.appearance"
    /// Event: the user opened a page from History.
    public static let historyOpen: StaticString = "history.open"
    /// Interval: deleting a page from History, until it is gone from the store.
    public static let historyDelete: StaticString = "history.delete"
    /// Event: the user reordered, renamed or deleted favorites.
    public static let favoritesEdit: StaticString = "favorites.edit"

    /// Event: a haptic played (message: its kind). On the same timeline as the motion intervals
    /// (`tabSwipe`, `galleryCardClose`, …), which is how its sync with the picture is checked
    /// (docs/research/haptics.md §5).
    public static let haptic: StaticString = "haptic"

    // MARK: Shell (address bar, toolbar, page)

    /// Interval from a tap on the URL pill to the field being first responder with the search
    /// sheet's layout applied (the first visual response).
    public static let urlBarFocus: StaticString = "urlBar.focus"
    /// Interval: building the focused field's content (copied link, the page, recent and closed
    /// pages) from what is already in memory, before the frame that shows the field. Main thread;
    /// no disk.
    public static let focusContent: StaticString = "urlBar.focusContent"
    /// Interval: reading the favorites and recent pages for the focused field, off the main
    /// thread, ahead of the next focus.
    public static let focusContentLoad: StaticString = "urlBar.focusContentLoad"
    /// Event: a row the focused field offered before typing was used ("copy", "edit", "copied",
    /// "recent", "closed").
    public static let focusAction: StaticString = "urlBar.focusAction"
    /// Event: the page sheet opened (More, or a long press on the pill).
    public static let pageSheet: StaticString = "pageSheet.open"
    /// Event: editing the page's address began (the page sheet's address, or the page's row).
    public static let editAddress: StaticString = "urlBar.editAddress"
    /// Interval from a tap on the URL pill to the keyboard at rest under the focused field
    /// (`keyboardDidShow`; `OpenIntervals`). The perf gate's `focusMs`: the system keyboard's own
    /// rise is inside it, so the app's part is what delays the rise's start.
    public static let urlBarReady: StaticString = "urlBar.ready"
    /// Interval: the search sheet growing from the pill ("open") or shrinking back into it
    /// ("close"), from the first frame of the motion to its rest. Ends "retargeted" when the other
    /// direction took over mid-flight.
    public static let searchSheetMorph: StaticString = "urlBar.sheetMorph"
    /// Event: how the open search sheet was closed without going anywhere ("outside": a tap on
    /// the dimmed page; "grabber"; "cancel"; "swipe"; "escape").
    public static let searchSheetDismiss: StaticString = "urlBar.sheetDismiss"
    /// Interval: a finger dragging the search sheet down, from the drag's start to its release
    /// ("collapsed" or "kept").
    public static let searchSheetDrag: StaticString = "urlBar.sheetDrag"
    /// Event: an option in the empty field was used ("mic", "micStop", "browseArm", "browseDisarm").
    public static let fieldOption: StaticString = "urlBar.fieldOption"
    /// The part of `urlBar.ready` before the keyboard starts rising: a tap on the URL pill to
    /// `keyboardWillShow` (the shell's work, the commit of that frame and the keyboard's setup).
    /// The rest of `urlBar.ready` is the system keyboard's own rise. Reported beside `focusMs`.
    public static let urlBarKeyboardStart: StaticString = "urlBar.keyboardStart"
    /// The reference screen's tap to keyboard at rest (`-PlainPerfReference`, test runs only): a
    /// bare UIKit screen with one text field and a button, so `urlBar.ready` and `tab.newReady` can
    /// be read against what UIKit alone takes on the same device (docs/research/perf-pass-3.md).
    public static let referenceReady: StaticString = "reference.ready"
    /// The reference screen's tap to `keyboardWillShow`, as `urlBar.keyboardStart`.
    public static let referenceKeyboardStart: StaticString = "reference.keyboardStart"
    /// The reference field's keystroke: `.editingChanged`, a hop off the main thread and back, as
    /// `search.suggestions` without the database read or the rows.
    public static let referenceKeystroke: StaticString = "reference.keystroke"
    /// Interval from a keystroke in the address bar to its local suggestions (history and
    /// favorites) being on screen. Engine suggestions arrive later and are not part of it.
    public static let suggestionsShown: StaticString = "search.suggestions"
    /// Interval: the search sheet putting one suggestion list on screen (matching rows to
    /// suggestions, laying them out, starting their animation). Main-thread work per update; a
    /// keystroke makes one or more updates (local pages, then the engine's suggestions).
    public static let suggestionsApply: StaticString = "search.suggestionsApply"
    /// Interval from the toolbar starting to collapse or expand to it settling.
    public static let toolbarCollapse: StaticString = "toolbar.collapse"
    /// Interval: one toolbar snap, from the finger lifting (or a tap or load expanding the bar) to
    /// the bar at rest. Ends "settled", or "grabbed" when a new drag takes over mid-snap.
    public static let toolbarSnap: StaticString = "toolbar.snap"
    /// Event: the page's bottom inset followed the bar's resting state (expanded or collapsed).
    public static let pageInset: StaticString = "toolbar.pageInset"
    /// Event: the bar hides while reading (the pill sinks away). Message: what hid it.
    public static let toolbarHide: StaticString = "toolbar.hide"
    /// Event: a hidden or collapsed bar comes back whole. Message: what brought it back (scroll
    /// up, edge tap, status bar, page end, navigation...).
    public static let toolbarReveal: StaticString = "toolbar.reveal"
    /// Interval: the shell's work in one page scroll callback (the toolbar's tracking, pull to
    /// refresh). Emitted only while a signpost recorder listens; the main-thread cost per scroll
    /// frame.
    public static let scrollStep: StaticString = "toolbar.scrollStep"
    /// Event: pull to refresh crossed its threshold and is armed.
    public static let pullToRefreshArm: StaticString = "ptr.arm"
    /// Event: pull to refresh was released armed and the page reloads.
    public static let pullToRefresh: StaticString = "ptr.refresh"
    /// Event: the page menu opened.
    public static let pageMenu: StaticString = "pageMenu.open"
    /// Event: Back or Forward from a button (the swipe gestures show up as navigations).
    public static let navBack: StaticString = "nav.back"
    public static let navForward: StaticString = "nav.forward"
    /// Event: the share sheet opened.
    public static let share: StaticString = "share.open"
    /// Events: page menu actions.
    public static let reload: StaticString = "page.reload"
    public static let findOnPage: StaticString = "page.find"
    public static let copyLink: StaticString = "page.copyLink"
    public static let desktopSite: StaticString = "page.desktopSite"
    /// Event: a site's Dark Pages choice changed ("on", "off", "automatic"), from the indicator in
    /// the pill or Site Settings.
    public static let darkPagesToggle: StaticString = "page.darkPages"
    /// Event: the Dark Pages switch changed ("on", "off") from outside Settings (the suggestion).
    public static let darkPagesSwitch: StaticString = "page.darkPagesSwitch"
    /// Interval: a page's crossfade between its light and dark rendering, from the snapshot to
    /// the end of the fade.
    public static let darkPagesCrossfade: StaticString = "page.darkPagesCrossfade"
    /// Event: the Dark Pages suggestion "shown", then how it went ("turnOn", "noThanks",
    /// "timedOut", "hidden").
    public static let darkPagesSuggestion: StaticString = "page.darkPagesSuggestion"
    /// Event: the user turned cookie banner handling off ("off") or back on ("on") for a site.
    public static let cookieBannersToggle: StaticString = "page.cookieBanners"
    /// Event: the cookie banner engine answered a banner ("rejected") or gave up ("failed").
    public static let cookieBannerAnswered: StaticString = "cookieBanners.answered"
    /// Event: the cookie banner engine went into a page, and why ("site rule", "host", "page").
    public static let cookieBannerEngine: StaticString = "cookieBanners.engine"
    /// Interval: reading the cookie banner engine and rules off the main thread after launch.
    public static let cookieBannersPrepare: StaticString = "cookieBanners.prepare"
    /// Interval: Translate Page, from the menu tap until the first translated text is on screen
    /// ("translated"), or until it failed or was cancelled.
    public static let translatePage: StaticString = "page.translate"
    /// Event: Show Original put the page back as the site wrote it.
    public static let showOriginal: StaticString = "page.showOriginal"
    /// Event: a page's language was detected (the name says whether it differs from the user's).
    public static let pageLanguage: StaticString = "page.language"
    /// Event: the page menu's Print opened the print sheet.
    public static let printPage: StaticString = "page.print"
    /// Interval: Save as PDF, from the menu tap until the share sheet has the file.
    public static let exportPDF: StaticString = "page.exportPDF"
    /// Event: Add to Favorites or Remove from Favorites in the page menu.
    public static let favoriteToggle: StaticString = "page.favorite"

    // MARK: Sheets the shell presents

    /// Event: Settings opened from the page menu.
    public static let settingsOpen: StaticString = "settings.open"
    /// Event: History opened from the page menu.
    public static let historyShow: StaticString = "history.show"
    /// Event: the favorites strip's long-press menu opened.
    public static let favoritesMenu: StaticString = "favorites.menu"
    /// Event: the favorites editor opened from the favorites strip.
    public static let favoritesEditorOpen: StaticString = "favorites.editorOpen"

    // MARK: Reading list

    /// Interval: Read Later in the page menu, from the tap until the page (and its reader copy,
    /// when it has an article) is saved. Message: "copy" or "link".
    public static let readingListSave: StaticString = "readingList.save"
    /// Event: Remove from Reading List in the page menu.
    public static let readingListRemove: StaticString = "readingList.remove"
    /// Event: the Reading List sheet opened from the page menu.
    public static let readingListShow: StaticString = "readingList.show"
    /// Interval: the Reading List screen reading its rows (opening or a search), until they show.
    public static let readingListLoad: StaticString = "readingList.load"
    /// Event: the user opened a saved page from the Reading List.
    public static let readingListOpen: StaticString = "readingList.open"
    /// Event: a swipe or menu marked a saved page read or unread, or deleted it.
    public static let readingListEdit: StaticString = "readingList.edit"
    /// Interval: a saved page failed to load (offline, site gone), until its saved copy is handed
    /// to the reader.
    public static let readingListOfflineCopy: StaticString = "readingList.offlineCopy"

    // MARK: Reader

    /// Interval: a reader request, from asking for the page's article until it is returned (or
    /// found not readerable). Near zero for a repeat open of the same page.
    public static let readerExtract: StaticString = "reader.extract"
    /// Interval: showing an article in the reader view, from the request until the rendered page
    /// is handed to the reader web view.
    public static let readerShow: StaticString = "reader.show"
    /// Event: the button on a page that can't show (crashed, failed, form waiting): Reload or Try
    /// Again. The message says which.
    public static let pageStateAction: StaticString = "page.stateAction"
    /// Event: Show Reader or Hide Reader from the page menu (or Back closing the reader).
    public static let readerToggle: StaticString = "page.reader"

    // MARK: On-device AI (Browse for Me, Summarize Page)

    /// Interval: a summary from the tap (Browse for Me or Summarize Page) until it is written,
    /// failed or closed. The message says which ("done", "failed", "cancelled").
    public static let summary: StaticString = "summary"
    /// Interval: loading one results page in its hidden view and reading its links (message: the
    /// engine and how many results).
    public static let summaryResults: StaticString = "summary.results"
    /// Interval: one source, from its hidden view's load to its text read and the view torn
    /// down (message: "read" or why it was skipped).
    public static let summarySource: StaticString = "summary.source"
    /// Interval: fitting the sources to the model's context (counting tokens off the main thread).
    public static let summaryFit: StaticString = "summary.fit"
    /// Interval: from the tap until the first words of the summary are on screen. The latency
    /// the perf test measures for summary start.
    public static let summaryFirstWords: StaticString = "summary.firstWords"
    /// Interval: the model writing, from the prompt sent until the last words.
    public static let summaryWrite: StaticString = "summary.write"
    /// Event: the summary screen opened for Browse for Me or Summarize Page.
    public static let summaryShow: StaticString = "summary.show"
    /// Event: Back from a source's first page brought its summary back.
    public static let summaryShowAgain: StaticString = "summary.showAgain"
    /// Event: a source opened from a summary (message: "new tab" or "background").
    public static let summaryOpenSource: StaticString = "summary.openSource"

    // MARK: Content blocking

    /// Interval: loading the allow-list and every bundled rule list (lookups, compiles on a miss).
    public static let contentBlockingPrepare: StaticString = "contentBlocking.prepare"
    /// Interval: compiling one rule list (first launch, or an update that changed it).
    public static let contentBlockingCompile: StaticString = "contentBlocking.compile"
    /// Interval: Turn Off / Turn On Blocking on This Site, until every web view's lists follow.
    public static let contentBlockingSiteToggle: StaticString = "contentBlocking.siteToggle"

    // MARK: Session restore

    /// Interval: after the first frame, reading the last session's tab and handing it to the
    /// page (its page then restores under `tab.restore`).
    public static let launchRestoreTab: StaticString = "launch.restoreTab"
    /// Interval: decoding the last tab's launch picture off the main thread, from the scene
    /// connecting (message: "decoded" or "none").
    public static let launchPictureDecode: StaticString = "launch.pictureDecode"
    /// Interval: the first frame waiting for that decode to finish (message: "ready" or
    /// "timedOut"); absent when it was already done.
    public static let launchPictureWait: StaticString = "launch.pictureWait"
    /// Interval: encoding and writing the launch picture off the main thread.
    public static let launchPictureSave: StaticString = "launch.pictureSave"
    /// Interval: the last tab's restored page shown under its picture, until the picture has
    /// faded and the live page is uncovered (message: "loaded", "timedOut" or "dropped").
    public static let launchPictureHandoff: StaticString = "launch.pictureHandoff"
    /// Event: a fresh search opened over the last tab (message: "launch" or "return").
    public static let freshSearch: StaticString = "launch.freshSearch"
    /// Interval, twice a launch: the launch splash's work on the main thread before the first
    /// frame ("prepare": the icon read and starting the off-main work as the scene connects;
    /// "show": its window and layers). Inside `launch.firstFrame`.
    public static let launchSplashBuild: StaticString = "launch.splashBuild"
    /// Interval: the launch splash on screen, from the app's first frame to the splash gone
    /// (message: how it ended: "metal", "iris", "crossfade", "skipped", "left", or "missed" when its pictures were not drawn in time and no splash showed).
    public static let launchSplash: StaticString = "launch.splash"
    /// Interval: the dive itself, from its first movement to the app filling the screen.
    public static let launchSplashDive: StaticString = "launch.splashDive"
    /// Event: the dive's frame timing (message: frames, intervals, late frames, CPU and GPU time).
    public static let launchSplashFrames: StaticString = "launch.splashFrames"

    // MARK: Tabs (TabStore). The shell emits these around its `TabStore` calls.

    /// Interval: a new tab, from the open request (new-tab button, link, popup) to its pane
    /// showing it (or, in the background, to it being in the list).
    public static let tabOpen: StaticString = "tab.open"
    /// Interval from New Tab (a menu, the gallery, a swipe past the last tab) to the keyboard at
    /// rest under the new tab's focused search field (`keyboardDidShow`; `OpenIntervals`). The perf
    /// gate's `newTabMs`.
    public static let newTabReady: StaticString = "tab.newReady"
    /// Event: the bar's New Tab button, tapped ("tap") or its long-press menu's other kind ("menu").
    public static let barNewTab: StaticString = "bar.newTab"
    /// The part of `tab.newReady` before the keyboard starts rising (`keyboardWillShow`), as
    /// `urlBar.keyboardStart` for the pill. Reported beside `newTabMs`.
    public static let newTabKeyboardStart: StaticString = "tab.newKeyboardStart"
    /// Interval: closing a tab (button, flick in the gallery, `window.close()`), until the next
    /// tab is on screen.
    public static let tabClose: StaticString = "tab.close"
    /// Interval: choosing a tab (gallery, bar swipe, sidebar), until its page is on screen.
    public static let tabSelect: StaticString = "tab.select"
    /// Interval: the auto-archive check at launch or on returning to the foreground, until the
    /// due tabs are out of the store. The message holds how many moved.
    public static let tabArchive: StaticString = "tab.archive"
    /// Event: an archived tab restored from the archive screen or its search.
    public static let tabUnarchive: StaticString = "tab.unarchive"
    /// Event: Reopen Closed Tab.
    public static let tabReopen: StaticString = "tab.reopen"
    /// Event: Close All Tabs.
    public static let tabCloseAll: StaticString = "tab.closeAll"
    /// Interval: the tab session read at launch, off the main thread (Storage emits it).
    public static let tabSessionLoad: StaticString = "tab.sessionLoad"
    /// Interval: one batched tab write, off the main thread (Storage emits it).
    public static let tabSave: StaticString = "tab.save"
    /// Interval: a swipe along the expanded address bar, from the finger starting to move until the
    /// page settles. Exclusive and without an end message, so XCTOSSignpostMetric measures it.
    public static let tabSwipe: StaticString = "tab.swipe"
    /// Interval: a bar swipe from the finger lifting until the page settles (visibly at rest,
    /// `visualSettle`) and the new tab has taken over. The part Plain owns: it leaves out the
    /// finger's own travel, which in UI tests is the test's scripted drag.
    public static let tabSwipeSettle: StaticString = "tab.swipeSettle"
    /// Interval inside `tab.swipeSettle`: the page at rest on the neighbour, its web view moving
    /// into the page container (`completeTabSwipe`). A live neighbour takes touches when it ends; a
    /// restored one keeps its picture over the page until it has loaded (up to 1.5 s).
    public static let tabSwipeHandoff: StaticString = "tab.swipeHandoff"
    /// Event right after `tab.swipe` ends: where it landed, "switched" (the neighbour tab),
    /// "stayed", "newTab" (past the last tab) or "cancelled".
    public static let tabSwipeEnd: StaticString = "tab.swipeEnd"
    /// Event: the tab gallery opened from the tabs button ("button") or a swipe up from the address
    /// bar ("swipe"); the page then zooms into its card under `gallery.show`.
    public static let galleryOpen: StaticString = "gallery.open"
    /// Event: the archive screen opened from the gallery.
    public static let archiveShow: StaticString = "archive.show"
    /// Interval: the Archive screen reads its tabs and puts them in their sections (open, search).
    public static let archiveLoad: StaticString = "archive.load"
    /// Event: private browsing turned on or off in the gallery.
    public static let privateMode: StaticString = "tab.privateMode"
    /// Event: the gallery switched to another profile's tabs from its profile switcher.
    public static let profileShow: StaticString = "profile.show"
    /// Event: a profile was made, from the gallery's More menu or the switcher.
    public static let profileCreate: StaticString = "profile.create"
    /// Event: a profile was renamed.
    public static let profileRename: StaticString = "profile.rename"
    /// Event: a profile and everything in it were deleted.
    public static let profileDelete: StaticString = "profile.delete"
    /// Interval: a profile's history database opening, off the main thread, the first time the
    /// window shows one of its tabs in a launch.
    public static let profileDataOpen: StaticString = "profile.dataOpen"
    /// Event: a short toast over the chrome (Reopen Tab after a close, a finished download).
    public static let toast: StaticString = "toast.show"
    /// Event: a line saying a feature is off for Plain (a site's camera, microphone or location
    /// request, Save Image, cellular data). The message says which.
    public static let systemAccessNotice: StaticString = "systemAccess.notice"
    /// Event: Settings from such a line, or a Site Settings row that is off in Settings: Plain's page
    /// in the Settings app opens.
    public static let openSettings: StaticString = "systemAccess.openSettings"
    /// Event: Site Settings changed a site's camera, microphone, location or motion answer.
    public static let sitePermissionChange: StaticString = "site.permission"

    // MARK: Tab gallery (TabGalleryUI emits these)

    /// Interval: opening the gallery, from the tabs button or the swipe up (the shell getting the
    /// gallery ready and the page's snapshot, since 2026-11-27) until the page visibly rests on
    /// its card (`visualSettle`; Core Animation finishes the spring's tail a few hundred ms later).
    public static let galleryShow: StaticString = "gallery.show"
    /// Where `gallery.show` counts the page as at rest, in points: within this distance of its card
    /// on every edge, and moving less than this in a frame (so a page still crossing the card's
    /// frame at speed doesn't count). Half a point is below what the eye can see move.
    public static let visualSettle: Double = 0.5
    /// Interval: a card zooming into its page, until the page visibly rests there (`visualSettle`,
    /// the same rule as `gallery.show`, since 2026-11-27); the live page takes over then.
    public static let galleryOpenTab: StaticString = "gallery.openTab"
    /// Interval: a card flicked away (or closed from its button or menu), until the cards reflow.
    public static let galleryCardClose: StaticString = "gallery.cardClose"
    /// Interval: one scroll of the gallery, from the finger down until it stops moving.
    public static let galleryScroll: StaticString = "gallery.scroll"
    /// Interval: applying a new tab list to the gallery (diff and layout).
    public static let galleryReload: StaticString = "gallery.reload"
    /// Events: gallery actions with no motion of their own.
    public static let galleryNewTab: StaticString = "gallery.newTab"
    public static let galleryReopen: StaticString = "gallery.reopen"
    public static let galleryCloseAll: StaticString = "gallery.closeAll"
    public static let galleryReorder: StaticString = "gallery.reorder"
    public static let galleryMenu: StaticString = "gallery.menu"
    public static let galleryCopyLink: StaticString = "gallery.copyLink"
    public static let galleryShare: StaticString = "gallery.share"
    public static let galleryOtherPane: StaticString = "gallery.otherPane"
    /// Event: a swipe on a gallery card that let go before closing it.
    public static let galleryCardKept: StaticString = "gallery.cardKept"
    /// Event: tap or swipe up on the gallery's empty space, back to the tab on screen.
    public static let galleryBack: StaticString = "gallery.back"
    /// Event: a finger spun the mark on the start screen.
    public static let startMarkSpin: StaticString = "start.markSpin"

    /// Interval: putting a tab's page on screen (tab switch). Restoring a discarded tab starts here
    /// too; its page coming back is `tab.restore`.
    public static let tabAttach: StaticString = "tab.attach"
    /// Interval from a discarded tab's restore starting to its page committing.
    public static let tabRestore: StaticString = "tab.restore"
    /// Interval from a tab's discard starting (reading its state) to its web view being released.
    public static let tabDiscard: StaticString = "tab.discard"
    /// Interval of a tab thumbnail snapshot, until WebKit returns the image.
    public static let tabSnapshot: StaticString = "tab.snapshot"
    /// Interval: fetching a site's icon, from the page's answer to the icon stored (or none
    /// found). Off the main thread but for the page's answer. The message is "stored" or "none".
    public static let faviconFetch: StaticString = "favicon.fetch"
    /// Interval: decoding a stored icon at a view's size, off the main thread.
    public static let faviconDecode: StaticString = "favicon.decode"
    /// Interval from the engine asking the shell (dialog, sign-in, certificate warning, permission,
    /// external app, universal link) to the answer. The kind is the interval's message.
    public static let enginePrompt: StaticString = "engine.prompt"
    /// Event: a download started or ended; the message says which and how.
    public static let download: StaticString = "download"
    /// Interval: a long press on a link or image, from WebKit asking for the menu until the menu
    /// is built (it includes one round trip to the page to find a pressed image).
    public static let linkMenu: StaticString = "linkMenu.build"
    /// Event: a link menu action; the message names it.
    public static let linkMenuAction: StaticString = "linkMenu.action"
    /// Interval: a link preview's web view being made and its load started.
    public static let linkPreview: StaticString = "linkMenu.preview"
    /// Event: page zoom changed from the page menu; the message is the new percentage.
    public static let pageZoom: StaticString = "page.zoom"
    /// Event: the page's file (a PDF) was handed to Downloads.
    public static let savePage: StaticString = "page.save"
    /// Event: the Downloads list opened.
    public static let downloadsShow: StaticString = "downloads.show"
    /// Event: Show in Files from the Downloads list.
    public static let downloadShowInFiles: StaticString = "download.showInFiles"
    /// Event: a finished download opened in Quick Look.
    public static let downloadPreview: StaticString = "download.preview"
    /// Event: a tab's web content process terminated.
    public static let tabCrash: StaticString = "tab.crash"
    /// Event: a page's passkey request failed because Plain can't use passkeys yet (no
    /// web-browser entitlement); the message says whether the shell was told.
    public static let passkeyUnavailable: StaticString = "signIn.passkeyUnavailable"
    /// Event: another app opened a web link in Plain (as the default browser); its tab's open is
    /// the `tab.open` interval that follows.
    public static let linkFromOtherApp: StaticString = "link.fromOtherApp"
    /// Event: Shortcuts, Siri, a widget, a control or a Spotlight result asked for a command
    /// (search, a tab, the tab switcher); the message names it. Its tab or gallery interval follows.
    public static let systemCommand: StaticString = "system.command"

    // MARK: First-run intro (FeatureUI emits these)

    /// Animation interval: the Stem mark assembling on the splash (ring draws, dawn rises, fold
    /// folds), until it lands or a tap skips it. Instruments shows its frame rate and hitches.
    public static let introSplash: StaticString = "intro.splash"
    /// Animation interval: one step of the intro handing over to the next (blur dissolve, staggered
    /// entrance). The message names the step it goes to.
    public static let introStep: StaticString = "intro.step"
    /// Animation interval: the blocking demo's page going clean or cluttered (the toggle).
    public static let introBlockingDemo: StaticString = "intro.blockingDemo"
    /// Animation interval: the Browse for Me demo playing (a question, its sources, the cited
    /// points), by itself on arrival or again from a tap on its row.
    public static let introBrowseDemo: StaticString = "intro.browseDemo"
    /// Animation interval: the default-browser step's demo (a link opening in Plain), by itself
    /// on arrival or again from a tap on its message.
    public static let introLinkDemo: StaticString = "intro.linkDemo"
    /// Event: Turn On Apple Intelligence was tapped on the intro's Browse for Me step.
    public static let introAISettings: StaticString = "intro.aiSettings"
    /// Event: the intro's Browse for Me step re-read the model's availability; the message names
    /// the answer.
    public static let introAIAvailability: StaticString = "intro.aiAvailability"
    /// Animation interval: the intro dissolving into the search field, until it is gone.
    public static let introFinish: StaticString = "intro.finish"
    /// Event: the intro was skipped; the message names the step it was skipped from.
    public static let introSkip: StaticString = "intro.skip"
    /// Interval: an app icon change, from the pick until the system confirms it.
    public static let appIconChange: StaticString = "appIcon.change"
    /// Event: Set as Default Browser was tapped (intro step or the empty-tab card).
    public static let defaultBrowserPrompt: StaticString = "defaultBrowser.open"

    // MARK: Duo layouts (M3)

    /// Interval: a split opening (page menu, link menu, gallery, sidebar), until both panes show.
    public static let splitOpen: StaticString = "split.open"
    /// Interval: a pane closing, until the remaining page fills the window.
    public static let splitClose: StaticString = "split.close"
    /// Event: the panes traded places.
    public static let splitSwap: StaticString = "split.swap"
    /// Event: the focused pane changed (a touch on the other pane, or a tab chosen in it).
    public static let paneFocus: StaticString = "pane.focus"
    /// Interval: the side pane opening (More, the edge swipe, History, Find on Page), from the
    /// request until its spring settles. The message says what it shows.
    public static let sidePaneOpen: StaticString = "sidePane.open"
    /// Interval: the side pane closing, until the page has its width back.
    public static let sidePaneClose: StaticString = "sidePane.close"
    /// Event: the side pane switched what it shows (Reader, Find, History).
    public static let sidePaneSection: StaticString = "sidePane.section"
    /// Interval: Find in the side pane, from a query to its list of matches.
    public static let sidePaneFind: StaticString = "sidePane.find"
    /// Event: a new window was asked for (Open in New Window, New Window).
    public static let windowOpen: StaticString = "window.open"
    /// Event: another window was brought forward from the tabs menu.
    public static let windowSwitch: StaticString = "window.switch"
    /// Interval: a size change of the window (fold, unfold, rotation), from
    /// `viewWillTransition(to:with:)` to its completion, when the page insets apply. The message is
    /// the target size.
    public static let foldTransition: StaticString = "fold.transition"
    /// Interval: the sidebar moving between Hidden, Rail and Expanded, until it rests. The message
    /// is the state it rests in.
    public static let sidebarState: StaticString = "sidebar.state"
    /// The tab list (the strip or the sidebar) came in with the second tab, or left with the
    /// last but one ("shown" or "hidden").
    public static let tabListPresence: StaticString = "tabList.presence"

    /// Event: a hardware keyboard shortcut acted (message: which one, `KeyShortcut.identifier`).
    public static let keyShortcut: StaticString = "key.shortcut"
    /// Event: a long press on Back or Forward listed the tab's history (message: back or forward).
    public static let historyMenu: StaticString = "nav.historyMenu"
    /// Event: a page picked from that list (message: the offset, negative is back).
    public static let historyJump: StaticString = "nav.historyJump"
    /// Event: a pinch in on a page at its smallest zoom opened the tab overview (wide screens).
    public static let pinchToOverview: StaticString = "gallery.pinch"
    /// Event: the system's undo (shake, three-finger swipe, ⌘Z) reopened the last closed tab.
    public static let undoCloseTab: StaticString = "tab.undoClose"
    /// Interval: the refresh arrow spinning after a pull, until the page's load ends.
    public static let pullRefreshing: StaticString = "ptr.refreshing"

    /// `StaticString` names as `String`, for `XCTOSSignpostMetric(subsystem:category:name:)`.
    public static func name(_ name: StaticString) -> String {
        name.description
    }
}
