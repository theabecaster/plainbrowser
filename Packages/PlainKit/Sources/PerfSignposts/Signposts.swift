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
    /// Event: the favorites editor opened from the favorites strip.
    public static let favoritesEditorOpen: StaticString = "favorites.editorOpen"

    /// `StaticString` names as `String`, for `XCTOSSignpostMetric(subsystem:category:name:)`.
    public static func name(_ name: StaticString) -> String {
        name.description
    }
}
