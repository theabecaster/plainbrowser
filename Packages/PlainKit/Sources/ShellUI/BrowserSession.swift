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
    private let readerScripts: ReaderPageScripts
    private let contentModes: StorageSiteContentModeStore
    private let pageZooms: StorageSitePageZoomStore
    private let darkPages: StorageSiteDarkPagesStore
    private let database: DatabaseProvider
    private var started = false

    /// - Parameters:
    ///   - database: the app's database once it has opened off the main thread.
    ///   - tabStates: where each tab's history, scroll and sessionStorage are saved for relaunch;
    ///     nil keeps them in memory only.
    ///   - windowID: the window this scene showed last time (`UISceneSession.userInfo`), so each
    ///     scene comes back to its own tabs and panes; nil for a new scene.
    public init(database: @escaping DatabaseProvider, tabStates: TabStateStore?, windowID: UUID? = nil) {
        self.database = database
        contentModes = StorageSiteContentModeStore(database: database)
        pageZooms = StorageSitePageZoomStore(database: database)
        darkPages = StorageSiteDarkPagesStore(database: database)
        blocker = ContentBlocker(allowListStore: StorageSiteAllowListStore(database: database))
        readerScripts = ReaderPageScripts(extractor: reader)
        pool = WebViewPool(
            tabStates: tabStates,
            permissionStore: StorageSitePermissionStore(database: database),
            contentModes: contentModes,
            contentRules: blocker,
            pageScripts: readerScripts,
            pageZooms: pageZooms,
            darkPages: darkPages
        )
        tabs = EngineTabs(pool: pool, database: database, tabStates: tabStates, windowID: windowID)
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
        // Lookups take about 1 ms when the lists are compiled; a first launch compiles them in the
        // background for several seconds, and pages load meanwhile without them.
        Task { [blocker] in await blocker.prepare() }
        let restored = await tabs.restoreSession()
        _ = await (modes, zooms, scripts)
        if await darkSites { pool.darkPagesSitesDidChange() }
        // Files of tabs gone for good, at background priority once launch has settled.
        Task(priority: .background) { [tabs] in await tabs.pruneFiles() }
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
