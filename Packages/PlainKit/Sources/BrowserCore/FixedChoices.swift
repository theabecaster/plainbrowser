import Foundation

/// Every value Plain decides instead of asking the user, in one place, each with the reason.
/// See AGENTS.md ("Opinionated and simple") and docs/ui-reference.md ("Fixed choices").
/// Changing one of these is a product decision; a new user-facing setting is not the fix.
public enum FixedChoices {
    // MARK: Setting defaults

    /// Most people already search with Google; it is the first-launch default (plan, section 11).
    public static let defaultSearchEngine = SearchEngine.google
    /// Tabs above the page, as Safari does on the Duo's inner screen: the strip sits under the
    /// top bar, shows only with two or more tabs, costs 34 pt and leaves the page its full width.
    /// It looks the same in landscape and portrait (a sidebar does not fit beside a portrait
    /// page), and it hides with the bar while reading.
    public static let defaultTabLayout = TabLayout.above
    /// A week keeps the tabs you come back to across a few days at hand and still clears the
    /// clutter without asking (owner's choice, 2026-11-27; a day archived tabs people still wanted).
    public static let defaultArchiveAfter = ArchiveAfter.oneWeek
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

    // MARK: Haptics (docs/ui-reference.md, "Haptics"; docs/research/haptics.md)

    /// Two haptics closer than this are one event: the first, synced to the visual, wins. 60 ms is
    /// under one tap's duration and over the gap between two calls for the same moment (a profile
    /// create's success and the list's tick).
    public static let hapticMinimumGap: TimeInterval = 0.06
    /// A refusal repeated faster than this stays silent, so a held or repeated press never buzzes.
    public static let hapticNothingThereGap: TimeInterval = 1
    /// Hysteresis on a gesture threshold, in points, so a finger resting on the line never chatters.
    public static let hapticThresholdHysteresis: CGFloat = 10
    /// The same hysteresis for a threshold measured in progress (0 to 1), such as the swipe up
    /// into the switcher: about 10 pt of a bar's travel.
    public static let hapticProgressHysteresis: CGFloat = 0.03

    // MARK: Launch and return (docs/research/launch.md)

    /// Away this long or longer, Plain opens to a fresh search over the last tab instead of the
    /// tab itself. Chrome and Firefox both switch to a start page at 4 hours: a short break (a
    /// call, lunch, a meeting) comes back to the page being read, while the next morning is a new
    /// errand. It sits well inside the shortest auto-archive interval (12 hours), so the last tab
    /// is still there behind the search.
    public static let freshSearchAfter: TimeInterval = 4 * 3600
    /// The longest the first frame waits for the last tab's picture to finish decoding off the
    /// main thread (it starts as the scene connects and usually finishes first). A frame of bare
    /// paper where the page should be reads as "empty"; 40 ms is under three frames, and the
    /// launch screen is still up meanwhile.
    public static let launchPictureWait: Duration = .milliseconds(40)
    /// The live page takes over from the picture once it has finished loading, or after this long
    /// at most, so a slow network never leaves a frozen picture on screen.
    public static let launchPictureMaxHold: Duration = .seconds(3)

    // MARK: Launch splash (docs/decisions.md, "Launch splash: through the P")

