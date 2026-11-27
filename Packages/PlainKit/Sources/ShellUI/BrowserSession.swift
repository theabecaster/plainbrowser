#if canImport(UIKit)
import ContentBlocking
import Foundation
import Reader
import Storage
import UIKit
import WebEngine

/// The engine side of one browser window, wired once: the web view pool with its stores, content
/// blocking, reader mode and the tab list. The app makes one per scene and hands it to
/// `BrowserViewController`.
///
/// Nothing here touches the disk or WebKit's processes at init. `start()` runs after the first
/// frame: warm-up, rule lists, the reader check and the last session's tab.
public final class BrowserSession {
    public let pool: WebViewPool
    let tabs: EngineTabs
    let blocker: ContentBlocker
    let reader = ReaderExtractor()
    let cookieBanners: CookieBanners
    /// Translate Page's engine (Apple's Translation framework; a stand-in in UI tests).
    let translator: any PageTranslator
    private let readerScripts: ReaderPageScripts
    private let cookieBannerSites: StorageSiteCookieBannersStore
    private let contentModes: StorageSiteContentModeStore
    private let pageZooms: StorageSitePageZoomStore
    private let darkPages: StorageSiteDarkPagesStore
    private let database: DatabaseProvider
    /// Each profile's history database (Personal's is the main one).
    public let profileData: ProfileDatabases
    private var started = false

    /// - Parameters:
    ///   - database: the app's database once it has opened off the main thread.
    ///   - tabStates: where each tab's history, scroll and sessionStorage are saved for relaunch;
    ///     nil keeps them in memory only.
    ///   - windowID: the window this scene showed last time (`UISceneSession.userInfo`), so each
    ///     scene comes back to its own tabs and panes; nil for a new scene.
    ///   - thumbnailDirectory: where tab thumbnails live; nil for Caches/Thumbnails. A test store
    ///     passes its own, since launch prunes thumbnails no tab in the database names.
    ///   - profileData: where profiles other than Personal keep their history; nil keeps it in
    ///     memory.
    public init(
        database: @escaping DatabaseProvider, tabStates: TabStateStore?, windowID: UUID? = nil,
        thumbnailDirectory: URL? = nil, profileData: ProfileDataLocation = ProfileDataLocation(directory: nil)
    ) {
        self.database = database
        self.profileData = ProfileDatabases(main: database, location: profileData)
        contentModes = StorageSiteContentModeStore(database: database)
        pageZooms = StorageSitePageZoomStore(database: database)
        darkPages = StorageSiteDarkPagesStore(database: database)
        blocker = ContentBlocker(allowListStore: StorageSiteAllowListStore(database: database))
        readerScripts = ReaderPageScripts(extractor: reader)
        cookieBannerSites = StorageSiteCookieBannersStore(database: database)
        cookieBanners = CookieBanners(store: cookieBannerSites)
        #if DEBUG
        translator = ProcessInfo.processInfo.arguments.contains("-PlainTestTranslator")
            ? TestPageTranslator() : AppleTranslator()
        #else
        translator = AppleTranslator()
        #endif
        pool = WebViewPool(
            tabStates: tabStates,
            permissionStore: StorageSitePermissionStore(database: database),
            contentModes: contentModes,
            contentRules: blocker,
            pageScripts: ShellPageScripts([readerScripts, cookieBanners]),
            thumbnailDirectory: thumbnailDirectory,
            pageZooms: pageZooms,
            darkPages: darkPages,
            translator: translator
        )
        tabs = EngineTabs(pool: pool, database: database, tabStates: tabStates, windowID: windowID)
        tabs.privateSessionDidEnd = { [cookieBanners] in cookieBanners.endPrivateSession() }
    }

    /// The window this scene shows. Keep it with the scene (`UISceneSession.userInfo`) so the next
    /// launch gives the scene the same tabs; it is final once the saved tabs are in.
    public var windowID: UUID { tabs.windowID }

    /// After the first frame: warms the first web view at once, then loads the per-site choices,
    /// the reader check, the rule lists and the saved tabs off the main thread. Returns the last
    /// session's selected tab when there is one and the user has not opened a page meanwhile;
    /// every other saved tab is in the list without a web view until it is opened.
    func start() async -> Tab? {
        guard !started else { return nil }
        started = true
        pool.warmUp()
        async let modes: Void = contentModes.load()
        async let zooms: Void = pageZooms.load()
        async let darkSites = darkPages.load()
        async let scripts: Void = readerScripts.prepare()
        async let cookieSites: Void = cookieBannerSites.load()
        async let cookieEngine: Void = cookieBanners.prepare()
        // Lookups take about 1 ms when the lists are compiled; a first launch compiles them in the
        // background for several seconds, and pages load meanwhile without them.
        Task { [blocker] in await blocker.prepare() }
        let restored = await tabs.restoreSession()
        _ = await (modes, zooms, scripts, cookieSites, cookieEngine)
        cookieBanners.storedSitesDidLoad()
        if await darkSites { pool.darkPagesSitesDidChange() }
        // Files of tabs gone for good, at background priority once launch has settled, and the data
        // of a profile whose deletion the app could not finish.
        Task(priority: .background) { [tabs, profileData] in
            await tabs.pruneFiles()
            if tabs.areProfilesKnown { await profileData.removeLeftovers(keeping: tabs.profiles.map(\.id)) }
            await AppWebsiteData.removeLeftoverProfileData()
        }
        // A restored page loads only with its rules attached: lookups of compiled lists take
        // about 1 ms, and an update keeps the previous lists attached while it compiles.
        if restored != nil { await blocker.firstRulesAttached() }
        return restored
    }

    /// Writes the tab list now. The pool saves each tab's page state on its own when the app
    /// resigns active.
    public func saveTabs() async {
        await tabs.flush()
    }

    /// Whether blocking is on for `url`'s site.
    func isBlockingEnabled(for url: URL?) -> Bool {
        blocker.isBlockingEnabled(for: url)
    }
}
#endif
