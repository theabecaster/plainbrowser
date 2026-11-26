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
    let tabs: TabStore
    let blocker: ContentBlocker
    let reader = ReaderExtractor()
    private let readerScripts: ReaderPageScripts
    private let contentModes: StorageSiteContentModeStore
    private let database: DatabaseProvider
    private var started = false

    /// - Parameters:
    ///   - database: the app's database once it has opened off the main thread.
    ///   - tabStates: where each tab's history, scroll and sessionStorage are saved for relaunch;
    ///     nil keeps them in memory only.
    public init(database: @escaping DatabaseProvider, tabStates: TabStateStore?) {
        self.database = database
        contentModes = StorageSiteContentModeStore(database: database)
        blocker = ContentBlocker(allowListStore: StorageSiteAllowListStore(database: database))
        readerScripts = ReaderPageScripts(extractor: reader)
        pool = WebViewPool(
            tabStates: tabStates,
            permissionStore: StorageSitePermissionStore(database: database),
            contentModes: contentModes,
            contentRules: blocker,
            pageScripts: readerScripts
        )
        tabs = TabStore(pool: pool, database: database, tabStates: tabStates)
    }

    /// After the first frame: warms the first web view at once, then loads the per-site choices,
    /// the reader check and the rule lists off the main thread. Returns the last session's tab
    /// when there is one and the user has not opened a page meanwhile.
    func start() async -> Tab? {
        guard !started else { return nil }
        started = true
        pool.warmUp()
        async let modes: Void = contentModes.load()
        async let scripts: Void = readerScripts.prepare()
        // Lookups take about 1 ms when the lists are compiled; a first launch compiles them in the
        // background for several seconds, and pages load meanwhile without them.
        Task { [blocker] in await blocker.prepare() }
        let restored = await tabs.restoreLastTab()
        _ = await (modes, scripts)
        // A restored page loads only with its rules attached: lookups of compiled lists take
        // about 1 ms, and an update keeps the previous lists attached while it compiles.
        if restored != nil { await blocker.firstRulesAttached() }
        // Files of tabs that never got a row (a crash between the two writes).
        Task { [database] in try? await database()?.removeOrphanedTabStates() }
        return restored
    }

    /// Writes the tabs' rows. The pool saves their state on its own when the app resigns active.
    public func saveTabs() {
        tabs.saveAll()
    }

    /// Whether blocking is on for `url`'s site.
    func isBlockingEnabled(for url: URL?) -> Bool {
        blocker.isBlockingEnabled(for: url)
    }
}
#endif