    /// A cold launch opens with the chosen icon's world and a dive through the P's counter (the
    /// owner's choice, 2026-11-27). The app is built and interactive underneath from its first
    /// frame; the splash only covers it.
    public static let launchSplashEnabled = true
    /// The mark's width on the splash, in points: a little under half the narrowest phone, so
    /// the P reads as the subject with the icon's field around it on every screen.
    public static let splashMarkWidth: Double = 152
    /// The dive starts no sooner than this after the process started, so the mark is seen for a
    /// moment on a fast launch and never lingers on a slow one.
    public static let splashMinimumTime: TimeInterval = 0.55
    /// ...and no sooner than this after the app's first frame: iOS crossfades from the launch
    /// screen to that frame, and a dive begun inside the fade would show both at once.
    public static let splashHandoff: TimeInterval = 0.3
    /// The whole dive, from the first movement to the app filling the screen. Short: the app is
    /// already there, and the dive is the way in, not a show.
    public static let splashDive: TimeInterval = 0.66
    /// The GPU renderer must be ready this long before the dive starts, or Core Animation plays
    /// the plain iris instead. The dive never waits for a shader.
    public static let splashRendererLead: TimeInterval = 0.08
    /// A touch (or a link from another app) ends the splash with this fade: gone at once, without
    /// a hard cut. The touch itself already went to the app underneath.
    public static let splashSkipFade: TimeInterval = 0.12
    /// A search-first launch has the field focused under the splash from the first frame, but
    /// its keyboard stays down until this far into the dive: iOS draws the keyboard above every
    /// window of the app, so it would lie over the splash. It rises as the dive lands, when the
    /// opening has cleared the screen: a keyboard coming up through the moving sheet was a third
    /// motion over the other two (design review). A touch brings it at once.
    public static let splashKeyboardAt: TimeInterval = 0.6
    /// The app starts this much larger under the hole and settles to its size as the hole opens,
    /// so the page comes up toward the viewer instead of sitting flat behind a growing circle.
    public static let splashContentZoom: Double = 1.08

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
    /// Darkening works per color, by the role the color plays, in OKLab lightness (L, 0 black to
    /// 1 white), keeping hue and as much chroma as fits. Backgrounds lighter than
    /// `darkPagesBackgroundThreshold` turn dark, white landing on `darkPagesBackgroundLightness`;
    /// darker backgrounds (a black hero, a dark card, a saturated brand button) stay exactly as
    /// the site made them. 0.21 is about #181818: Dark Reader's and Chrome's page dark, a step off
    /// black so cards and shadows still read. 0.62 keeps mid-tone brand colors (Apple's blue
    /// button is 0.57) and catches every light grey section, card and tint.
    public static let darkPagesBackgroundLightness = 0.21
    public static let darkPagesBackgroundThreshold = 0.62
    /// Text darker than `darkPagesTextThreshold` turns light, black landing on
    /// `darkPagesTextLightness`; lighter text (white on a dark hero, light links) stays. The line
    /// between them is continuous (0.66 maps to itself), so greys keep their order: body text
    /// becomes near white, secondary grey a softer light grey. 0.94 is Dark Reader's text
    /// (#e8e6e3): bright, short of glaring white.
    public static let darkPagesTextLightness = 0.94
    public static let darkPagesTextThreshold = 0.66
    /// Borders and rules: light ones turn into a grey that still shows on the dark page (white
    /// becomes 0.30, a typical #d2d2d7 hairline 0.37); dark ones stay.
    public static let darkPagesBorderLightness = 0.30
    public static let darkPagesBorderThreshold = 0.55
    /// A dark box (a card, a panel) on a light section that dark pages darkened would melt into
    /// it: when the two differ by less than this contrast ratio, the box is lifted to the
    /// section's lightness plus `darkPagesLift` (OKLab L), as raised surfaces are lighter in dark
    /// designs. 1.15 lifts a #1d1d1f card on a #f5f5f7 section (1.03 once darkened) and leaves a
    /// black hero on a white page (1.19) black.
    public static let darkPagesLiftBelowContrast = 1.15
    public static let darkPagesLift = 0.05
    /// Text whose contrast with what is behind it falls under this (WCAG AA for body text, the
    /// target Safari's Adaptive Dark Mode states) is made lighter or darker until it passes.
    public static let darkPagesMinimumContrast = 4.5
    /// Script time spent in the first frame on elements the style sheets can't reach (inline
    /// styles, legacy color attributes, sheets from another origin, icons, contrast fixes). The
    /// page's top is first in the document, so this covers the visible area; the rest is done in
    /// idle slices of `darkPagesSliceBudget`, which never hold a frame.
    public static let darkPagesFirstFrameBudget = 4.0
    public static let darkPagesSliceBudget = 5.0
    /// An inline SVG with a fill or stroke at least this colorful (0 grey, 1 a pure hue) is a
    /// logo or an illustration and keeps its colors; one in greys is an icon that flips with the
    /// text so it stays visible. 0.25 keeps brand colors and leaves near-greys to flip.
    public static let darkPagesColoredSVGChroma = 0.25
    /// Shapes read per inline SVG for that check: a logo shows its colors in its first few shapes.
    public static let darkPagesSVGShapesChecked = 24
    /// A black-and-white logo picture (a dark mark on a transparent ground) is inverted on a
    /// darkened page, as Safari does, when it is at most this big on the page (CSS pixels): a
    /// wordmark or an icon, never a photo or an illustration.
    public static let darkPagesLogoMaxWidth = 640
    public static let darkPagesLogoMaxHeight = 240
    /// Pictures read per page for that check, each from a copy this many pixels across: a page
    /// has a few logos, and 64 pixels show whether a mark is grey on clear in well under 1 ms.
    public static let darkPagesLogosRead = 16
    public static let darkPagesLogoSample = 64
    /// How far the mark is inverted: black lands near the darkened text's light grey, not on
    /// pure white, which would glare next to it.
    public static let darkPagesLogoInvert = 0.92
    /// What counts as such a mark: at least this share of the picture see-through, of the rest
    /// at most these shares colored or white (a two-tone or colored picture is a design, not a
    /// wordmark), and showing under this contrast against what is behind it (it would vanish).
    public static let darkPagesLogoClearShare = 0.15
    public static let darkPagesLogoColoredShare = 0.04
    public static let darkPagesLogoWhiteShare = 0.15
    public static let darkPagesLogoVanishingContrast = 3.0
    /// Custom elements defined after the page's walk met them attach their shadow roots late;
    /// they are looked for again this many milliseconds after load (and on every batch and
    /// scroll), covering components that load with the page and the slow ones after.
    public static let darkPagesLateComponentChecks = [300, 1_500, 4_000]
    /// Content and style sheets a page adds after load are darkened in batches at most this many
    /// milliseconds apart, so an infinite-scroll page costs one pass per burst, not one per node.
    /// While the page is still loading, batches run every frame instead.
    public static let darkPagesWatchDelay = 100
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
    /// A PDF longer than this many pages says "Saving as PDF…" while it is made: the first page
    /// waits for the page's process to lay out the whole document (about 0.4 s for 120 pages on
    /// the simulator), and a short document is done before a message could be read.
    public static let exportProgressPages = 20

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
    /// A page is watched for signs of a consent manager until this many milliseconds after it
    /// loads; only then does the engine go into it. Consent managers load with the page or soon
    /// after, and the EasyList Cookie List still hides a banner that comes later.
    public static let cookieBannerWatchMilliseconds = 5_000
    /// A banner answered this many times on one site within `cookieBannerLoopWindow` (a page that
    /// reloads itself after each answer) means the answer doesn't stick: the site is left alone
    /// for the rest of the launch instead of reloading forever.
    public static let cookieBannerLoopLimit = 3
    public static let cookieBannerLoopWindow = Duration.seconds(60)

