import XCTest

/// The sheets the shell presents: Settings (the engine change reaches the next search), History
/// (visits show and search finds them, a row opens its page) and favorites (added from the page
/// menu, shown above the keyboard, edited from the strip).
@MainActor
final class FeatureSheetTests: XCTestCase {
    private var server: TestServer!

    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["-PlainInMemoryStore"]
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        return app
    }

    private func go(_ app: XCUIApplication, to path: String, heading: String) {
        type(app, server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show")
    }

    /// Opens the address field when it is closed, then types `text`.
    private func type(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(text)
    }

    /// Opens the page menu from More (the glass bar, or the Duo's vertical bar) and picks `item`.
    private func pageMenu(_ app: XCUIApplication, pick item: String) {
        let more = app.buttons["more"]
        XCTAssertTrue(more.waitForExistence(timeout: 2))
        more.tap()
        let action = app.buttons[item]
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the page menu")
        action.tap()
    }

    func testSettingsEngineChangeReachesTheNextSearch() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")

        pageMenu(app, pick: "Settings…")
        let engineRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Search Engine'")).firstMatch
        XCTAssertTrue(engineRow.waitForExistence(timeout: 3))
        XCTAssertEqual(engineRow.label, "Search Engine, Google")
        engineRow.tap()
        let duck = app.buttons["DuckDuckGo"]
        XCTAssertTrue(duck.waitForExistence(timeout: 2))
        duck.tap()
        // Back to Settings. On the Duo the sheet's back button sits in the vertical bar.
        let back = app.otherElements["settingsSheet"].buttons["BackButton"]
        if back.exists { back.tap() } else { app.navigationBars["Search Engine"].buttons.firstMatch.tap() }
        XCTAssertTrue(app.buttons["Search Engine, DuckDuckGo"].waitForExistence(timeout: 2), "the row shows the new value")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 3))

        type(app, "plain browser test\n")
        let pill = app.buttons["addressPill"]
        let searched = NSPredicate { _, _ in (pill.value as? String)?.contains("duckduckgo.com") == true }
        wait(for: [XCTNSPredicateExpectation(predicate: searched, object: nil)], timeout: 5)
    }

    func testHistoryShowsVisitsSearchesAndOpens() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        go(app, to: "/b", heading: "Page B")

        // No wait for the 2 s history batch: History writes what is queued before it reads.
        pageMenu(app, pick: "History")
        let sheet = app.otherElements["historySheet"]
        XCTAssertTrue(sheet.staticTexts["Plain Test A"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Plain Test B"].exists)

        // The search field, or a Search button where the sheet's toolbar folds it away.
        if !sheet.searchFields.firstMatch.exists { sheet.buttons["Search"].tap() }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.tap()
        search.typeText("Test A")
        let gone = NSPredicate { _, _ in !sheet.staticTexts["Plain Test B"].exists }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 3)
        XCTAssertTrue(sheet.staticTexts["Plain Test A"].exists)
        sheet.staticTexts["Plain Test A"].tap()

        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["addressPill"].value as? String, "http://" + server.address("/a"))
    }

    func testAddedFavoriteShowsAboveTheKeyboardAndOpensTheEditor() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")

        pageMenu(app, pick: "Add to Favorites")
        app.buttons["addressPill"].tap()
        let tile = app.buttons["favorite.0"]
        XCTAssertTrue(tile.waitForExistence(timeout: 3), "the favorite should show above the keyboard")
        XCTAssertEqual(tile.label, "Plain Test A")

        tile.press(forDuration: 1)
        let edit = app.buttons["Edit Favorites"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Plain Test A"].exists)
        app.buttons["Done"].tap()
        // The field comes back, favorites and all.
        XCTAssertTrue(app.buttons["favorite.0"].waitForExistence(timeout: 3))

        // The page menu now offers the way back.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
        pageMenu(app, pick: "Remove from Favorites")
        app.buttons["addressPill"].tap()
        let removed = NSPredicate { _, _ in !app.buttons["favorite.0"].exists }
        wait(for: [XCTNSPredicateExpectation(predicate: removed, object: nil)], timeout: 3)
    }
}
