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

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    /// The database, opened off the main thread as the scene connects, so launch never waits on
    /// disk. makeDatabase and seed are @concurrent: the disk work runs on the global executor.
    private lazy var database: Task<AppDatabase?, Never> = { [options] in
        Task(priority: .userInitiated) {
            guard let database = try? await options.makeDatabase() else { return nil }
            await options.seed(database)
            return database
        }
    }()
    /// The engine: pool, tabs, content blocking and reader. Its stores wait for the database.
    /// Made when the scene connects, for the window the scene showed last time.
    private var session: BrowserSession!
    /// Where a scene keeps its window's id across launches (per-window state, docs/plan.md,
    /// section 6): each scene comes back to its own tabs and panes.
    private static let windowIDKey = "plain.windowID"
    private let addressBarData = LiveAddressBarData()
    /// Settings, History and the favorites editor. A saved setting goes straight to the address
    /// bar, so the next search uses it.
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
    /// Spotlight, the App Group file and widget timelines, following the favorites; the task
    /// that follows them, cancelled with the scene.
    private var systemSync: SystemSync?
    private var systemSyncTask: Task<Void, Never>?
    /// When the scene last went to the background: a long absence opens a fresh search on return.
    private var leftAt: Date?
    private var currentMemory: LaunchMemory?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        _ = database
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
        // App Intents run in this process; their commands come here (waiting ones arrive now).
        CommandInbox.shared.handler = { [weak self, weak windowScene] command in
            guard let self, let windowScene else { return }
            self.receive([command], in: windowScene)
        }
        // After the intro was seen this is one defaults read; no intro code runs. A link from
        // another app (or a widget, a shortcut) opens at once: the intro waits for the next launch.
        if pendingCommands.isEmpty, IntroGate.shouldShow(arguments: arguments) {
            showIntro(in: windowScene)
        } else {
            showBrowser(in: windowScene)
        }
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
            database: { [database] in await database.value },
            tabStates: TabStateStore(directory: self.options.tabStateDirectory),
            // A scene the system made new shows the window whose page the first frame shows.
            windowID: savedWindow ?? launch.hint?.windowID,
            thumbnailDirectory: self.options.thumbnailDirectory
        )
        let browser = BrowserViewController(session: self.session, data: addressBarData, sheets: sheets, launch: launch) {
            [weak self] in
            Signposts.signposter.endInterval(Signposts.launch, launchInterval, "\(String(describing: launch.opening))")
            // Links that launched the app open once the launch focus is done, so the search
            // field never comes up over their page.
            self?.performPendingCommands()
        }
        // The navigation controller gives the page buttons a place in the system's vertical bar
        // (iPhone Duo). Its navigation bar stays hidden; the browser shows its toolbar only where
        // that bar is vertical.
        let navigation = UINavigationController(rootViewController: browser)
        navigation.setNavigationBarHidden(true, animated: false)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        TestIsolationMarker.install(in: window)
        self.window = window
        self.browser = browser
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
        let pages = value(after: "-PlainOpen")?.split(separator: ",").compactMap { URL(string: String($0)) } ?? []
        browser.debugSetUp(
            open: pages, split: arguments.contains("-PlainSplit"), tabLayout: value(after: "-PlainTabLayout"),
            sidebar: value(after: "-PlainSidebar")
        )
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
        guard pendingCommands.isEmpty, windowID != nil || onlyScene, let hint = memory.hint,
              // A known window that never left a hint gets no other window's page.
              windowID == nil || hint.windowID == windowID else { return .search }
        let opening = LaunchRules.opening(hint: hint, now: options.now)
        return LaunchPlan(opening: opening, hint: hint, picture: memory.startDecodingPicture(for: hint))
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

    private static func commands(urls: [URL], activities: [NSUserActivity]) -> [PlainCommand] {
        urls.compactMap(PlainLink.command(from:)) + activities.compactMap(SystemActivity.command(from:))
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Final once the saved tabs are in; written each time so the next launch finds it.
        guard let session else { return }
        SceneState.set(session.windowID.uuidString, forKey: Self.windowIDKey, in: scene.session)
        // The page on screen and its picture, for the next launch's first frame.
        browser?.rememberForLaunch(in: launchMemory(for: session.windowID))
    }

    /// The scene's window id (`SceneState`: never the owner's scene state in an isolated run).
    private static func savedWindowID(of sceneSession: UISceneSession) -> UUID? {
        SceneState.string(forKey: windowIDKey, in: sceneSession).flatMap(UUID.init(uuidString:))
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
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

    /// Hands the database to the address bar and the sheets once it is open.
    private func attachDatabase(to browser: BrowserViewController) {
        let data = addressBarData
        let sheets = sheets
        let opening = database
        Task(priority: .userInitiated) { [weak self] in
            guard let database = await opening.value else {
                self?.addressBarIsReady()
                return
            }
            await data.attach(database)
            sheets.attach(database)
            browser.addressBarDataDidChange()
            self?.addressBarIsReady()
            // Pruning and SQLite upkeep, at most daily, at background priority after launch settles.
            database.scheduleDailyMaintenance()
            self?.startSystemSync(database)
        }
    }

    /// Searches that waited for the saved engine go now, if the browser is up.
    private func addressBarIsReady() {
        addressBarReady = true
        if browser?.viewIfLoaded?.window != nil { performPendingCommands() }
    }

    /// Spotlight, the widgets' favorites file and their timelines follow the favorites from here
    /// on, at background priority once launch has settled (`FixedChoices.systemSyncLaunchDelay`).
    /// Clear History and Data empties Spotlight through it.
    private func startSystemSync(_ database: AppDatabase) {
        guard systemSync == nil else { return }
        let sync = SystemSync(
            file: SharedFavoritesFile.shared,
            indexed: AppGroup.containerURL.map { SharedFavoritesFile(url: $0.appending(path: "spotlight.json")) },
            index: CoreSpotlightIndex(), widgets: WidgetCenterReloader()
        ) {
            // "Open <favorite> in Plain" learns the new names.
            PlainShortcuts.updateAppShortcutParameters()
        }
        systemSync = sync
        sheets.didClearBrowsingData = { await sync.browsingDataCleared() }
        systemSyncTask = Task.detached(priority: .background) {
            try? await Task.sleep(for: FixedChoices.systemSyncLaunchDelay)
            guard !Task.isCancelled else { return }
            await sync.follow(database)
        }
    }

    /// The scene is gone: intents wait in the inbox for the next one, and the sync stops.
    func sceneDidDisconnect(_ scene: UIScene) {
        CommandInbox.shared.handler = nil
        systemSyncTask?.cancel()
        systemSyncTask = nil
    }
}

/// Ends the `launch.firstFrame` interval at the first display-link callback after the first window
/// became visible: the run loop turn that showed it is done and the main thread is running again. Once per process; later windows and scenes do nothing.
@MainActor
private enum LaunchFirstFrame {
    private static var pending = true

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
private nonisolated struct LaunchOptions: Sendable {
    /// `-PlainInMemoryStore`: a fresh, empty database (UI tests).
    let inMemory: Bool
    /// `-PlainSeedFavorites`: a few favorites, for screenshots. Debug builds only.
    var seedFavorites = false
    /// `-PlainSeedArchive`: a few archived tabs, for screenshots of the archive. Debug builds only.
    var seedArchive = false
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
@MainActor
private enum TestIsolationMarker {
    static func install(in window: UIWindow) {
        guard TestIsolation.isActive else { return }
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = TestIsolation.markerIdentifier
        marker.accessibilityLabel = "Test isolation"
        marker.accessibilityValue = TestIsolation.mode.rawValue
        window.addSubview(marker)
    }
}