    // MARK: Address bar
    // MARK: Address bar

    /// Suggestions older than this are useless while typing; give up and show what we have.
    public static let suggestionTimeout = Duration.milliseconds(1_000)
    /// When no cached answer fits a keystroke, the previous keystroke's engine rows stay this long
    /// while the new answer is on its way, so they change into the new rows in one step instead of
    /// leaving and coming back a moment later. Long enough for a warm connection's answer (about
    /// 90 ms), short enough that rows for the old text never linger where anyone reads them.
    public static let suggestionHoldWindow = Duration.milliseconds(120)
    /// Engine suggestions kept per keystroke: enough to choose from, few enough to scan at a glance.
    public static let maxSearchSuggestions = 6
    /// History and favorite rows per keystroke, so pages never push search suggestions off screen.
    public static let maxPageSuggestions = 4
    /// One typed character means a site ("g" for github.com), not a word in a page title, so
    /// shorter input matches only addresses that start with it.
    public static let minTitleSearchLength = 2
    /// Total rows in the suggestion list; fits above the keyboard on the Duo's outer screen.
    public static let maxAddressBarSuggestions = 8

    /// Recently visited pages the focused address bar shows before typing (Arc shows one, Safari
    /// a row of Frequently Visited). Four read at a glance and leave room for favorites, the page
    /// itself and a copied link above the keyboard on the Duo's outer screen.
    public static let focusRecentPages = 4
    /// How many of the newest visits `recentPages` reads to find that many distinct pages: enough
    /// for a few reloads and back-and-forth, bounded so the read stays an index scan.
    public static let recentPagesScan = 64
    /// Recently closed tabs the focused address bar offers to reopen: the last two batches, the
    /// ones people still remember closing.
    public static let focusClosedTabs = 2
    /// Unread Reading List pages the focused address bar offers: the two saved last, the ones
    /// still meant for "later today".
    public static let focusReadingList = 2
    /// How long the copy button in the address bar shows its check mark: long enough to read,
    /// short enough to copy again.
    public static let copiedConfirmation: TimeInterval = 1.2
    /// A web address on the pasteboard is offered ("Open Copied Link") only this long after Plain
    /// first sees it, as Chrome does: an old copy is no longer an intention.
    public static let copiedLinkFreshness: TimeInterval = 10 * 60
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

