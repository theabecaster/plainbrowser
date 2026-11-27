import Foundation

/// Every value Plain decides instead of asking the user, in one place, each with the reason.
/// See AGENTS.md ("Opinionated and simple") and docs/ui-reference.md ("Fixed choices").
/// Changing one of these is a product decision; a new user-facing setting is not the fix.
public enum FixedChoices {
    // MARK: Setting defaults

    /// Most people already search with Google; it is the first-launch default (plan, section 11).
    public static let defaultSearchEngine = SearchEngine.google
    /// Tabs on the left: on the Duo's inner screen a sidebar uses the spare width beside a page
    /// (a top strip takes height from a short landscape screen), its rail costs 64 pt, and the
    /// leading edge is where a list is read from. The system's vertical bar sits on the right.
    public static let defaultTabLayout = TabLayout.left
    /// A day keeps today's tabs at hand and clears yesterday's clutter without asking.
    public static let defaultArchiveAfter = ArchiveAfter.oneDay
    /// Follow iOS: people set light or dark once for every app, often on a schedule, and Safari,
    /// Chrome and Firefox all start there. Light and Dark are for someone who wants the browser
    /// different from the rest of the phone.
    public static let defaultAppearance = Appearance.system

    // MARK: Decided for the user, no setting

    /// Ads, trackers and cookie banners are blocked everywhere, with no global switch: almost
    /// nobody wants them, and a page that breaks gets "Turn Off Blocking on This Site" in its page
    /// menu, which is remembered for that site.
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
    /// Reduce Motion swaps zooms and slides for a short crossfade.
    public static let motionFollowsReduceMotion = true
    /// Page zoom and desktop/mobile site are remembered per site, automatically.
    public static let perSiteChoicesRemembered = true

    // MARK: First run

    /// A short intro on first launch only (the owner's choice, docs/ui-reference.md, "First run"),
    /// never again after it is finished or skipped. No permission prompts in it: those wait until
    /// a site needs them.
    public static let introShownOnce = true
    /// The intro's default-browser step and the empty-tab "Set as Default Browser" card. Off until
    /// Apple grants Plain the default-browser entitlement (`com.apple.developer.web-browser`):
    /// without it Plain cannot be chosen as the default, so the prompts would point at a choice
    /// that is not there. Both are built and tested; turn this on when the entitlement lands.
    public static let defaultBrowserPromptsEnabled = false

    // MARK: Sign-in (docs/research/sign-in.md)

    /// Passkeys (WebAuthn) in web pages. Off until Apple grants Plain the
    /// `com.apple.developer.web-browser` entitlement and the build signs with
    /// `Plain/Plain-WebBrowser.entitlements`: without it WebKit refuses every passkey request for
    /// sites other than the app's own. With it `WKWebView` handles passkeys for every site itself
    /// (on iOS no second key is needed; `...web-browser.public-key-credential` is macOS only).
    /// While off, pages are told this browser has no passkey authenticator, so sites offer their
    /// password sign-in instead of a passkey button that can only fail, and a request a site makes
    /// anyway gets one short toast that says why. Turn it on in the same change as the
    /// entitlement.
    public static let passkeysEnabled = false
    /// Passwords come from iOS AutoFill (the Passwords app and every password manager the user
    /// turned on in Settings), in the keyboard's suggestion bar, as in Safari. On web fields the
    /// system shows it only to apps with the web-browser entitlement (docs/research/sign-in.md),
    /// so it arrives with the grant. Plain keeps no
    /// password store of its own: a second place for passwords is one more to keep in sync, and
    /// the system's already holds the user's passwords and passkeys.
    public static let passwordsFromSystemAutoFill = true

    // MARK: Page

    /// Page zoom steps, Safari's set: fine steps near 100% where people adjust, bigger ones past
    /// 150% where they only want "much larger". Every zoom lands on one of these, so a site's
    /// remembered zoom always matches a step.
    public static let pageZoomSteps: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    // MARK: Dark pages (docs/research/dark-mode.md)

