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
        let field = app.descendants(matching: .any)["sidePane.findField"]
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
        XCTAssertTrue(app.descendants(matching: .any)["sidePane.findField"].waitForExistence(timeout: 3), "Find on Page opens the pane's Find")
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
        // The tabs menu's New Window (the link menu's Open in New Window is the same request; its
        // live preview keeps XCTest waiting for idle, so it is checked in LinkMenuRulesTests).
        app.buttons["tabs"].firstMatch.press(forDuration: 1.0)
        let open = app.buttons["menu.newWindow"]
        try XCTSkipUnless(open.waitForExistence(timeout: 3), "the system takes no new window here")
        open.tap()
        // The new window opens on search; the system puts it over the first (or beside it in
        // Split View).
        let field = app.textFields["searchField"]
        wait({ field.exists && field.hasKeyboardFocus && !app.webViews.staticTexts["Page A"].exists }, timeout: 10,
             "the new window opened on search")
        field.typeText(server.address("/b") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page B"].waitForExistence(timeout: 10), "the new window loads its own page")
        // More lists the other window (the tabs menu too, once this window has a second tab).
        app.buttons["more"].firstMatch.tap()
        let others = app.buttons["menu.otherWindows"]
        XCTAssertTrue(others.waitForExistence(timeout: 3), "More lists the other windows")
        others.tap()
        let first = app.buttons["menu.window.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 3), "the first window is in the list")
        first.tap()
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10), "the first window came forward")
    }

    /// Walks two windows for screenshots taken from outside (`simctl io screenshot`, the inner
    /// display): it pauses in each state. Runs on request only (`TEST_RUNNER_PLAIN_CAPTURE=1`).
    func testCaptureTwoWindows() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let app = try launch()
        go(app, to: "/article", heading: "The Quiet Page")
        app.buttons["tabs"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["menu.newWindow"].waitForExistence(timeout: 3))
        sleep(4)  // capture: the tabs menu with New Window
        app.buttons["menu.newWindow"].tap()
        let field = app.textFields["searchField"]
        wait({ field.exists && field.hasKeyboardFocus && !app.webViews.staticTexts["The Quiet Page"].exists }, timeout: 10,
             "the new window opened on search")
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 10))
        sleep(4)  // capture: the second window
        app.buttons["more"].firstMatch.tap()
        app.buttons["menu.otherWindows"].tap()
        XCTAssertTrue(app.buttons["menu.window.0"].waitForExistence(timeout: 3))
        sleep(4)  // capture: Other Windows
        app.buttons["menu.window.0"].tap()
        XCTAssertTrue(app.webViews.staticTexts["The Quiet Page"].waitForExistence(timeout: 10))
        sleep(4)  // capture: back in the first window
    }
}
