import XCTest

/// Captures for the gestures lane (docs/research/gestures.md): the history list on Back's long
/// press, the tabs menu with Close All, and a slow pull to refresh (record the screen alongside
/// for its color cycle: `simctl io <udid> recordVideo`). Not a test of behavior: it skips unless
/// `PLAIN_CAPTURE=1` reaches the runner; `scripts/matrix.sh` names it to get a sheet per screen.
@MainActor
final class GestureCaptureTests: XCTestCase {
    private var server: TestServer!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication.isolated()
        app.launch()
        XCTAssertTrue(app.waitForFirstScreen())
        return app
    }

    private func go(_ app: XCUIApplication, _ path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].firstMatch.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10))
    }

    func testCaptureGestureMenus() {
        let app = launch()
        go(app, "/a", heading: "Page A")
        app.webViews.links["Go to B"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Page B"].waitForExistence(timeout: 10))
        pause(0.5)
        app.buttons["back"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["history.-1"].waitForExistence(timeout: 3))
        pause(0.6)
        shot("gestures-history")
        app.buttons["history.-1"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))

        app.typeKey("t", modifierFlags: .command)
        app.textFields["searchField"].typeText(server.address("/c") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page C"].waitForExistence(timeout: 10))
        pause(0.5)
        app.buttons["tabs"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["menu.closeAllTabs"].waitForExistence(timeout: 3))
        pause(0.6)
        shot("gestures-tabsmenu")
        app.buttons["menu.closeAllTabs"].tap()
        XCTAssertTrue(app.buttons["confirm.closeAllTabs"].firstMatch.waitForExistence(timeout: 3))
        pause(0.6)
        shot("gestures-closeall")
    }

    /// A slow pull, held past the threshold, then let go: the video shows the colors running
    /// faster toward the threshold, the fill and the spin. Then the same in a private tab.
    func testCapturePullSlowly() {
        let app = launch()
        go(app, "/long", heading: "Long Read")
        pause(1)
        let page = app.webViews.firstMatch
        let start = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: XCUIGestureVelocity(160), thenHoldForDuration: 1.2)
        pause(2)
        shot("gestures-pull-after")

        app.typeKey("n", modifierFlags: [.command, .shift])
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 10))
        pause(1)
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: XCUIGestureVelocity(160), thenHoldForDuration: 1.2)
        pause(2)
    }
}
