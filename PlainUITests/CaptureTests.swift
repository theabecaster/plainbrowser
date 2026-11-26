import XCTest

/// Walks the shell through its states with pauses, attaching a screenshot of each, for design
/// review and screen recordings (docs/workflow.md, Verify). Not a test of behavior: it skips
/// itself unless `PLAIN_CAPTURE=1` reaches the runner. Run it alone:
/// `TEST_RUNNER_PLAIN_CAPTURE=1 xcodebuild ... -only-testing:PlainUITests/CaptureTests test-without-building`,
/// then export the attachments with `xcrun xcresulttool export attachments`.
@MainActor
final class CaptureTests: XCTestCase {
    func testCaptureShellStates() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["-PlainInMemoryStore", "-PlainSeedFavorites"]
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        pause(1.5)
        shot("1-launch")

        for path in ["/a", "/b"] {
            if !(field.exists && field.hasKeyboardFocus) { app.buttons["addressPill"].tap() }
            field.typeText(server.address(path) + "\n")
            XCTAssertTrue(app.webViews.staticTexts[path == "/a" ? "Page A" : "Page B"].waitForExistence(timeout: 10))
        }
        app.buttons["addressPill"].tap()
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 10))
        pause(2.5)
        shot("2-page")

        // URL bar focus: the pill grows into the search sheet.
        app.buttons["addressPill"].tap()
        pause(1)
        shot("3-focus")
        field.typeText("Plain")
        pause(1.5)
        shot("4-suggestions")
        // Clear the field (no rows left), then close the sheet with a tap on its empty top.
        field.buttons.firstMatch.tap()
        pause(0.5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
        pause(1)

        // Toolbar collapse.
        let webView = app.webViews.firstMatch
        webView.swipeUp(velocity: .slow)
        pause(1)
        shot("5-collapsed")
        webView.swipeDown(velocity: .slow)
        pause(1)

        // Page menu from the pill.
        app.buttons["addressPill"].press(forDuration: 0.8)
        pause(1)
        shot("6-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        pause(1)

        // Pull to refresh, slowly, holding past the threshold.
        let start = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
        pause(2)
        shot("7-after-refresh")
    }

    /// The sheets the shell presents: page menu, Settings, Search Engine, History, and the
    /// favorites strip's menu and editor.
    func testCaptureSheets() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["-PlainInMemoryStore", "-PlainSeedFavorites"]
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for (path, heading) in [("/a", "Page A"), ("/b", "Page B"), ("/long", "Long Read")] {
            if !(field.exists && field.hasKeyboardFocus) { app.buttons["addressPill"].tap() }
            field.typeText(server.address(path) + "\n")
            XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10))
        }
        pause(2.5)

        app.buttons["more"].tap()
        pause(1)
        shot("s1-page-menu")
        app.buttons["Settings…"].tap()
        pause(1.5)
        shot("s2-settings")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Search Engine'")).firstMatch.tap()
        pause(1)
        shot("s3-search-engine")
        let back = app.otherElements["settingsSheet"].buttons["BackButton"]
        if back.exists { back.tap() } else { app.navigationBars["Search Engine"].buttons.firstMatch.tap() }
        pause(0.8)
        app.buttons["Done"].tap()
        pause(1)

        app.buttons["more"].tap()
        pause(1)
        app.buttons["History"].tap()
        pause(1.5)
        shot("s4-history")
        app.buttons["Done"].tap()
        pause(1)

        app.buttons["addressPill"].tap()
        pause(1)
        app.buttons["favorite.0"].press(forDuration: 1)
        pause(1)
        shot("s5-favorites-menu")
        app.buttons["Edit Favorites"].tap()
        pause(1.5)
        shot("s6-favorites-editor")
        app.buttons["Done"].tap()
        pause(1.5)
        shot("s7-back-to-search")
    }

    /// The bar over a page with a fixed footer, expanded and collapsed: the footer sits above
    /// the resting bar, and the scroll edge effect keeps text under the bar readable.
    func testCaptureFixedFooter() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["-PlainInMemoryStore"]
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/footer") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Footer Page"].waitForExistence(timeout: 10))
        pause(2)
        shot("f1-footer-expanded")
        app.webViews.firstMatch.swipeUp(velocity: .slow)
        pause(2)
        shot("f2-footer-collapsed")
        // The page's end with the bar expanded: the last line clears the bar.
        for _ in 0..<10 { app.webViews.firstMatch.swipeUp(velocity: .fast) }
        pause(2)
        app.buttons["addressPill"].tap()
        pause(2)
        shot("f3-page-end")
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
