import XCTest

/// The shell's interactions against local pages (TestServer): type and go, suggestion tap,
/// back and forward, pull to refresh, and the toolbar collapsing on scroll.
@MainActor
final class ShellTests: XCTestCase {
    private var server: TestServer!

    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        let app = XCUIApplication()
        // A fresh, empty database: no history from earlier runs.
        app.launchArguments = ["-PlainInMemoryStore"]
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        return app
    }

    /// Types an address into the open field and submits it.
    private func go(_ app: XCUIApplication, to path: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
    }

    private func waitForPage(
        _ app: XCUIApplication, _ heading: String, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let text = app.webViews.staticTexts[heading]
        XCTAssertTrue(text.waitForExistence(timeout: timeout), "page \"\(heading)\" did not show", file: file, line: line)
    }

    func testTypeAndGo() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")

        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 2))
        XCTAssertEqual(pill.value as? String, "http://" + server.address("/a"))
        XCTAssertFalse(app.textFields["searchField"].exists, "the field should rest as the pill after submit")
    }

    func testSuggestionTap() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        go(app, to: "/b")
        waitForPage(app, "Page B")
        // History is written in batches (FixedChoices.historyFlushInterval, 2 s).
        Thread.sleep(forTimeInterval: 2.5)

        app.buttons["addressPill"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText("Plain Test")
        let row = app.buttons["Plain Test A"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "history suggestion for page A did not show")
        row.tap()
        waitForPage(app, "Page A")
        XCTAssertEqual(app.buttons["addressPill"].value as? String, "http://" + server.address("/a"))
    }

    func testBackAndForward() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        app.webViews.links["Go to B"].tap()
        waitForPage(app, "Page B")

        let back = app.buttons["back"]
        XCTAssertTrue(back.waitForExistence(timeout: 2))
        back.tap()
        waitForPage(app, "Page A")
        XCTAssertEqual(app.buttons["addressPill"].value as? String, "http://" + server.address("/a"))

        let forward = app.buttons["forward"]
        XCTAssertTrue(forward.isEnabled)
        forward.tap()
        waitForPage(app, "Page B")

        // The edge swipe (allowsBackForwardNavigationGestures) starts and tracks under XCUITest,
        // but a synthesized release never commits it, so it is checked by hand on the device.
    }

    func testPullToRefresh() throws {
        let app = try launch()
        go(app, to: "/count")
        waitForPage(app, "Load 1")

        let webView = app.webViews.firstMatch
        let start = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForPage(app, "Load 2")
    }

    func testToolbarCollapsesOnScrollAndComesBackAtTheTop() throws {
        let app = try launch()
        go(app, to: "/long")
        waitForPage(app, "Long Read")
        let pill = app.buttons["addressPill"]
        let expanded = pill.frame.height

        let webView = app.webViews.firstMatch
        webView.swipeUp(velocity: .slow)
        let collapsed = NSPredicate { _, _ in pill.frame.height < expanded - 4 }
        wait(for: [XCTNSPredicateExpectation(predicate: collapsed, object: nil)], timeout: 3)

        // A tap on the collapsed pill brings the bar back instead of editing.
        pill.tap()
        let back = NSPredicate { _, _ in abs(pill.frame.height - expanded) < 1 }
        wait(for: [XCTNSPredicateExpectation(predicate: back, object: nil)], timeout: 3)
        XCTAssertFalse(app.textFields["searchField"].exists)
    }
}
