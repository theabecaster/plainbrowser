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
    private lazy var session = BrowserSession(
        database: { [database] in await database.value },
        tabStates: TabStateStore(directory: options.tabStateDirectory)
    )
    private let addressBarData = LiveAddressBarData()
    /// Settings, History and the favorites editor. A saved setting goes straight to the address
    /// bar, so the next search uses it.
    private lazy var sheets = FeatureSheets(addressBar: addressBarData)

    /// The first-run intro's window, above the browser's, only while the intro is up.
    private var introWindow: UIWindow?
    /// The browser was built (on launch, or when the intro finished).
    private var browserShown = false

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
        // After the intro was seen this is one defaults read; no intro code runs.
        if IntroGate.shouldShow(arguments: arguments) {
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
    }

    private func showBrowser(in windowScene: UIWindowScene) {
        browserShown = true
        let window = UIWindow(windowScene: windowScene)
        let browser = BrowserViewController(session: self.session, data: addressBarData, sheets: sheets) {
            Signposts.signposter.endInterval(Signposts.launch, launchInterval)
        }
        // The navigation controller gives the page buttons a place in the system's vertical bar
        // (iPhone Duo). Its navigation bar stays hidden; the browser shows its toolbar only where
        // that bar is vertical.
        let navigation = UINavigationController(rootViewController: browser)
        navigation.setNavigationBarHidden(true, animated: false)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        attachDatabase(to: browser)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Nothing to save while the intro is up: the browser (and its engine) is not built yet.
        guard browserShown else { return }
        let data = addressBarData
        Task { await data.flush() }
        // The pool saves every tab's page state on its own (willResignActive); this writes the
        // tab list.
        let session = session
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

/// Where the database lives, and the test-only launch arguments.
private nonisolated struct LaunchOptions: Sendable {
    /// `-PlainInMemoryStore`: a fresh, empty database (UI tests). Debug builds only.
    var inMemory = false
    /// `-PlainSeedFavorites`: a few favorites, for screenshots. Debug builds only.
    var seedFavorites = false
    /// `-PlainSeedArchive`: a few archived tabs, for screenshots of the archive. Debug builds only.
    var seedArchive = false
    /// `-PlainTestStore`: a database and tab state on disk in a temporary folder that survives
    /// relaunches, for UI tests of session restore; `-PlainResetStore` empties it first. Debug
    /// builds only.
    var testStore = false
    var resetStore = false

    init(arguments: [String]) {
        #if DEBUG
        inMemory = arguments.contains("-PlainInMemoryStore")
        seedFavorites = arguments.contains("-PlainSeedFavorites")
        seedArchive = arguments.contains("-PlainSeedArchive")
        testStore = arguments.contains("-PlainTestStore")
        resetStore = arguments.contains("-PlainResetStore")
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
