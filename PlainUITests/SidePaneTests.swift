import XCTest

/// The Duo's inner screen: the side pane (Reader, Find, History beside the page) and windows
/// (Open in New Window, New Window, switching).
///
/// They need the iPhone Duo simulator unfolded (`scripts/duo-fold.sh <sim> Open`). Elsewhere (an
/// iPhone, the Duo's outer screen) they skip. Every window a test opens is a scene of the isolated
/// run: the app marks it, and a normal launch removes it (`SceneState.isTestSession`).
@MainActor
final class SidePaneTests: XCTestCase {
    private var server: TestServer!

    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication.isolated()
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        let width = app.windows.firstMatch.frame.width
        try XCTSkipUnless(width >= 600, "needs the Duo's inner screen (window is \(Int(width)) pt wide)")
        return app
    }

    private func go(_ app: XCUIApplication, to path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].firstMatch.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show")
    }

    /// More, then `item`.
    private func more(_ app: XCUIApplication, pick item: String, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["more"].firstMatch.tap()
        let action = app.buttons[item]
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in More", file: file, line: line)
        action.tap()
    }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message, file: file, line: line)
    }

    func testSidePaneOpensFromMoreFindsOnThePageAndCloses() throws {
        let app = try launch()
        go(app, to: "/long", heading: "Long Read")
        let window = app.windows.firstMatch.frame
        more(app, pick: "menu.sidePane")
        let pane = app.otherElements["sidePane"]
        XCTAssertTrue(pane.waitForExistence(timeout: 3))
        // About 30% at the trailing edge, at least 250 pt; the page keeps the rest.
        wait({ pane.frame.maxX >= window.maxX - 1 && pane.frame.width >= 249 && pane.frame.width < window.width * 0.45 },
             "the pane sits at the trailing edge, 30% wide (\(pane.frame))")
        let heading = app.webViews.staticTexts["Long Read"]
        XCTAssertLessThan(heading.frame.maxX, pane.frame.minX + 1, "the page is beside the pane, not under it")

        // Find: a list of matches.
        app.segmentedControls["sidePane.picker"].buttons.element(boundBy: 1).tap()
        let field = app.searchFields["sidePane.findField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText("paragraph")
        let count = app.staticTexts["sidePane.findCount"]
        wait({ (count.label).contains("match") && !count.label.hasPrefix("No") }, "Find lists matches (\(count.label))")
        XCTAssertTrue(app.cells["sidePane.match.0"].waitForExistence(timeout: 2))
        app.cells["sidePane.match.0"].tap()

        // Closing gives the page its width back.
        app.buttons["sidePane.close"].tap()
        wait({ !pane.exists || !pane.isHittable }, "the pane closed")
        more(app, pick: "menu.sidePane")
        XCTAssertTrue(pane.waitForExistence(timeout: 3), "it opens again from More")
        app.buttons["more"].firstMatch.tap()
        let hide = app.buttons["menu.sidePane"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3))
        XCTAssertEqual(hide.label, "Hide Side Pane")
        hide.tap()
        wait({ !pane.exists || !pane.isHittable }, "Hide Side Pane closes it")
    }

    func testHistoryAndFindOnPageOpenBesideThePage() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        more(app, pick: "menu.history")
        let pane = app.otherElements["sidePane"]
        XCTAssertTrue(pane.waitForExistence(timeout: 3), "History opens in the side pane, not a sheet")
        XCTAssertFalse(app.otherElements["historySheet"].exists)
        XCTAssertTrue(app.webViews.staticTexts["Page A"].exists, "the page stays on screen beside History")
        more(app, pick: "menu.find")
        XCTAssertTrue(app.searchFields["sidePane.findField"].waitForExistence(timeout: 3), "Find on Page opens the pane's Find")
    }

    func testReaderShowsThePagesArticleBesideIt() throws {
        let app = try launch()
        go(app, to: "/article", heading: "The Quiet Page")
        more(app, pick: "menu.sidePane")
        app.segmentedControls["sidePane.picker"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.webViews["sidePane.readerView"].waitForExistence(timeout: 10), "the article shows in the pane")
    }

    func testNewWindowOpensASecondSceneAndTheTabsMenuSwitches() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        app.webViews.links["Go to B"].press(forDuration: 1.2)
        let open = app.buttons["Open in New Window"]
        try XCTSkipUnless(open.waitForExistence(timeout: 3), "the system takes no new window here")
        open.tap()
        // The new window shows B; the system puts it beside or over the first.
        XCTAssertTrue(app.webViews.staticTexts["Page B"].waitForExistence(timeout: 10), "the new window opened the link")
        wait({ app.windows.count >= 2 || app.buttons.matching(identifier: "addressPill").count >= 2 }, timeout: 5,
             "a second window")
        // The tabs menu lists the other window.
        let tabs = app.buttons.matching(identifier: "tabs").firstMatch
        tabs.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["menu.window.0"].waitForExistence(timeout: 3), "the tabs menu lists the other window")
    }
}
