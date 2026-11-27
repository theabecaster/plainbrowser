import BrowserCore
import FeatureUI
import Foundation
import PerfSignposts
import PlainShared
import ShellUI
import Storage
import SystemSync
import UIKit
import WebEngine

/// What every window of the app shares, made once per process: the database (opened off the main
/// thread as the first scene connects, so launch never waits on disk), the app's stores
/// (`AppStores`: the tabs of every window, each profile's history database, the per-site
/// choices, content blocking) and the system sync. Each window keeps its own address bar data
/// and sheets, since each shows its own profile; a saved setting reaches all of them. Per-window
/// browser state, docs/plan.md, section 6.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    /// makeDatabase and seed are @concurrent: the disk work runs on the global executor.
    private(set) lazy var database: Task<AppDatabase?, Never> = { [options] in
        Task(priority: .userInitiated) {
            guard let database = try? await options.makeDatabase() else { return nil }
            await options.seed(database)
            return database
        }
    }()
    private(set) lazy var stores: AppStores = {
        let stores = AppStores(database: { [database] in await database.value }, profileData: options.profileData)
        // Windows whose scene is gone for good join a window that has one (`AppTabs`).
        stores.tabs.sessionWindowIDs = {
            Set(SceneState.valuesOfOpenSessions(forKey: Windows.windowIDKey).compactMap(UUID.init(uuidString:)))
        }
        return stores
    }()
    /// The database once open, with the app-wide upkeep started once.
    private var opening: Task<AppDatabase?, Never>?
    /// Spotlight, the App Group file and widget timelines, following the favorites: one for the
    /// app, whatever its windows.
    private(set) var systemSync: SystemSync?
    private var systemSyncTask: Task<Void, Never>?
    /// The favorites the sync follows: the profile of the window the user was in last.
    private var profileFavorites: AppDatabase?
    private weak var followedFavorites: AppDatabase?
    /// Every window's address bar data, so a setting saved in one window reaches the others.
    private let addressBars = NSHashTable<LiveAddressBarData>.weakObjects()

    /// The database once it is open; every window waits for the same opening. The daily upkeep and
    /// the system sync start once. Nil when it could not open.
    func openedDatabase() async -> AppDatabase? {
        if let opening { return await opening.value }
        let databaseTask = database
        let task = Task(priority: .userInitiated) { [weak self] () -> AppDatabase? in
            guard let database = await databaseTask.value else { return nil }
            // Pruning and SQLite upkeep, at most daily, at background priority after launch settles.
            database.scheduleDailyMaintenance()
            self?.startSystemSync(database)
            return database
        }
        opening = task
        return await task.value
    }

    /// A window's address bar data, to keep its settings in step with the others'.
    func register(_ data: LiveAddressBarData) {
        addressBars.add(data)
    }

    /// A window saved `settings`: every other window's address bar uses them too.
    func settingsSaved(_ settings: BrowserSettings, by data: LiveAddressBarData) {
        for other in addressBars.allObjects where other !== data { other.apply(settings) }
    }

    /// Spotlight, the widgets' favorites file and their timelines follow the favorites from here
    /// on, at background priority once launch has settled (`FixedChoices.systemSyncLaunchDelay`).
    /// Clear History and Data empties Spotlight through it. Once per app.
    private func startSystemSync(_ database: AppDatabase) {
        guard systemSync == nil else { return }
        // An isolated test run gets its own folder and a Spotlight, widgets and Shortcuts that
        // keep nothing (`SystemSync.live`, TestIsolation).
        let sync = SystemSync.live {
            // "Open <favorite> in Plain" learns the new names.
            PlainShortcuts.updateAppShortcutParameters()
        }
        systemSync = sync
        followFavorites(of: profileFavorites ?? database, after: FixedChoices.systemSyncLaunchDelay)
    }

    /// Spotlight, the widgets and Shortcuts offer the favorites of the profile of the window the
    /// user moved to last (docs/decisions.md, "Profiles, no tab groups"): the sync follows that
    /// profile's database from here on.
    func followFavorites(of database: AppDatabase, after delay: Duration = .zero) {
        guard let sync = systemSync else {
            profileFavorites = database
            return
        }
        guard database !== followedFavorites else { return }
        followedFavorites = database
        systemSyncTask?.cancel()
        systemSyncTask = Task.detached(priority: .background) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await sync.follow(database)
        }
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let services = AppServices.shared
    private var options: LaunchOptions { services.options }
    /// The engine: pool, the window's tabs and the reader. Made when the scene connects, for the
    /// window the scene showed last time.
    private var session: BrowserSession!
    /// The window's address bar data: its profile's history and favorites, the app's settings.
    private let addressBarData = LiveAddressBarData()
    /// Settings, History and the favorites editor. A saved setting goes straight to the address
    /// bar, so the next search uses it, and to every other window's.
    private lazy var sheets = FeatureSheets(addressBar: addressBarData)

    /// The first-run intro's window, above the browser's, only while the intro is up.
    private var introWindow: UIWindow?
    /// The browser was built (on launch, or when the intro finished).
    private var browserShown = false
    private weak var browser: BrowserViewController?
    /// What the system asked for before the browser could do it: web links from other apps,
    /// widget links, App Intents, Spotlight results and Handoff (docs/research/system-integration.md).
    private var pendingCommands: [PlainCommand] = []
    /// The address bar has the saved search engine, so a search goes to the right engine.
    private var addressBarReady = false
    /// A new window was asked for ("Open in New Window"): its page, or nil for the start page, and
    /// whether it is private. Nil when the scene was not made for that.
    private var newWindowRequest: (url: URL?, isPrivate: Bool)?
    /// When the scene last went to the background: a long absence opens a fresh search on return.
    private var leftAt: Date?
    private var currentMemory: LaunchMemory?
    /// The launch splash, from the scene connecting until it is gone (a cold launch's first
    /// scene only; docs/state-rules.md, "Launch splash").
    private var launchSplash: LaunchSplash?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // A window a test run opened never comes back in the owner's app.
        if SceneState.isTestSession(session) {
            SceneState.destroy(session)
            return
        }
        newWindowRequest = options.userActivities.lazy.compactMap(Windows.request(in:)).first
        // A window an isolated test run asks for is marked, so the owner never sees it.
        SceneState.sessionDidConnect(session, isNewWindow: newWindowRequest != nil)
        _ = services.database
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        if arguments.contains("-PlainPreviewEmptyTabCard") {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = DefaultBrowserCardPreviewController()
            window.makeKeyAndVisible()
            TestIsolationMarker.install(in: window)
            self.window = window
            return
        }
        #endif
        pendingCommands = Self.commands(urls: options.urlContexts.map(\.url), activities: Array(options.userActivities))
        // App Intents run in this process; their commands come to the window that connected or
        // became active last (waiting ones arrive now).
        takeCommandInbox(in: windowScene)
        // The launch splash, if this launch has one: its pictures and shaders start off the main
        // thread now, while the browser is built. A link from another app (or a widget, a
        // shortcut) and a new window get none.
        launchSplash = LaunchSplash(
            scene: windowScene, arguments: arguments, launchedForCommand: !pendingCommands.isEmpty,
            isNewWindow: newWindowRequest != nil
        )
        launchSplash?.onEnd = { [weak self] in self?.launchSplash = nil }
        // After the intro was seen this is one defaults read; no intro code runs. A link from
        // another app (or a widget, a shortcut) opens at once: the intro waits for the next launch.
        // So does a new window.
        if pendingCommands.isEmpty, newWindowRequest == nil, IntroGate.shouldShow(arguments: arguments) {
            showIntro(in: windowScene)
        } else {
            showBrowser(in: windowScene)
        }
        // Over whichever came up, in the same first frame: the app under it is whole and takes
        // every touch.
        launchSplash?.show { [weak self] in (self?.introWindow ?? self?.window)?.rootViewController?.view }
    }

    /// The intro in its own window. On finish the browser comes up underneath (its search field
    /// takes focus and the keyboard rises) while the intro dissolves off the top.
    private func showIntro(in windowScene: UIWindowScene) {
        let intro = IntroViewController()
        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .normal + 1
        AppAppearance.prepare(window)
        window.rootViewController = intro
        intro.onFinish = { [weak self, weak intro] in
            guard let self else { return }
            self.showBrowser(in: windowScene)
            intro?.dissolve { [weak self] in
                self?.introWindow?.isHidden = true
                self?.introWindow = nil
            }
        }
        // Under the launch splash the mark waits to assemble until the dive opens onto it.
        if let launchSplash {
            intro.waitsForLaunchSplash = true
            launchSplash.onOpening = { [weak intro] in intro?.launchSplashIsOpening() }
        }
        window.makeKeyAndVisible()
        TestIsolationMarker.install(in: window)
        introWindow = window
        LaunchFirstFrame.endAtNextFrame()
    }

    private func showBrowser(in windowScene: UIWindowScene) {
        browserShown = true
        let window = UIWindow(windowScene: windowScene)
        // Settings > Appearance from the first frame (the database is read later).
        AppAppearance.prepare(window)
        let savedWindow = Self.savedWindowID(of: windowScene.session)
        // First, so the last tab's picture decodes off the main thread while the browser is built.
        let launch = launchPlan(for: savedWindow)
        self.session = BrowserSession(
            database: { [database = services.database] in await database.value },
            stores: services.stores,
            tabStates: TabStateStore(directory: self.options.tabStateDirectory),
            // A scene the system made new shows the window whose page the first frame shows; one
            // asked for by Open in New Window gets an empty window of its own.
            windowID: savedWindow ?? launch.hint?.windowID, isNewWindow: newWindowRequest != nil,
            thumbnailDirectory: self.options.thumbnailDirectory
        )
        // Known at once, so the window's id survives even a scene that never goes inactive.
        SceneState.set(session.windowID.uuidString, forKey: Windows.windowIDKey, in: windowScene.session)
        services.register(addressBarData)
        sheets.settingsSaved = { [services, addressBarData] settings in
            services.settingsSaved(settings, by: addressBarData)
        }
        // Read when a clear runs: the sync starts once the database is open.
        sheets.didClearBrowsingData = { [services] in await services.systemSync?.browsingDataCleared() }
        let browser = BrowserViewController(
            session: self.session, data: addressBarData, sheets: sheets, launch: launch
        ) { [weak self] in
            // The process's launch ends once: a later window's first screen is not a launch.
            if !LaunchFirstFrame.launchEnded {
                LaunchFirstFrame.launchEnded = true
                Signposts.signposter.endInterval(Signposts.launch, launchInterval, "\(String(describing: launch.opening))")
            }
            // Links that launched the app open once the launch focus is done, so the search
            // field never comes up over their page. A new window's page opens the same way.
            self?.openNewWindowRequest()
            self?.performPendingCommands()
        }
        // The navigation controller gives the page buttons a place in the system's vertical bar
        // (iPhone Duo). Its navigation bar stays hidden; the browser shows its toolbar only where
        // that bar is vertical.
        // Under the launch splash the field has focus but its keyboard waits for the dive. Before
        // the window shows: the field takes focus as the view appears.
        if let launchSplash {
            browser.holdLaunchKeyboard()
            launchSplash.onOpening = { [weak browser] in browser?.releaseLaunchKeyboard() }
        }
        let navigation = UINavigationController(rootViewController: browser)
        navigation.setNavigationBarHidden(true, animated: false)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        TestIsolationMarker.install(in: window)
        self.window = window
        self.browser = browser
        browser.onProfileDatabaseChange = { [services] database in services.followFavorites(of: database) }
        LaunchFirstFrame.endAtNextFrame()
        attachDatabase(to: browser)
        #if DEBUG
        // `-PlainOpen <url>,<url>` opens pages after launch, `-PlainSplit` puts the last one in a
        // split's other pane, `-PlainTabLayout above|left|right` sets Tab Layout and `-PlainSidebar
        // rail|expanded|hidden` the sidebar's state (neither saved): screenshots of Duo states the
        // simulator reaches only through Device Hub.
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        // A window made by Open in New Window shows its own page, not the launch's.
        guard newWindowRequest == nil else { return }
        let pages = value(after: "-PlainOpen")?.split(separator: ",").compactMap { URL(string: String($0)) } ?? []
        browser.debugSetUp(
            open: pages, split: arguments.contains("-PlainSplit"), tabLayout: value(after: "-PlainTabLayout"),
            sidebar: value(after: "-PlainSidebar")
        )
        browser.debugSidePane(value(after: "-PlainSidePane"), find: value(after: "-PlainFind"))
        browser.debugNewWindow(value(after: "-PlainNewWindow"))
        #endif
    }

    // MARK: Launch and return (docs/state-rules.md, "Launch and return")

    /// What this window remembers for the next launch, in `TestIsolation.defaults` (an isolated
    /// run's own suite, emptied by an in-memory run and by `-PlainResetStore`). One per window, so
    /// its picture writes stay in order.
    private func launchMemory(for windowID: UUID?) -> LaunchMemory {
        if let memory = currentMemory, memory.windowID == windowID { return memory }
        let memory = LaunchMemory(directory: options.launchDirectory, windowID: windowID)
        currentMemory = memory
        return memory
    }

    /// The first frame's screen: search with no last tab or with a link,
    /// widget, intent or Spotlight command to do; else the last tab,
    /// or a fresh search over it after a long time away. Its picture starts decoding now.
    /// A scene without a window id (the system made it new) takes the page any window left last
    /// only when it is the app's one scene, and then restores that window (`showBrowser`), so the
    /// picture and the restored tab agree; a further new scene starts with search.
    private func launchPlan(for windowID: UUID?) -> LaunchPlan {
        let onlyScene = UIApplication.shared.connectedScenes.count <= 1
        let memory = launchMemory(for: windowID)
        guard pendingCommands.isEmpty, newWindowRequest == nil, windowID != nil || onlyScene, let hint = memory.hint,
              // A known window that never left a hint gets no other window's page.
              windowID == nil || hint.windowID == windowID else { return .search }
        let opening = LaunchRules.opening(hint: hint, now: options.now)
        return LaunchPlan(opening: opening, hint: hint, picture: memory.startDecodingPicture(for: hint))
    }

    /// The window the user is in takes App Intents' commands.
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        takeCommandInbox(in: windowScene)
        launchSplash?.sceneDidBecomeActive()
    }

    private func takeCommandInbox(in windowScene: UIWindowScene) {
        CommandInbox.shared.handler = { [weak self, weak windowScene] command in
            guard let self, let windowScene else { return }
            self.receive([command], in: windowScene)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        guard let leftAt, let browser else { return }
        self.leftAt = nil
        browser.appDidReturn(awayFrom: leftAt, now: options.now)
    }

    // MARK: Links, intents, Spotlight and Handoff

    /// Web links another app opens in Plain (as the default browser), and widget links, while it
    /// runs.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        receive(Self.commands(urls: URLContexts.map(\.url), activities: []), in: scene)
    }

    /// A Spotlight result, or a page continued from another device.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        receive(Self.commands(urls: [], activities: [userActivity]), in: scene)
    }

    /// Does `commands` in the browser; while the intro is up it gives way, unseen, so the page
    /// shows now and the intro comes back on the next launch.
    private func receive(_ commands: [PlainCommand], in scene: UIScene) {
        guard !commands.isEmpty else { return }
        // A link always wins: the splash gives way at once.
        launchSplash?.end()
        pendingCommands += commands
        if browser?.viewIfLoaded?.window != nil {
            performPendingCommands()
            return
        }
        guard let windowScene = scene as? UIWindowScene, introWindow != nil else { return }
        introWindow?.isHidden = true
        introWindow = nil
        showBrowser(in: windowScene)
    }

    /// In order. A search waits (with what follows it) until the saved engine is in, so it never
    /// goes to the default engine by mistake on a cold launch.
    private func performPendingCommands() {
        guard let browser else { return }
        while let command = pendingCommands.first {
            if case .search = command, !addressBarReady { return }
            pendingCommands.removeFirst()
            browser.perform(command)
        }
    }

    /// A window made by "Open in New Window" opens its page (a private one in a private tab), or
    /// stays on its search when it was made empty.
    private func openNewWindowRequest() {
        guard let browser, let request = newWindowRequest else { return }
        newWindowRequest = nil
        guard let url = request.url else { return }
        browser.openInThisWindow(url, isPrivate: request.isPrivate)
    }

    private static func commands(urls: [URL], activities: [NSUserActivity]) -> [PlainCommand] {
        urls.compactMap(PlainLink.command(from:)) + activities.compactMap(SystemActivity.command(from:))
    }

    func sceneWillResignActive(_ scene: UIScene) {
        launchSplash?.sceneDidLeave()
        // Final once the saved tabs are in; written each time so the next launch finds it.
        guard let session else { return }
        SceneState.set(session.windowID.uuidString, forKey: Windows.windowIDKey, in: scene.session)
        // The page on screen and its picture, for the next launch's first frame.
        browser?.rememberForLaunch(in: launchMemory(for: session.windowID))
    }

    /// The scene's window id (`SceneState`: never the owner's scene state in an isolated run).
    private static func savedWindowID(of sceneSession: UISceneSession) -> UUID? {
        SceneState.string(forKey: Windows.windowIDKey, in: sceneSession).flatMap(UUID.init(uuidString:))
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Also a scene that goes to the background without ever becoming active (a launch the
        // system made in the background): its splash never played, and never will.
        launchSplash?.sceneDidLeave()
        // Nothing to save while the intro is up: the browser (and its engine) is not built yet.
        guard browserShown else { return }
        leftAt = Date()
        let data = addressBarData
        Task { await data.flush() }
        // The pool saves every tab's page state on its own (willResignActive); this writes the
        // tab list.
        guard let session else { return }
        Task { await session.saveTabs() }
    }

    /// The browser hears about the database once the app has handed it to the address bar and the
    /// sheets; searches that waited for the saved engine go then.
    private func attachDatabase(to browser: BrowserViewController) {
        let services = services
        let data = addressBarData
        let sheets = sheets
        let profiles = session?.profileData
        Task(priority: .userInitiated) { [weak self] in
            guard let database = await services.openedDatabase() else {
                self?.addressBarIsReady()
                return
            }
            await data.attach(database) { await profiles?.database(for: $0) }
            sheets.attach(database)
            browser.addressBarDataDidChange()
            TestIsolationMarker.storeIsReady()
            self?.addressBarIsReady()
        }
    }

    /// Searches that waited for the saved engine go now, if the browser is up.
    private func addressBarIsReady() {
        addressBarReady = true
        if browser?.viewIfLoaded?.window != nil { performPendingCommands() }
    }

    /// The system let the scene go (a window closed, or memory): its window stays in the app's
    /// tabs, so the scene comes back to it; the app delegate closes it if the session is discarded.
    /// Intents wait in the inbox for the next window.
    func sceneDidDisconnect(_ scene: UIScene) {
        launchSplash?.sceneDidLeave()
        CommandInbox.shared.handler = nil
        session?.sceneDidDisconnect()
    }
}

