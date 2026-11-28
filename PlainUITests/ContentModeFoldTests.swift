import XCTest

/// Desktop or mobile across a real fold of the iPhone Duo simulator (docs/decisions.md, "Desktop
/// or mobile across the fold"). A test can't fold the simulator itself: it prints
/// `PLAIN-FOLD-REQUEST Open` (or `Closed`) and a driver watching the test log presses Device
/// Hub's button (`scripts/duo-fold.sh`). Without the driver (`TEST_RUNNER_PLAIN_FOLD_DRIVER=1`)
/// the tests skip. They start on the outer screen.
@MainActor
final class ContentModeFoldTests: XCTestCase {
    private var server: TestServer!

    private func launch() throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_FOLD_DRIVER"] == "1",
                          "needs the fold driver (Device Hub)")
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore"]
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        try XCTSkipUnless(app.windows.firstMatch.frame.width < 500, "starts on the outer screen")
        return app
    }

    private func go(_ app: XCUIApplication, to path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show")
    }

    /// Asks the driver to fold or unfold, then waits for the window to change size.
    private func fold(_ app: XCUIApplication, _ state: String) {
        print("PLAIN-FOLD-REQUEST \(state)")
        let window = app.windows.firstMatch
        let done = NSPredicate { _, _ in state == "Open" ? window.frame.width >= 900 : window.frame.width < 500 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: nil)], timeout: 60),
                       .completed, "the simulator did not reach \(state)")
    }

    private func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), what)
    }

    /// Paragraph 40 is still near the top of the page on screen.
    private func assertParagraphNearTop(_ app: XCUIApplication, _ when: String) {
        let paragraph = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Fold paragraph 40.'")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        let y = paragraph.frame.minY
        XCTAssertTrue(y > -20 && y < window.height * 0.45,
                      "\(when): paragraph 40 at y \(Int(y)) in a \(Int(window.height)) pt window")
    }

    func testFoldAndUnfoldSwitchTheSiteAndKeepThePlace() throws {
        let app = try launch()
        go(app, to: "/fold", heading: "Mobile UA")
        assertParagraphNearTop(app, "loaded")

        fold(app, "Open")
        waitFor(app.webViews.staticTexts["Desktop UA"], "the inner screen gets the desktop site")
        sleep(1)
        assertParagraphNearTop(app, "after unfold")

        fold(app, "Closed")
        waitFor(app.webViews.staticTexts["Mobile UA"], "the outer screen gets the mobile site")
        sleep(1)
        assertParagraphNearTop(app, "after fold")
    }

    func testTypedTextIsNeverReloadedAway() throws {
        let app = try launch()
        go(app, to: "/fold", heading: "Mobile UA")
        let field = app.webViews.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The page scrolled away from the field; bring it back.
        app.webViews.firstMatch.swipeDown(velocity: .fast)
        app.webViews.firstMatch.swipeDown(velocity: .fast)
        app.webViews.firstMatch.swipeDown(velocity: .fast)
        field.tap()
        field.typeText("hello fold")

        fold(app, "Open")
        sleep(3)
        XCTAssertTrue(app.webViews.staticTexts["Mobile UA"].exists, "kept: typed text")
        XCTAssertEqual(field.value as? String, "hello fold")
        fold(app, "Closed")
    }

    func testABackgroundTabSwitchesWhenShown() throws {
        let app = try launch()
        go(app, to: "/fold", heading: "Mobile UA")
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 2))
        tabs.press(forDuration: 1.0)
        let newTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch
        XCTAssertTrue(newTab.waitForExistence(timeout: 3))
        newTab.tap()
        go(app, to: "/b", heading: "Page B")

        fold(app, "Open")
        sleep(1)
        app.buttons["tabs"].press(forDuration: 1.0)
        let previous = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Previous Tab'")).firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 3))
        previous.tap()
        waitFor(app.webViews.staticTexts["Desktop UA"], "the background tab is desktop once shown")
        sleep(1)
        assertParagraphNearTop(app, "background tab shown")
        fold(app, "Closed")
    }
}