    // MARK: Reading list (docs/research/bookmarks.md)

    /// No bookmark folders: Favorites are the one list of kept pages, History and the archive
    /// find the rest, and the reading list holds pages saved to read once. Folder use was never
    /// shown to be common, and Arc proved a browser works without bookmarks.
    public static let bookmarkFolders = false
    /// Saving for later keeps a reader copy of the article (Readability), as Chrome does, not a
    /// web archive: it is small, opens instantly in Plain's reader, and an article is what people
    /// save to read later. A page with no article is saved as its link only.
    public static let readingListKeepsReaderCopy = true
    /// A saved page opens live; when the network fails it (offline, the site gone or slow to
    /// answer), its saved copy opens in the reader on its own, with no setting or extra tap.
    public static let readingListOpensCopyWhenOffline = true
    /// Opening a page from the reading list marks it read, as in Safari and Chrome; a swipe
    /// marks it unread again.
    public static let readingListMarksReadOnOpen = true
    /// Reading speed for the "6 min" estimate: about 230 words a minute of about 5.5 characters
    /// with the space (adult silent reading, Brysbaert 2019).
    public static let readingCharactersPerMinute = 1_250
    /// Unread saved pages that match the typed text rank right after favorites in the address
    /// bar: the user saved them to come back to.
    public static let readingListRanksInSuggestions = true
    /// Rows the Reading List screen reads at most: years of saving for most people, and one cheap
    /// indexed read.
    public static let readingListLimit = 1_000

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
    /// How long a tab stays in the archive before it clears itself, with its state file; the page
    /// stays in History. One archive that tidies itself, not a second place for stale tabs to
    /// learn (docs/decisions.md, "The archive clears itself after 30 days"). With the week
    /// default a tab is gone about five weeks after it was last opened, past Safari's longest
    /// Close Tabs choice (a month, and its tabs close outright); Arc's archive kept everything
    /// until it was cleared by hand, which is the pile this avoids.
    public static let archivedTabLifetime: TimeInterval = 30 * 24 * 3600
    /// The archive's safety net beside its 30 days: past this many tabs the oldest go, with their
    /// state files (a few KB each). Far more than 30 days of ordinary browsing, the size the
    /// archive search and the Archive screen are tested on, and what bounds every pruning pass.
    public static let archivedTabLimit = 1_000
    /// Archive search results shown per query: more than fits on screen, cheap to fetch.
    public static let archiveSearchLimit = 200

    // MARK: Profiles (docs/decisions.md, "Profiles, no tab groups")