/// Ends the `launch.firstFrame` interval at the first display-link callback after the first window
/// became visible: the run loop turn that showed it is done and the main thread is running again. Once per process; later windows and scenes do nothing.
@MainActor
private enum LaunchFirstFrame {
    private static var pending = true
    /// The `launch` interval ended (the first window's screen was ready).
    static var launchEnded = false

    static func endAtNextFrame() {
        guard pending else { return }
        pending = false
        let link = CADisplayLink(target: Tick.shared, selector: #selector(Tick.fire(_:)))
        link.add(to: .main, forMode: .common)
    }

    @MainActor
    private final class Tick: NSObject {
        static let shared = Tick()

        @objc func fire(_ link: CADisplayLink) {
            link.invalidate()
            Signposts.signposter.endInterval(Signposts.launchFirstFrame, launchFirstFrameInterval)
        }
    }
}

/// Where the database lives, and the test-only launch arguments. The isolation arguments
/// (`TestIsolation`: `-PlainInMemoryStore`, `-PlainTestStore`, `-PlainResetStore`) work in every
/// configuration, so a Release perf run on the owner's phone uses throwaway state too. The seeds
/// are Debug only.
nonisolated struct LaunchOptions: Sendable {
    /// `-PlainInMemoryStore`: a fresh, empty database (UI tests).
    let inMemory: Bool
    /// `-PlainSeedFavorites`: a few favorites, for screenshots. Debug builds only.
    var seedFavorites = false
    /// `-PlainSeedArchive`: a few archived tabs, for screenshots of the archive. Debug builds only.
    var seedArchive = false
    /// `-PlainSeedHistory`: a few visited pages, for screenshots of the focused address bar.
    /// Debug builds only.
    var seedHistory = false
    /// `-PlainTestStore`: a database and tab state on disk in a temporary folder that survives
    /// relaunches, for UI tests of session restore; `-PlainResetStore` empties it first. The perf
    /// tests start each launch from an empty session this way, on disk like the real store. The
    /// reset only ever touches that temporary folder.
    let resetStore: Bool
    /// `-PlainAwayOffset <seconds>`: the clock the launch and return rules read runs this far
    /// ahead, so UI tests reach "a long time away" without waiting. Debug builds only.
    var awayOffset: TimeInterval = 0

    init(arguments: [String]) {
        #if DEBUG
        seedFavorites = arguments.contains("-PlainSeedFavorites")
        seedArchive = arguments.contains("-PlainSeedArchive")
        seedHistory = arguments.contains("-PlainSeedHistory")
        if let index = arguments.firstIndex(of: "-PlainAwayOffset"), arguments.indices.contains(index + 1) {
            awayOffset = TimeInterval(arguments[index + 1]) ?? 0
        }
        #endif
        inMemory = TestIsolation.mode == .inMemory
        resetStore = TestIsolation.resetRequested
        directory = TestIsolation.directory
            ?? URL.applicationSupportDirectory.appending(path: "Plain", directoryHint: .isDirectory)
    }

    /// The database's folder: Application Support/Plain, or a temporary one in an isolated run.
    let directory: URL

    /// Where tabs' history, scroll and sessionStorage are saved for relaunch, next to the database.
    /// A path only: nothing touches the disk until the first save.
    var tabStateDirectory: URL { directory.appending(path: "TabState", directoryHint: .isDirectory) }

    /// Where profiles other than Personal keep their history and favorites: beside the database,
    /// in memory for an in-memory run (the test folder for the test store). A path only.
    var profileData: ProfileDataLocation { ProfileDataLocation(directory: inMemory ? nil : directory) }

    /// The time the launch and return rules use (`-PlainAwayOffset` moves it ahead).
    var now: Date { Date().addingTimeInterval(awayOffset) }

    /// Where each window's launch picture lives: beside the thumbnails, in a folder of its own
    /// (thumbnail pruning only looks at the top level).
    var launchDirectory: URL {
        let thumbnails = thumbnailDirectory ?? URL.cachesDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)
        return thumbnails.appending(path: "Launch", directoryHint: .isDirectory)
    }