    /// While Plain is dark, pages without a dark design of their own are darkened, as Safari
    /// does: a white page in a dark app is the brightest thing on screen at night. No setting:
    /// Light and Dark in Settings > Appearance already say what the user wants, and a page that
    /// looks wrong darkened gets "Turn Off Dark Pages for This Site" in its page menu, remembered
    /// for that site.
    public static let darkPagesOn = true
    /// A page counts as light, and is darkened, when its background's relative luminance (0 for
    /// black, 1 for white) is at least this: about #BCBCBC. Mid greys and every dark or colored
    /// background a site chose stay as they are; a page with no background of its own shows on
    /// the browser's white canvas and counts as white.
    public static let darkPagesLightBackground = 0.5
    /// Style rules read per page when looking for `prefers-color-scheme: dark`. Large sites have
    /// 10–30 thousand; a dark design's rules sit in any of them, but reading more than this costs
    /// more than a frame on a slow phone, and the background check catches the rest.
    public static let darkPagesMaxRulesRead = 20_000
    /// Elements checked for a background picture set by a style sheet (so it keeps its colors).
    /// About a long article's worth; past it, background pictures may show inverted, which is the
    /// cost of never spending more than a few milliseconds per page.
    public static let darkPagesMaxElementsScanned = 4_000
    /// An inline SVG with a fill or stroke at least this colorful (0 grey, 1 a pure hue) is a
    /// logo or an illustration and keeps its colors; one in greys is an icon that flips with the
    /// text so it stays visible. 0.25 keeps brand colors and leaves near-greys to flip.
    public static let darkPagesColoredSVGChroma = 0.25
    /// Shapes read per inline SVG for that check: a logo shows its colors in its first few shapes.
    public static let darkPagesSVGShapesChecked = 24
    /// After load, content a page adds is checked for background pictures in batches this many
    /// milliseconds apart, so an infinite-scroll page costs one pass per burst, not one per node.
    public static let darkPagesWatchDelay = 250
    /// A page that drops Plain's style sheets without touching its DOM gets them back on the next
    /// scroll or touch, checked at most this many milliseconds apart (and once more after a
    /// burst): a few microseconds of work twice a second at most, back before a line is read.
    public static let darkPagesSheetCheckInterval = 500

    // MARK: Translate Page (docs/research/translate.md)

    /// Pages are translated on the device with Apple's Translation framework, never on a server:
    /// the page's text stays on the phone, and it works offline once a language is downloaded.
    public static let translationOnDevice = true
    /// "Translate Page" shows in the page menu only on a page in a language the user doesn't read
    /// (their preferred languages in iOS Settings); there is no setting for "always translate".
    /// Once a tab is translated, its next pages in the same language translate by themselves,
    /// until Show Original: someone reading a site in another language wants all of it.
    public static let translationFollowsTab = true
    /// A foreign page gets one quiet hint, once ever: a toast naming the page's language with a
    /// Translate button. After that, the page menu is the only way (no banners, ui-reference).
    public static let translateHintShownOnce = true
    /// Characters of the page's text the language check reads: enough for the recognizer to be
    /// sure (it is reliable from a few hundred), small enough to cost nothing per page.
    public static let translateSampleLength = 2_000
    /// The recognizer's answer is used at this confidence or more; below it the page's own
    /// `<html lang>` decides, and with neither the page isn't offered for translation.
    public static let translateDetectionConfidence = 0.6
    /// One request to the translator holds at most this many characters and text pieces: a
    /// screenful of text comes back in one or two answers, and the first lands quickly.
    public static let translateBatchCharacters = 1_500
    public static let translateBatchCount = 40
    /// Requests waiting on the translator at once: enough to keep it busy, few enough that text
    /// near the screen is never stuck behind text far below it.
    public static let translateBatchesInFlight = 2
    /// Text a translated page adds (infinite scroll, a chat, a live score) is translated in
    /// batches at most this many milliseconds apart, not once per change.
    public static let translateMutationDelay = 250
    /// Text is translated once it is within this distance of the screen (a CSS margin): one and a
    /// half screens ahead, so scrolling at reading speed never shows the original.
    public static let translateLookahead = "150%"

    // MARK: Print and Save as PDF (docs/research/print-pdf.md)

