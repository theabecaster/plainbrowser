import os

/// The signposts every user-visible interaction emits (AGENTS.md rule 5). The app emits them and
/// the UI tests measure them by these exact names, so both sides read them from here.
///
/// See them live: Instruments > os_signpost, subsystem `dev.abrahamgonzalez.plainbrowser`.
public enum Signposts {
    public static let subsystem = "dev.abrahamgonzalez.plainbrowser"
    public static let category = "perf"

    public static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// Interval from `main` entering to the search field becoming first responder.
    public static let launch: StaticString = "launch"
    /// Event: the search field became first responder at launch.
    public static let searchFieldReady: StaticString = "launch.searchFieldReady"
    /// Interval: the pool creating the warm web view after the first frame.
    public static let webViewWarmUp: StaticString = "webView.warmUp"
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
    /// Event: the user changed a setting (search engine, tab layout or archive interval).
    public static let settingsChange: StaticString = "settings.change"
    /// Event: the user opened a page from History.
    public static let historyOpen: StaticString = "history.open"
    /// Interval: deleting a page from History, until it is gone from the store.
    public static let historyDelete: StaticString = "history.delete"
    /// Event: the user reordered, renamed or deleted favorites.
    public static let favoritesEdit: StaticString = "favorites.edit"

    // MARK: Shell (address bar, toolbar, page)

    /// Interval from a tap on the URL pill to the field being first responder with the search
    /// sheet's layout applied (the first visual response).
    public static let urlBarFocus: StaticString = "urlBar.focus"
    /// Interval from a keystroke in the address bar to its local suggestions (history and
    /// favorites) being on screen. Engine suggestions arrive later and are not part of it.
    public static let suggestionsShown: StaticString = "search.suggestions"
    /// Interval from the toolbar starting to collapse or expand to it settling.
    public static let toolbarCollapse: StaticString = "toolbar.collapse"
    /// Interval: one toolbar snap, from the finger lifting (or a tap or load expanding the bar) to
    /// the bar at rest. Ends "settled", or "grabbed" when a new drag takes over mid-snap.
    public static let toolbarSnap: StaticString = "toolbar.snap"
    /// Event: the page's bottom inset followed the bar's resting state (expanded or collapsed).
    public static let pageInset: StaticString = "toolbar.pageInset"
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

    // MARK: Reader

    /// Interval: a reader request, from asking for the page's article until it is returned (or
    /// found not readerable). Near zero for a repeat open of the same page.
    public static let readerExtract: StaticString = "reader.extract"
    /// Interval: showing an article in the reader view, from the request until the rendered page
    /// is handed to the reader web view.
    public static let readerShow: StaticString = "reader.show"

    // MARK: Tabs (TabStore). The shell emits these around its `TabStore` calls.

    /// Interval: a new tab, from the open request (new-tab button, link, popup) to its pane
    /// showing it (or, in the background, to it being in the list).
    public static let tabOpen: StaticString = "tab.open"
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

    /// Interval: putting a tab's page on screen (tab switch). Restoring a discarded tab starts here
    /// too; its page coming back is `tab.restore`.
    public static let tabAttach: StaticString = "tab.attach"
    /// Interval from a discarded tab's restore starting to its page committing.
    public static let tabRestore: StaticString = "tab.restore"
    /// Interval from a tab's discard starting (reading its state) to its web view being released.
    public static let tabDiscard: StaticString = "tab.discard"
    /// Interval of a tab thumbnail snapshot, until WebKit returns the image.
    public static let tabSnapshot: StaticString = "tab.snapshot"
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

    /// `StaticString` names as `String`, for `XCTOSSignpostMetric(subsystem:category:name:)`.
    public static func name(_ name: StaticString) -> String {
        name.description
    }
}