    /// Thumbnails next to a test database (nil: the pool's Caches/Thumbnails). Launch prunes
    /// thumbnails that no tab in the database names, so a test store must never share the user's.
    var thumbnailDirectory: URL? { TestIsolation.folder("Thumbnails") }

    @concurrent func makeDatabase() async throws -> AppDatabase {
        if inMemory { return try AppDatabase.inMemory() }
        if resetStore { try? FileManager.default.removeItem(at: directory) }
        return try await AppDatabase.open(
            at: directory.appending(path: "Plain.sqlite"), tabStateDirectory: tabStateDirectory
        )
    }

    @concurrent func seed(_ database: AppDatabase) async {
        if seedArchive {
            let pages: [(String, String, Double)] = [
                ("https://www.theverge.com/tech", "The Verge — Tech", 3),
                ("https://en.wikipedia.org/wiki/Liquid_glass", "Liquid glass — Wikipedia", 20),
                ("https://developer.apple.com/documentation/webkit", "WebKit | Apple Developer Documentation", 30),
                ("https://news.ycombinator.com/item?id=1", "Show HN: A plain browser", 50),
                ("https://www.nytimes.com/section/food", "Food — The New York Times", 80),
            ]
            for (address, title, hours) in pages {
                let date = Date().addingTimeInterval(-hours * 3600)
                let entry = TabEntry(url: URL(string: address), title: title, createdAt: date, lastActiveAt: date)
                database.tabSession.enqueue(.archive([entry], at: date))
            }
            await database.tabSession.flush()
        }
        if seedHistory {
            let pages: [(String, String, Double)] = [
                ("https://www.apple.com/iphone/", "iPhone - Apple", 1),
                ("https://arc.net/blog/farewell", "A farewell to Arc", 2),
                ("https://www.nytimes.com/section/food", "Food — The New York Times", 5),
                ("https://en.wikipedia.org/wiki/Liquid_glass", "Liquid glass — Wikipedia", 9),
                ("https://developer.apple.com/documentation/webkit", "WebKit | Apple Developer Documentation", 26),
            ]
            for (address, title, hours) in pages.reversed() {
                guard let url = URL(string: address) else { continue }
                await database.historyRecorder.record(
                    HistoryVisit(url: url, title: title, visitedAt: Date().addingTimeInterval(-hours * 3600), kind: .typed)
                )
            }
            await database.historyRecorder.flush()
        }
        guard seedFavorites else { return }
        let pages: [(String, String)] = [
            ("https://en.wikipedia.org", "Wikipedia"),
            ("https://news.ycombinator.com", "Hacker News"),
            ("https://github.com", "GitHub"),
            ("https://developer.apple.com", "Apple Developer"),
            ("https://www.theverge.com", "The Verge"),
        ]
        for (address, title) in pages {
            guard let url = URL(string: address) else { continue }
            _ = try? await database.addFavorite(url: url, title: title)
        }
    }
}

