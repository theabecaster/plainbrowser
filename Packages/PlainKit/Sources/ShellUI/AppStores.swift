#if canImport(UIKit)
import ContentBlocking
import Foundation
import Storage

/// What every window of the app shares (per-window browser state with app-wide stores,
/// docs/plan.md, section 6): the tabs in every window, the per-site choices (desktop or mobile,
/// zoom, dark pages, cookie banners, blocking off) and the content blocker. The app makes one;
/// each scene's `BrowserSession` uses it, so a choice made in one window holds in the others and
/// two windows never write over each other's tabs.
///
/// Each store loads once, off the main thread, for the first window that starts.
public final class AppStores {
    public let tabs: AppTabs
    let contentModes: StorageSiteContentModeStore
    let pageZooms: StorageSitePageZoomStore
    let darkPages: StoragePageAppearanceStore
    let cookieBannerSites: StorageSiteCookieBannersStore
    let blocker: ContentBlocker
    /// Each profile's history database (Personal's is the main one), opened once for every window.
    public let profileData: ProfileDatabases
    private var loading: Task<Bool, Never>?
    private var preparingBlocker: Task<Void, Never>?
    private var didPruneFiles = false

    /// - Parameter profileData: where profiles other than Personal keep their history (the app
    ///   decides it from the test isolation: in memory for an isolated in-memory run).
    public init(database: @escaping DatabaseProvider, profileData: ProfileDataLocation) {
        tabs = AppTabs(database: database)
        self.profileData = ProfileDatabases(main: database, location: profileData)
        contentModes = StorageSiteContentModeStore(database: database)
        pageZooms = StorageSitePageZoomStore(database: database)
        darkPages = StoragePageAppearanceStore(database: database)
        cookieBannerSites = StorageSiteCookieBannersStore(database: database)
        blocker = ContentBlocker(allowListStore: StorageSiteAllowListStore(database: database))
    }

    /// Loads the per-site choices once; later windows wait for the same load. Returns whether Dark
    /// Pages' policy changed from its launch copy (the pools then update their pages).
    func loadSiteChoices() async -> Bool {
        if let loading { return await loading.value }
        let task = Task { [contentModes, pageZooms, darkPages, cookieBannerSites] in
            async let modes: Void = contentModes.load()
            async let zooms: Void = pageZooms.load()
            async let darkSites = darkPages.load()
            async let cookieSites: Void = cookieBannerSites.load()
            _ = await (modes, zooms, cookieSites)
            return await darkSites
        }
        loading = task
        return await task.value
    }

    /// Compiles or looks up the rule lists once, in the background: about 1 ms when compiled, a
    /// first launch compiles them for several seconds while pages load without them.
    func prepareBlocker() {
        guard preparingBlocker == nil else { return }
        preparingBlocker = Task { [blocker] in _ = await blocker.prepare() }
    }

    /// Whether the files of gone tabs were already pruned in this process (once is enough: the
    /// tab store is the app's).
    func claimFilePruning() -> Bool {
        guard !didPruneFiles else { return false }
        didPruneFiles = true
        return true
    }
}
#endif
