import AppIntents
import BrowserCore
@testable import Plain
import PlainShared
import XCTest

/// Performs each App Intent inside the app and checks the command it hands the browser. The
/// scene's handler is swapped for a recorder for each test, then put back.
///
/// The host app is isolated: Smoke.xctestplan passes `-PlainInMemoryStore` to it, so it never
/// opens the owner's store, App Group, Spotlight or widgets (scripts/lib/check-isolation.zsh
/// checks the plan). Each test stops first if the host is not isolated.
@MainActor
final class IntentTests: XCTestCase {
    private var received: [PlainCommand] = []
    private var sceneHandler: ((PlainCommand) -> Void)?

    override func setUp() async throws {
        guard TestIsolation.isActive else {
            XCTFail("the host app is not isolated; Smoke.xctestplan must pass -PlainInMemoryStore")
            throw XCTSkip("not isolated")
        }
        sceneHandler = CommandInbox.shared.handler
        received = []
        CommandInbox.shared.handler = { [unowned self] in self.received.append($0) }
    }

    override func tearDown() async throws {
        CommandInbox.shared.handler = sceneHandler
    }

    func testSearchSendsTheQuery() async throws {
        let intent = SearchIntent()
        intent.criteria = StringSearchCriteria(term: "  liquid glass  ")
        _ = try await intent.perform()
        XCTAssertEqual(received, [.search("liquid glass")])
    }

    func testAnEmptySearchFocusesTheField() async throws {
        let intent = SearchIntent()
        intent.criteria = StringSearchCriteria(term: " ")
        _ = try await intent.perform()
        XCTAssertEqual(received, [.focusSearch])
    }

    func testOpenURLFixesUpABareAddress() async throws {
        _ = try await OpenPageIntent(url: URL(string: "apple.com")!).perform()
        _ = try await OpenPageIntent(url: URL(string: "https://example.com/a")!).perform()
        XCTAssertEqual(received, [.open(URL(string: "https://apple.com")!), .open(URL(string: "https://example.com/a")!)])
    }

    func testOpenURLRefusesWhatIsNotAPage() async throws {
        do {
            _ = try await OpenPageIntent(url: URL(string: "two words")!).perform()
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(received, [])
    }

    func testTabIntents() async throws {
        _ = try await NewTabIntent().perform()
        _ = try await NewPrivateTabIntent().perform()
        _ = try await ShowTabsIntent().perform()
        XCTAssertEqual(received, [.newTab, .newPrivateTab, .showTabs])
    }

    func testControlsOpenSearchOrAPrivateTab() async throws {
        _ = try await OpenPlainIntent(target: .search).perform()
        _ = try await OpenPlainIntent(target: .privateTab).perform()
        XCTAssertEqual(received, [.focusSearch, .newPrivateTab])
    }

    func testOpenFavoriteAndItsQuery() async throws {
        let favorites = [
            SharedFavorite(url: URL(string: "https://en.wikipedia.org")!, title: "Wikipedia"),
            SharedFavorite(url: URL(string: "https://github.com")!, title: "GitHub"),
        ]
        var query = FavoriteQuery()
        query.favorites = { favorites }
        let suggested = try await query.suggestedEntities()
        let matching = try await query.entities(matching: "hub")
        let byID = try await query.entities(for: ["https://github.com"])
        XCTAssertEqual(suggested.map(\.title), ["Wikipedia", "GitHub"])
        XCTAssertEqual(matching.map(\.title), ["GitHub"])
        XCTAssertEqual(byID.map(\.title), ["GitHub"])
        let github = try XCTUnwrap(matching.first)
        _ = try await OpenFavoriteIntent(target: github).perform()
        XCTAssertEqual(received, [.open(URL(string: "https://github.com")!)])
    }

    func testEveryShortcutNamesTheApp() {
        XCTAssertEqual(PlainShortcuts.appShortcuts.count, 6)
    }
}