/// The safety net's app side: in an isolated test run every window carries a tiny, invisible
/// accessibility element (`TestIsolation.markerIdentifier`, value the mode). The UI tests look for
/// it right after each launch and stop at once when it is missing, so a build that ignored the
/// isolation arguments can't go on touching the owner's data. Nothing is added otherwise.
/// Once the database is open and migrated (on disk for the test store) and handed to the address
/// bar and the sheets, the value gains `TestIsolation.storeReadyValue`: a readiness signal the
/// tests read without driving any UI, so it holds in every layout.
@MainActor
enum TestIsolationMarker {
    private static let markers = NSHashTable<UIView>.weakObjects()
    private static var storeReady = false

    static func install(in window: UIWindow) {
        guard TestIsolation.isActive else { return }
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = TestIsolation.markerIdentifier
        marker.accessibilityLabel = "Test isolation"
        marker.accessibilityValue = value
        window.addSubview(marker)
        markers.add(marker)
    }

    /// The database is attached: every marker, now and later, says so.
    static func storeIsReady() {
        guard TestIsolation.isActive, !storeReady else { return }
        storeReady = true
        for marker in markers.allObjects { marker.accessibilityValue = value }
    }

    private static var value: String {
        let mode = TestIsolation.mode.rawValue
        return storeReady ? "\(mode) \(TestIsolation.storeReadyValue)" : mode
    }
}