    /// Profiles a person can have, Personal included. Each is a row in the switcher's menu and a
    /// website data store on the phone; six fit the menu on the Duo's outer screen without
    /// scrolling, and work, personal and a few side projects fit with room to spare.
    public static let maxProfiles = 6
    /// A profile's name is a menu row and the switcher's title: about two short words.
    public static let profileNameLimit = 24

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
    /// The sidebar's rail: site tiles only, one 44 pt target plus a 4 pt margin each side, close
    /// to Safari's vertical-tab strip. It is forced while a split shows or the screen is partly
    /// folded, where a wider sidebar would squeeze the pages.
    public static let sidebarRailWidth: Double = 52
    /// The expanded sidebar: favicon and title. Wide enough for about 25 characters of a title;
    /// where the page would drop under `sideTabsMinimumPageWidth` it floats over the page instead.
    public static let sidebarExpandedWidth: Double = 260
    /// The tab strip under the top bar (Tab Layout: Above): 30 pt tabs, Safari's compact tab
    /// height on iPad, with 2 pt above and below. Each tab still takes a 44 pt touch.
    public static let tabStripHeight: Double = 34
    /// Tabs in the strip share its width, as Safari's tab bar does, between these widths: at the
    /// narrowest about 14 characters of a title show, and past it the strip scrolls; the widest
    /// keeps two tabs from stretching across the whole screen.
    public static let tabStripItemWidth: (minimum: Double, maximum: Double) = (140, 280)
    /// The top bar on a wide screen (the Duo's inner screen, iPad-size windows): one row of 44 pt
    /// controls under the status bar, as Safari puts it there. The page gets the full width and
    /// height under it, and the bar shrinks to the address while reading.
    public static let topBarHeight: Double = 44
    /// The top bar's address pill at its widest: about Safari's address field there. Wider, an
    /// address reads as a sentence across the screen and the buttons drift from it.
    public static let topBarPillMaxWidth: Double = 560
    /// The top bar's pill while reading, relative to its resting size: the address stays readable
    /// (about 31 pt high) and the chrome drops under 9% of the inner screen.
    public static let topBarCollapsedScale: Double = 0.7
    /// The room Plain leaves for the status bar's time beside a camera the status items wrap, used
    /// only where the system reports the camera (an occlusion region inside the top safe area) but
    /// no corner-adaptive guide says how far the items reach. It is an allowance for the time's
    /// text, not a screen measurement: the camera's place still comes from the system. Calibrated
    /// on the owner's screenshot of the Duo's inner screen (landscape, 3x): the time "11:08"
    /// starts at x 831.7 pt, 53 pt before the camera (884.7), the battery ring wraps the camera
    /// (883–924) and the indicators above the time start further right (845.7). Plus 4 pt for a
    /// wider time ("10:58", "12:00": the 1s are the narrow digits). The top bar's trailing capsule
    /// then ends `statusItemsGap` (8 pt) before that: 12 pt before "11:08", at least
    /// 8 before any 12-hour time. Was 64 (with a 12 pt gap: 23 pt short of the clock, which the
    /// owner saw as the buttons stopping too far from the status items).
    public static let statusItemsReach: Double = 57
    /// How far inside the status items' own occlusion region their left edge is taken to be,
    /// where the region's margins don't say more. The region pads the items for interactive
    /// content: on the Duo's inner screen it starts at x 807 and the time at 831 (Device Hub's
    /// simulator, landscape, matching the owner's device screenshot). 24 less 4 pt for a wider
    /// time. Taking the region's edge itself left Tabs, Share and More 32 pt from the clock;
    /// treating the region as a camera (and reaching 64 pt past it, the build the owner tried)
    /// left them about 100 pt away, with the strip cut there too.
    public static let statusRegionPadding: Double = 20
    /// How far above the bottom of the status items' own region the top bar's row ends, where
    /// the region's margins don't place the items: they sit low in it (Duo inner screen: region
    /// 0–82, items 27–69), so a 44 pt row ending 12 pt above the bottom (26–70) is centered on
    /// them. Centered on the region instead, the row sat 7 pt above the clock (design review).
    public static let statusRegionBottomPadding: Double = 12
    /// How far past the safe area's top a status-zone region may end and still count as inside
    /// it: rounding, since the Duo's inner screen reports a safe area of 81 or 82 pt against a
    /// region ending at 82. Used where the corner is read and where the lanes skip its regions,
    /// so both agree.
    public static let statusZoneRounding: Double = 2
    /// Between the top bar's end (Tabs, Share and More) and the status items' left edge (the
    /// clock) on the Duo's inner screen: the glass sits snug beside them without touching, at the
    /// bar's own spacing (its capsules sit 6 pt from the address). Was 12 on top of a 64 pt
    /// reach past the status region, which left the capsule about 100 pt short of the clock on
    /// the device (owner: "spaced properly next to the status bar Wi-Fi and all the other
    /// indicators").
    public static let statusItemsGap: Double = 8
    /// The narrowest pane of a split: the narrowest current iPhone. Narrower panes get cramped
    /// mobile layouts, so the Duo's inner portrait (669 pt) shows one pane.
    public static let splitMinimumPaneWidth: Double = 375
    /// The side pane (Reader, Find, History next to the page) takes this share of the pages' width
    /// (docs/plan.md, section 6: about 30%): 285 pt in the Duo's inner landscape leaves the page
    /// 666 pt, still a desktop-width page.
    public static let sidePaneFraction: Double = 0.3
    /// The side pane's narrowest width: a history row's title and address, or a reader line of
    /// about 30 characters, still read at the system's text size. In the Duo's inner portrait
    /// (669 pt) 30% would be 200 pt, so it takes 250 and leaves the page 419, wider than the outer
    /// screen's 382.
    public static let sidePaneMinimumWidth: Double = 250
    /// Find in the side pane lists at most this many matches (the count says how many there are):
    /// past a few hundred a list stops helping, and each match keeps a DOM range in the page.
    public static let findResultLimit = 300
    /// Characters of context before a match in the side pane's Find (twice this after it): about
    /// a line of the pane either side, enough to tell matches apart.
    public static let findResultContext = 40
    /// Find in the side pane waits this long after a keystroke before it searches, so typing a
    /// word searches once, not per letter.
    public static let findDebounce: Duration = .milliseconds(150)
    /// Find in the side pane walks this many text nodes between pauses that hand the page's main
    /// thread back (a few milliseconds of walking on a phone), so a huge page keeps scrolling and a
    /// newer query stops the older one at the next pause.
    public static let findChunkNodes = 2000
    /// The edge swipe opens the side pane past this share of its width, as the sidebar's drag
    /// settles past a third: less is a touch that strayed in from the edge.
    public static let sidePaneOpenFraction = 1.0 / 3
    /// A swipe this fast (pt/s) opens the side pane however short it was; a swipe back half as
    /// fast cancels it. The sidebar's flick speed, so both edges feel the same.
    public static let sidePaneFlickVelocity = 500.0
    /// Past the pane's width the edge swipe moves it at this share of the finger's travel: it
    /// gives, so the end of the pane reads as an end.
    public static let sidePaneOverdragFactor = 0.25

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

