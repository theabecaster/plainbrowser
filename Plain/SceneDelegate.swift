import BrowserCore
import FeatureUI
import Foundation
import PerfSignposts
import ShellUI
import Storage
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
    /// Web links other apps opened before the browser was built.
    private var pendingLinks: [URL] = []

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        _ = database
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        if arguments.contains("-PlainPreviewEmptyTabCard") {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = DefaultBrowserCardPreviewController()
            window.makeKeyAndVisible()
            self.window = window
            return
        }
        #endif
        pendingLinks = Self.webLinks(options.urlContexts.map(\.url) + options.userActivities.compactMap(Self.webLink))
        // After the intro was seen this is one defaults read; no intro code runs. A link from
        // another app opens its page at once: the intro waits for the next launch.
        if pendingLinks.isEmpty, IntroGate.shouldShow(arguments: arguments) {
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
        introWindow = window
        LaunchFirstFrame.endAtNextFrame()
    }

    private func showBrowser(in windowScene: UIWindowScene) {
        browserShown = true
        let window = UIWindow(windowScene: windowScene)
        // Settings > Appearance from the first frame (the database is read later).
        AppAppearance.prepare(window)
        let savedWindow = (windowScene.session.userInfo?[Self.windowIDKey] as? String).flatMap(UUID.init(uuidString:))
        self.session = BrowserSession(
            database: { [database] in await database.value },
            tabStates: TabStateStore(directory: self.options.tabStateDirectory),
            windowID: savedWindow
        )
        let browser = BrowserViewController(session: self.session, data: addressBarData, sheets: sheets) { [weak self] in
            Signposts.signposter.endInterval(Signposts.launch, launchInterval)
            // Links that launched the app open once the launch focus is done, so the search
            // field never comes up over their page.
            self?.openPendingLinks()
        }
        // The navigation controller gives the page buttons a place in the system's vertical bar
        // (iPhone Duo). Its navigation bar stays hidden; the browser shows its toolbar only where
        // that bar is vertical.
        let navigation = UINavigationController(rootViewController: browser)
        navigation.setNavigationBarHidden(true, animated: false)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
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

    // MARK: Links from other apps

    /// Web links another app opens in Plain (as the default browser) while it runs.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        open(Self.webLinks(URLContexts.map(\.url)), in: scene)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        open(Self.webLinks([Self.webLink(userActivity)].compactMap { $0 }), in: scene)
    }

    /// Opens `links` in the browser; while the intro is up it gives way, unseen, so the page shows
    /// now and the intro comes back on the next launch.
    private func open(_ links: [URL], in scene: UIScene) {
        guard !links.isEmpty else { return }
        pendingLinks += links
        if browser?.viewIfLoaded?.window != nil {
            openPendingLinks()
            return
        }
        guard let windowScene = scene as? UIWindowScene, introWindow != nil else { return }
        introWindow?.isHidden = true
        introWindow = nil
        showBrowser(in: windowScene)
    }

    private func openPendingLinks() {
        guard let browser, !pendingLinks.isEmpty else { return }
        let links = pendingLinks
        pendingLinks = []
        links.forEach(browser.open(externalURL:))
    }

    private static func webLink(_ activity: NSUserActivity) -> URL? {
        activity.activityType == NSUserActivityTypeBrowsingWeb ? activity.webpageURL : nil
    }

    private static func webLinks(_ urls: [URL]) -> [URL] {
        urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Final once the saved tabs are in; written each time so the next launch finds it.
        guard let session else { return }
        var info = scene.session.userInfo ?? [:]
        info[Self.windowIDKey] = session.windowID.uuidString
        scene.session.userInfo = info
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Nothing to save while the intro is up: the browser (and its engine) is not built yet.
        guard browserShown else { return }
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
        Task(priority: .userInitiated) {
            guard let database = await opening.value else { return }
            await data.attach(database)
            sheets.attach(database)
            browser.addressBarDataDidChange()
            // Pruning and SQLite upkeep, at most daily, at background priority after launch settles.
            database.scheduleDailyMaintenance()
        }
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

/// Where the database lives, and the test-only launch arguments.
private nonisolated struct LaunchOptions: Sendable {
    /// `-PlainInMemoryStore`: a fresh, empty database (UI tests). Debug builds only.
    var inMemory = false
    /// `-PlainSeedFavorites`: a few favorites, for screenshots. Debug builds only.
    var seedFavorites = false
    /// `-PlainSeedArchive`: a few archived tabs, for screenshots of the archive. Debug builds only.
    var seedArchive = false
    /// `-PlainTestStore`: a database and tab state on disk in a temporary folder that survives
    /// relaunches, for UI tests of session restore; `-PlainResetStore` empties it first. Release
    /// builds too: the perf tests start each launch from an empty session this way, on disk like the
    /// real store, and never read or write the user's own tabs. The reset only ever touches that
    /// temporary folder.
    var testStore = false
    var resetStore = false

    init(arguments: [String]) {
        testStore = arguments.contains("-PlainTestStore")
        resetStore = testStore && arguments.contains("-PlainResetStore")
        #if DEBUG
        inMemory = arguments.contains("-PlainInMemoryStore")
        seedFavorites = arguments.contains("-PlainSeedFavorites")
        seedArchive = arguments.contains("-PlainSeedArchive")
        #endif
        let temporary = FileManager.default.temporaryDirectory
        if testStore {
            directory = temporary.appending(path: "PlainUITestStore", directoryHint: .isDirectory)
        } else if inMemory {
            directory = temporary.appending(path: "Plain-\(UUID().uuidString)", directoryHint: .isDirectory)
        } else {
            directory = URL.applicationSupportDirectory.appending(path: "Plain", directoryHint: .isDirectory)
        }
    }

    /// The database's folder: Application Support/Plain, or a fresh temporary one for UI tests.
    let directory: URL

    /// Where tabs' history, scroll and sessionStorage are saved for relaunch, next to the database.
    /// A path only: nothing touches the disk until the first save.
    var tabStateDirectory: URL { directory.appending(path: "TabState", directoryHint: .isDirectory) }

    @concurrent func makeDatabase() async throws -> AppDatabase {
        if inMemory, !testStore { return try AppDatabase.inMemory() }
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
