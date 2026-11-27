#if canImport(UIKit)
import ContentBlocking
import Foundation
import Reader
import Storage
import UIKit
import WebEngine

/// The engine side of one browser window, wired once: the web view pool, reader mode and the
/// window's view of the tab list. The app makes one per scene and hands it to
/// `BrowserViewController`. What all windows share (the tabs of every window, the per-site
/// choices, content blocking) lives in the app's `AppStores`.
///
/// Nothing here touches the disk or WebKit's processes at init. `start()` runs after the first
/// frame: warm-up, rule lists, the reader check and the last session's tab.
public final class BrowserSession {
    public let pool: WebViewPool
    let tabs: EngineTabs
    let stores: AppStores
    var blocker: ContentBlocker { stores.blocker }
    let reader = ReaderExtractor()
    let cookieBanners: CookieBanners
    /// Translate Page's engine (Apple's Translation framework; a stand-in in UI tests).
    let translator: any PageTranslator
    private let readerScripts: ReaderPageScripts
    /// Each profile's history database (Personal's is the main one): the app's, so two windows
    /// never open the same files twice.
    public var profileData: ProfileDatabases { stores.profileData }
    private var started = false

    /// - Parameters:
    ///   - database: the app's database once it has opened off the main thread.
    ///   - stores: what every window shares: the tabs, the per-site choices, content blocking.
    ///   - tabStates: where each tab's history, scroll and sessionStorage are saved for relaunch;
    ///     nil keeps them in memory only.
    ///   - windowID: the window this scene showed last time (`UISceneSession.userInfo`), so each
    ///     scene comes back to its own tabs and panes; nil for a new scene.
    ///   - isNewWindow: the scene was asked for as a new window: it gets an empty window of its own.
    ///   - thumbnailDirectory: where tab thumbnails live; nil for Caches/Thumbnails. A test store
    ///     passes its own, since launch prunes thumbnails no tab in the database names.
    ///   - profileData: where profiles other than Personal keep their history; nil keeps it in
    ///     memory.
    public init(
        database: @escaping DatabaseProvider, stores: AppStores, tabStates: TabStateStore?, windowID: UUID? = nil,
        isNewWindow: Bool = false, thumbnailDirectory: URL? = nil
    ) {
        self.stores = stores
        readerScripts = ReaderPageScripts(extractor: reader)
        cookieBanners = CookieBanners(store: stores.cookieBannerSites)
        #if DEBUG
        translator = ProcessInfo.processInfo.arguments.contains("-PlainTestTranslator")
            ? TestPageTranslator() : AppleTranslator()
        #else
        translator = AppleTranslator()
        #endif
        pool = WebViewPool(
            tabStates: tabStates,
            permissionStore: StorageSitePermissionStore(database: database),
            contentModes: stores.contentModes,
            contentRules: stores.blocker,
            pageScripts: ShellPageScripts([readerScripts, cookieBanners]),
            thumbnailDirectory: thumbnailDirectory,
            pageZooms: stores.pageZooms,
            darkPages: stores.darkPages,
            translator: translator
        )
        tabs = EngineTabs(
            pool: pool, app: stores.tabs, database: database, tabStates: tabStates, windowID: windowID,
            isNewWindow: isNewWindow
        )
        tabs.privateSessionDidEnd = { [cookieBanners] in cookieBanners.endPrivateSession() }
    }

    /// The window this scene shows. Keep it with the scene (`UISceneSession.userInfo`) so the next
    /// launch gives the scene the same tabs; it is final once the saved tabs are in.
    public var windowID: UUID { tabs.windowID }

    /// After the first frame: warms the first web view at once, then loads the per-site choices,
    /// the reader check, the rule lists and the saved tabs off the main thread (each shared load
    /// once per app). Returns the last session's selected tab when there is one and the user has
    /// not opened a page meanwhile; every other saved tab is in the list without a web view until
    /// it is opened.
    func start() async -> Tab? {
        guard !started else { return nil }
        started = true
        pool.warmUp()
        async let darkSites = stores.loadSiteChoices()
        async let scripts: Void = readerScripts.prepare()
        async let cookieEngine: Void = cookieBanners.prepare()
        // Lookups take about 1 ms when the lists are compiled; a first launch compiles them in the
        // background for several seconds, and pages load meanwhile without them.
        stores.prepareBlocker()
        let restored = await tabs.restoreSession()
        let anyDarkSites = await darkSites
        _ = await (scripts, cookieEngine)
        cookieBanners.storedSitesDidLoad()
        if anyDarkSites { pool.darkPagesSitesDidChange() }
        // Files of tabs gone for good, at background priority once launch has settled, and the data
        // of a profile whose deletion the app could not finish; once per app, since the tab list
        // and the profiles are the app's.
        if stores.claimFilePruning() {
            Task(priority: .background) { [tabs, profileData] in
                await tabs.pruneFiles()
                if tabs.areProfilesKnown {
                    // The live list is read when each cleanup decides, never a snapshot from before.
                    await profileData.removeLeftovers { tabs.profiles.map(\.id) }
                    await AppWebsiteData.removeLeftoverProfileData(keeping: tabs.profiles.map(\.id))
                }
            }
        }
        // A restored page loads only with its rules attached: lookups of compiled lists take
        // about 1 ms, and an update keeps the previous lists attached while it compiles.
        if restored != nil { await stores.blocker.firstRulesAttached() }
        return restored
    }

    /// The scene disconnected: its window stays in the app's tabs for when it comes back.
    public func sceneDidDisconnect() {
        tabs.releaseWindow()
    }

    /// Writes the tab list now. The pool saves each tab's page state on its own when the app
    /// resigns active.
    public func saveTabs() async {
        await tabs.flush()
    }

    /// Whether blocking is on for `url`'s site.
    func isBlockingEnabled(for url: URL?) -> Bool {
        stores.blocker.isBlockingEnabled(for: url)
    }
}
#endif