    // MARK: On-device AI (docs/research/browse-for-me.md)

    /// Summaries are written by Apple's on-device model only, never Private Cloud Compute or any
    /// server: the pages read stay on the phone. Where the model can't run, the entries are not
    /// there at all (docs/state-rules.md §4, §6), and they appear by themselves once it is ready.
    public static let summariesOnDeviceOnly = true
    /// While Apple's model is still downloading or preparing (`modelNotReady`, which Apple says
    /// resolves by itself), Plain looks again this often while it is on screen, besides each
    /// return to the app, so Browse for Me and Summarize Page appear soon after the model is
    /// ready. The check is one cheap read off the main thread.
    public static let aiNotReadyRecheck = Duration.seconds(30)
    /// A line saying a feature is off for Plain (a site's camera, microphone or location request
    /// while iOS has it off) shows once per site until the switch changes, in memory only
    /// (`SystemAccessNoticeMemory`): a site that asks on every page gets one line, and Plain keeps
    /// no record of which sites asked. Its button reads "Settings", short enough for the
    /// narrowest toast; the error page, which has room, says "Open Settings".
    public static let switchedOffToastButton = "Settings"
    /// Browse for Me reads this many results, as Arc Search does: enough points of view to
    /// cross-check, few enough to read in a few seconds and to fit the model's context.
    public static let browseSources = 5
    /// Results kept beyond those five: a page that fails or is too slow early is replaced by the
    /// next result while the time budget lasts.
    public static let browseCandidates = 8
    /// The results page gets this long to load and show its results before Plain tries the next
    /// one (DuckDuckGo's lite page) or gives up. Results pages answer in well under a second on a
    /// good connection; four seconds covers a slow one without a long wait on a broken engine.
    public static let browseResultsTimeout = Duration.seconds(4)
    /// The sources are read in parallel within this budget, from the results arriving. Whatever
    /// was read by then is summarized; slower pages are skipped, and the screen says so.
    public static let browseReadBudget = Duration.seconds(7)
    /// Past the budget with nothing read, Plain waits this much longer for the first page before
    /// saying none could be read.
    public static let browseFirstSourceGrace = Duration.seconds(3)
    /// No replacement for a skipped source starts this close to the end of the read budget: it
    /// would not finish in time, and would only cost a page load.
    public static let browseReplacementCutoff = Duration.seconds(1)
    /// A results page whose list comes from script and is still empty when its HTML has parsed
    /// gets this long more, until its load event, before Plain reads it again.
    public static let browseResultsScriptWait = Duration.seconds(2)
    /// How often a hidden page is asked whether its HTML has parsed. Each answer is immediate (no
    /// promise a navigation could leave hanging); 50 ms is under the time a parse takes.
    public static let hiddenPageReadyPoll = Duration.milliseconds(50)
    /// Links read from a results page at most: far more than the eight results kept, enough to
    /// get past ads and the engine's own links.
    public static let browseResultsLinksRead = 40
    /// Summarize Page reads the page's text within this time; a page that takes longer (a script
    /// stuck in WebKit) says it has no text instead of leaving "Writing…" up.
    public static let summaryPageReadTimeout = Duration.seconds(5)
    /// A source with less readable text than this (characters) is a page without an article:
    /// a login wall, a video, an app shell. It is skipped.
    public static let browseMinimumText = 400
    /// Text read from one page at most (characters), before fitting: bounds memory and the work of
    /// the fit, and is more than any page's share of the context.
    public static let summaryMaxPageText = 24_000
    /// Sites whose result pages hold no article text, or only behind a login: videos and social
    /// posts. Skipped, so a source slot goes to a page that can be read.
    public static let browseSkippedSites: [String] = [
        "youtube.com", "youtu.be", "tiktok.com", "instagram.com", "facebook.com", "x.com", "twitter.com",
        "pinterest.com", "linkedin.com", "maps.google.com",
    ]
    /// Source pages load with their JavaScript off: an article's text is in its HTML, the page's
    /// own scripts (ads, analytics, trackers) never run, nothing they would send leaves the phone,
    /// and each hidden page costs a fraction of the memory. Reader runs in its own world either
    /// way. A results page that may build its list with script (Bing) keeps it on.
    public static let browseSourcesWithoutJavaScript = true
    /// Tokens kept for the instructions, the answer's schema and a margin (measured: about 520
    /// for both with the schema in the prompt).
    public static let summaryReservedTokens = 700
    /// The answer's room in tokens: a title and up to four sections of up to four points, with
    /// citations, is about 600.
    public static let summaryResponseTokens = 800
    /// Characters per token for the first fit, before the model counts the real prompt: English
    /// runs about 4, other languages less; 3 leaves room for both.
    public static let summaryCharactersPerToken = 3.0
    /// A prompt the model counts over its room is cut to this share of the room it would need:
    /// a tenth below the count, since cutting at paragraph ends removes less than asked.
    public static let summaryRefitMargin = 0.9
    /// A result's title read from a results page at most (characters): a long headline, never a
    /// whole snippet.
    public static let browseResultTitleLength = 300
    /// Summarize Page on a page longer than the context: this share of the room goes to the
    /// page's opening, the rest to paragraphs spread over the remainder.
    public static let summaryOpeningShare = 0.6
    /// The summary screen redraws the streaming text at most this often: smooth to the eye at
    /// a fraction of the layout work of a redraw per token.
    public static let summaryRedrawInterval = Duration.milliseconds(66)
    /// Browse for Me and Summarize Page write nothing to disk: no history, no tab, no website
    /// data. Hidden pages load in a non-persistent store made for each run and dropped after it,
    /// for regular and private tabs alike, so the user's cookies and logins are never sent to
    /// pages they didn't choose to open.
    public static let summariesLeaveNoTrace = true

    // MARK: System integration (docs/research/system-integration.md)

    /// Spotlight gets favorites only. Favorites are pages the user chose to keep at hand, so
    /// finding them from the Home Screen is expected; history is everything they read, which
    /// nobody expects in system search (Safari keeps it out too), and Clear History would have
    /// to chase it. Private tabs reach nothing outside the app.
    public static let spotlightIndexesHistory = false
    /// The page on screen is offered to the user's other devices (Handoff), except in a private
    /// tab: a private page leaves no trace, on this phone or another.
    public static let handoffInPrivateTabs = false
    /// Search from Shortcuts, Siri and the widget uses the engine chosen in Settings, with no
    /// per-shortcut engine: one choice, made once.
    public static let intentsUseSettingsEngine = true
    /// The Spotlight and widget sync starts this long after launch, at background priority, so it
    /// never competes with the first frame or the first page load. Favorites rarely change; a
    /// few seconds late costs nothing.
    public static let systemSyncLaunchDelay = Duration.seconds(5)
}