    /// Regions whose standard paper is US Letter (ISO 3166 codes); everywhere else gets A4. A
    /// saved PDF should print on the paper in the drawer, and nobody wants to pick a size.
    public static let letterPaperRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "CR", "PR"]
    /// Half an inch: what Safari and most printers leave, enough that no printer clips text.
    public static let exportMargin: Double = 36
    /// How long Print and Save as PDF wait for lazily loaded pictures before going ahead without
    /// the stragglers: long enough for a page's pictures on a normal connection, short enough
    /// that the sheet still feels immediate.
    public static let exportImageWait = Duration.milliseconds(800)
    /// A saved PDF's name is the page title cut to this many characters: long titles stay
    /// recognizable in Files without becoming a paragraph.
    public static let exportFileNameLength = 100

    // MARK: Cookie banners (docs/research/cookie-banners.md)

    /// Cookie consent banners are answered automatically, rejecting wherever the banner offers it,
    /// as DuckDuckGo and Brave do: nobody reads them, "reject" is what a privacy-first browser
    /// should say, and a banner covering the page is the opposite of "the page gets the screen". A
    /// site that breaks gets "Turn Off Cookie Banner Blocking" in Site Settings, remembered for it.
    public static let cookieBannersHandled = true
    /// How many times the engine looks for a banner on a page (autoconsent's default): banners
    /// that load late are still found, and a page without one stops costing anything after it.
    public static let cookieBannerDetectRetries = 20
    /// Known banners are hidden from the first frame while they are judged, so they never flash;
    /// after this many milliseconds a banner the engine could not answer shows again.
    public static let cookieBannerPrehideTimeout = 2_000
    /// A banner answered this many times on one site within `cookieBannerLoopWindow` (a page that
    /// reloads itself after each answer) means the answer doesn't stick: the site is left alone
    /// for the rest of the launch instead of reloading forever.
    public static let cookieBannerLoopLimit = 3
    public static let cookieBannerLoopWindow = Duration.seconds(60)

    // MARK: Address bar
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
    /// Tab thumbnails are this wide in points: a phone's switcher card (two-thirds of a 393 pt
    /// page), so the card shows them at their own size, never upscaled and blurred. Full-size
    /// snapshots cost 70+ MiB (research notes).
    public static let thumbnailWidth: Double = 260
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

    // MARK: Duo layouts (docs/plan.md, section 6)

    /// The narrowest page side tabs may leave: a sidebar is docked only when the page beside it
    /// keeps at least this width, measured in layout after the sidebar and the system's bars, not
    /// on the window. Below it a phone-width page beside a sidebar reads as cramped, and sites
    /// switch to their mobile layout anyway.
    public static let sideTabsMinimumPageWidth: Double = 640
    /// The sidebar's rail: favicons only, one 44 pt target plus margins. It is forced while a
    /// split shows or the screen is partly folded, where a wider sidebar would squeeze the pages.
    public static let sidebarRailWidth: Double = 64
    /// The expanded sidebar: favicon and title. Wide enough for about 25 characters of a title;
    /// where the page would drop under `sideTabsMinimumPageWidth` it floats over the page instead.
    public static let sidebarExpandedWidth: Double = 260
    /// The tab strip above the pages (Tab Layout: Above): one 44 pt tap target with a small
    /// margin, the least height a short landscape screen can give up.
    public static let tabStripHeight: Double = 48
    /// A tab in the strip: room for about 18 characters of a title, so five or six tabs show at once
    /// on the Duo's inner screen; the rest scroll.
    public static let tabStripItemWidth: Double = 170
    /// The narrowest pane of a split: the narrowest current iPhone. Narrower panes get cramped
    /// mobile layouts, so the Duo's inner portrait (669 pt) shows one pane.
    public static let splitMinimumPaneWidth: Double = 375

    // MARK: Tab switching and toasts

    /// A bar swipe past the last tab shows a New Tab card; pulled this far, letting go opens a
    /// new tab (docs/plan.md, motion table). Far enough not to happen by accident.
    public static let newTabSwipeThreshold: Double = 80
    /// A swipe up from the address bar opens the gallery once it has covered this share of the
    /// screen's height, or at any speed upward past `galleryFlickSpeed` points per second.
    public static let gallerySwipeCommit: Double = 0.3
    public static let galleryFlickSpeed: Double = 600
    /// A short toast (Reopen Tab after a close, a finished download) stays this long: time to
    /// read a few words and reach the button, gone before it is in the way. Same as the gallery's.
    public static let toastDuration = Duration.seconds(4)
}
