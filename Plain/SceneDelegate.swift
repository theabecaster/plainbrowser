import Foundation
import PerfSignposts
import ShellUI
import Storage
import UIKit
import WebEngine

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let pool = WebViewPool()
    private let addressBarData = LiveAddressBarData()
    /// Settings, History and the favorites editor. A saved setting goes straight to the address
    /// bar, so the next search uses it.
    private lazy var sheets = FeatureSheets(addressBar: addressBarData)

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let browser = BrowserViewController(pool: pool, data: addressBarData, sheets: sheets) {
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
        openDatabase(then: browser)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        let data = addressBarData
        Task { await data.flush() }
    }

    /// Opens the database off the main thread, so launch never waits on disk, then hands it to the
    /// address bar.
    private func openDatabase(then browser: BrowserViewController) {
        let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
        let data = addressBarData
        let sheets = sheets
        Task(priority: .userInitiated) {
            // makeDatabase and seed are @concurrent: the disk work runs on the global executor.
            guard let database = try? await options.makeDatabase() else { return }
            await options.seed(database)
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

    init(arguments: [String]) {
        #if DEBUG
        inMemory = arguments.contains("-PlainInMemoryStore")
        seedFavorites = arguments.contains("-PlainSeedFavorites")
        #endif
    }

    @concurrent func makeDatabase() async throws -> AppDatabase {
        if inMemory { return try AppDatabase.inMemory() }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return try await AppDatabase.open(at: support.appending(path: "Plain/Plain.sqlite"))
    }

    @concurrent func seed(_ database: AppDatabase) async {
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
