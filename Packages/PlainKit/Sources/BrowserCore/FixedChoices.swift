import Foundation

/// Every value Plain decides instead of asking the user, in one place, each with the reason.
/// See AGENTS.md ("Opinionated and simple") and docs/ui-reference.md ("Fixed choices").
/// Changing one of these is a product decision; a new user-facing setting is not the fix.
public enum FixedChoices {
    // MARK: Setting defaults

    /// Most people already search with Google; it is the first-launch default (plan, section 11).
    public static let defaultSearchEngine = SearchEngine.google
    /// Regular tabs work on every screen; side tabs are an opt-in for big windows.
    public static let defaultTabLayout = TabLayout.regular
    /// A day keeps today's tabs at hand and clears yesterday's clutter without asking.
    public static let defaultArchiveAfter = ArchiveAfter.oneDay

    // MARK: Decided for the user, no setting

    /// Ads, trackers and cookie banners are blocked everywhere; the page menu can turn it off per site.
    public static let contentBlockingAlwaysOn = true
    /// The content-blocking list compiled first on first launch (and after an update changes it):
    /// the highest-value network rules, third-party ad and tracker domains plus EasyPrivacy,
    /// filled to the rule limit by tools/blocklists. Trackers leak data on every page, so they
    /// are blocked after the first compile (about 2 s), not after all of them (about 8 s).
    public static let priorityBlocklist = "blocklist-01"
    /// Every cosmetic (element-hiding) rule lives in this one list, compiled second: ads still
    /// show until it lands, but hiding is visible polish next to stopping the requests. One list
    /// means one `display: none` stylesheet per frame, and cosmetic churn recompiles one list.
    public static let cosmeticBlocklist = "blocklist-02"
    /// HTTPS is always tried first; nobody wants plain HTTP when HTTPS works.
    public static let httpsUpgradeAlwaysOn = true
    /// Haptics follow the iOS system setting, so there is no second switch to find.
    public static let hapticsFollowSystem = true
    /// Text size follows Dynamic Type, which people already set once for every app.
    public static let textFollowsDynamicType = true
    /// Dark mode follows the system appearance.
    public static let appearanceFollowsSystem = true
    /// Reduce Motion swaps zooms and slides for a short crossfade.
    public static let motionFollowsReduceMotion = true
    /// Page zoom and desktop/mobile site are remembered per site, automatically.
    public static let perSiteChoicesRemembered = true

    // MARK: Address bar

    /// Suggestions older than this are useless while typing; give up and show what we have.
    public static let suggestionTimeout = Duration.milliseconds(1_000)
    /// Engine suggestions kept per keystroke: enough to choose from, few enough to scan at a glance.
    public static let maxSearchSuggestions = 6
    /// History and favorite rows per keystroke, so pages never push search suggestions off screen.
    public static let maxPageSuggestions = 4
    /// One typed character means a site ("g" for github.com), not a word in a page title, so
    /// shorter input matches only addresses that start with it.
    public static let minTitleSearchLength = 2
    /// Total rows in the suggestion list; fits above the keyboard on the Duo's outer screen.
    public static let maxAddressBarSuggestions = 8
    /// Private tabs never send what is typed to the search engine: a private tab should leave no
    /// trace anywhere, and Firefox makes the same call (`browser.search.suggest.enabled.private`
    /// is false). History and favorites still suggest, from the device only.
    public static let remoteSuggestionsInPrivateTabs = false
    /// Engine answers kept in memory, newest used first. Enough for the keystrokes of a few
    /// queries, so backspacing and retyping never wait on the network; small enough to ignore.
    public static let suggestionCacheSize = 64
    /// A cached answer older than this is asked for again: suggestions follow the news.
    public static let suggestionCacheLifetime = Duration.seconds(600)
    /// Focusing the address bar warms the connection to the suggestion host at most this often.
    /// iOS keeps an idle HTTP/2 connection for about a minute, so a shorter wait would only add
    /// requests, and a longer one would let the connection go cold between focuses.
    public static let suggestionPreconnectInterval = Duration.seconds(45)

    // MARK: History

    /// Frecency halves every 30 days: last month's habits still count, last year's fade out.
    public static let frecencyHalfLife: TimeInterval = 30 * 24 * 3600
    /// Visits are buffered and written in one transaction at most this often, so page loads never
    /// wait on the database and SQLite does one write instead of many.
    public static let historyFlushInterval = Duration.seconds(2)
    /// A buffer this full is written right away, so a burst of loads stays bounded.
    public static let historyFlushBatchSize = 64
    /// Visits the History screen loads at a time; more load as the list scrolls to the end. A few
    /// days of browsing for most people, and cheap to group and show.
    public static let historyPageSize = 300
    /// Pause after the last keystroke before History searches, so fast typing runs one query.
    public static let historySearchDelay = Duration.milliseconds(150)
    /// A visit to an address the user typed (or picked in the address bar) counts this many link
    /// clicks in frecency. Typing an address is intent; following a link is often incidental.
    /// Firefox weighs typed visits 20x a link, but its score also folds in bookmarks and visit
    /// counts; in Plain's plain decayed sum, 4x lets a site typed weekly outrank pages clicked
    /// through daily without letting one typed visit bury a month of habit.
    public static let typedVisitWeight: Double = 4
    /// Address-bar picks remembered per typed prefix decay by this factor every day, and a pick
    /// whose weight drops under `inputHistoryMinimumUse` is forgotten (about six months unused).
    /// Firefox's values for `moz_inputhistory`.
    public static let inputHistoryDailyDecay = 0.975
    public static let inputHistoryMinimumUse = 0.01
    /// Each new pick keeps this share of a page's earlier picks, then adds one (Firefox's
    /// update), so repeated picks approach 10 and a new habit overtakes an old one in a few picks.
    public static let inputHistoryPickRetention = 0.9
    /// Remembered picks offered per keystroke: the strongest becomes the top hit, and a second
    /// keeps a close runner-up in the list.
    public static let inputHistoryMatches = 2

