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
    /// History rows fetched per keystroke: twice the rows shown, so http/https and www variants
    /// of one page can be merged without leaving the list short.
    public static let historyCandidates = 2 * maxPageSuggestions
    /// One typed character means a site ("g" for github.com), not a word in a page title, so
    /// shorter input matches only addresses that start with it.
    public static let minTitleSearchLength = 2
    /// Total rows in the suggestion list; fits above the keyboard on the Duo's outer screen.
    public static let maxAddressBarSuggestions = 8

    // MARK: History

    /// Frecency halves every 30 days: last month's habits still count, last year's fade out.
    public static let frecencyHalfLife: TimeInterval = 30 * 24 * 3600
    /// Visits are buffered and written in one transaction at most this often, so page loads never
    /// wait on the database and SQLite does one write instead of many.
    public static let historyFlushInterval = Duration.seconds(2)
    /// A buffer this full is written right away, so a burst of loads stays bounded.
    public static let historyFlushBatchSize = 64

    // MARK: Tabs

    /// Tabs kept fully live besides the visible ones (plan, section 4, tab tiers).
    public static let extraLiveTabs = 3
    /// Tab thumbnails are this wide in points; full-size snapshots cost 70+ MiB (research notes).
    public static let thumbnailWidth: Double = 200
}