    // MARK: Storage maintenance

    /// Pages kept in history; the least frecent go first beyond this. Firefox's expiration
    /// targets a page cap derived from the device (tens of thousands to about 150k on desktop);
    /// 100k is the size the address bar's 16 ms p95 budget is tested on, so it holds for everyone.
    public static let historyMaxPlaces = 100_000
    /// Visits older than this are deleted. Safari's default is one year too, and with a 30-day
    /// frecency half-life a year-old visit weighs 1/4096 of a fresh one, so ranking never misses it.
    public static let historyMaxAge: TimeInterval = 365 * 24 * 3600
    /// Site icons not refreshed in this long belong to sites no longer visited; a visit fetches
    /// the icon again.
    public static let faviconMaxAge: TimeInterval = 90 * 24 * 3600
    /// Daily maintenance (pruning, FTS and SQLite `optimize`) runs at most this often.
    public static let maintenanceInterval: TimeInterval = 24 * 3600
    /// After a clear, compaction (VACUUM) waits this long, so Clear History and Data (history,
    /// then icons, then website data) compacts once at the end instead of after each step.
    public static let compactionDelay = Duration.milliseconds(500)
    /// Maintenance waits this long after launch, so it never competes with the first page load.
    public static let maintenanceLaunchDelay = Duration.seconds(20)

    // MARK: Tabs

    /// Tabs kept fully live besides the visible ones (plan, section 4, tab tiers).
    public static let extraLiveTabs = 3
    /// Tab thumbnails are this wide in points; full-size snapshots cost 70+ MiB (research notes).
    public static let thumbnailWidth: Double = 200
    /// Panes per window: one, or two side by side on the Duo's inner screen. A third would leave
    /// each page narrower than the outer screen.
    public static let maxPanesPerWindow = 2
    /// Close actions Reopen Closed Tab can undo, newest first. Chrome keeps 25 entries
    /// (`TabRestoreService`); more is never reached by hand, fewer loses a Close All Tabs.
    public static let recentlyClosedLimit = 25
    /// A page's links and popups open right after it, after the tabs it already opened, so a
    /// reading session stays together (Chrome and Firefox do the same).
    public static let childTabsOpenNextToOpener = true
    /// Closing a tab another tab opened goes back to that opener when it is still open, so a
    /// quick look at a link returns where it started.
    public static let closingChildSelectsOpener = true
    /// New tabs without an opener go at the end of the list, like Safari, so the order reads as
    /// the order they were opened.
    public static let newTabsOpenAtEnd = true
    /// Pinned means kept: Close All Tabs leaves pinned tabs open.
    public static let closeAllKeepsPinnedTabs = true
    /// A closed private tab leaves no trace, not even in Reopen Closed Tab.
    public static let privateTabsSkipRecentlyClosed = true
    /// Tab changes are written this long after the last one, so a drag or a page's title changes
    /// cost one write. A crash loses at most this much; the app also writes on going to the
    /// background.
    public static let tabSaveDelay = Duration.milliseconds(500)
    /// A tab write that fails (disk full, a locked file) is tried this many times, a short pause
    /// apart, before it is dropped; later writes wait behind it so they never land first. Three
    /// rides out a passing lock without holding later saves for long.
    public static let tabWriteAttempts = 3
    public static let tabWriteRetryDelay = Duration.milliseconds(100)
    /// Archived tabs kept; the oldest are deleted beyond it, with their state files (a few KB
    /// each). Months of tabs at the 1-day default, and the size the archive search is tested on.
    public static let archivedTabLimit = 1_000
    /// Archive search results shown per query: more than fits on screen, cheap to fetch.
    public static let archiveSearchLimit = 200

    // MARK: Tab gallery

    /// Tab gallery width, in points, from which it shows the wide grid. Below it the gallery is
    /// a phone-sized card list; above it there is room for twice the columns.
    public static let tabGalleryWideWidth: Double = 640
    /// Tab gallery columns below and above `tabGalleryWideWidth`. Always even, so on the Duo's
    /// inner screen no card straddles the fold (docs/plan.md, section 6).
    public static let tabGalleryColumns = (narrow: 2, wide: 4)
}
