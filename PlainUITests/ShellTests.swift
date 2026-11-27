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
        let app = XCUIApplication.isolated()
        // A fresh, empty database: no history from earlier runs.
        app.launchArguments += ["-PlainInMemoryStore"]
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

    /// A long tracking address never pushes the pill past the screen, resting or editing.
    func testLongAddressStaysInsideTheScreen() throws {
        let app = try launch()
        let screen = app.windows.firstMatch.frame
        go(app, to: "/a?cjdata=MXxOfDB8WXww&cjevent=9dfc9ae0e9b011f1811706670a82b836&utm_source=CJ&utm_medium=101597760&utm_campaign=4500501&utm_term=17187241")
        waitForPage(app, "Page A")
        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(pill.frame.minX, screen.minX)
        XCTAssertLessThanOrEqual(pill.frame.maxX, screen.maxX)

        pill.tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(field.frame.minX, screen.minX)
        XCTAssertLessThanOrEqual(field.frame.maxX, screen.maxX)
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

    /// Waits for `condition`, polling the app.
    private func waitUntil(
        _ what: String, timeout: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) {
        let predicate = NSPredicate { _, _ in condition() }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = what
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "timed out waiting for: \(what)", file: file, line: line)
    }

    /// A drag on the page that stops before the finger lifts, so the page does not coast:
    /// `from` and `to` are heights in the web view (0 top, 1 bottom).
    private func drag(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
        let webView = app.webViews.firstMatch
        let start = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        let end = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// The pill is gone: the bar is hidden (it sinks away and leaves the accessibility tree).
    private func isHidden(_ pill: XCUIElement) -> Bool {
        !pill.exists || !pill.isHittable
    }

    func testToolbarCollapsesOnScrollAndComesBackAtTheTop() throws {
        let app = try launch()
        go(app, to: "/long")
        waitForPage(app, "Long Read")
        let pill = app.buttons["addressPill"]
        let expanded = pill.frame.height

        // A short drag: the bar becomes the pill, and stays there.
        drag(app, from: 0.6, to: 0.5)
        waitUntil("bar collapsed") { pill.exists && pill.frame.height < expanded - 4 }

        // A tap on the collapsed pill brings the bar back instead of editing.
        pill.tap()
        waitUntil("bar back") { abs(pill.frame.height - expanded) < 1 }
        XCTAssertFalse(app.textFields["searchField"].exists)
    }

    /// Reading on: past the pill the bar hides, and a move up brings the whole bar back.
    func testBarHidesWhileReadingAndComesBackOnScrollUp() throws {
        let app = try launch()
        go(app, to: "/long")
        waitForPage(app, "Long Read")
        let pill = app.buttons["addressPill"]
        let expanded = pill.frame.height

        app.webViews.firstMatch.swipeUp(velocity: .slow)
        waitUntil("bar hidden") { self.isHidden(pill) }

        // A small nudge up (rereading a line) leaves it hidden.
        drag(app, from: 0.5, to: 0.51)
        XCTAssertTrue(isHidden(pill))

        drag(app, from: 0.4, to: 0.5)
        waitUntil("bar back whole") { pill.exists && abs(pill.frame.height - expanded) < 1 }
    }

    /// A tap on the bottom edge (the home-indicator zone) brings a hidden bar back.
    func testTapOnTheBottomEdgeBringsAHiddenBarBack() throws {
        let app = try launch()
        go(app, to: "/long")
        waitForPage(app, "Long Read")
        let pill = app.buttons["addressPill"]
        let expanded = pill.frame.height

        app.webViews.firstMatch.swipeUp(velocity: .slow)
        waitUntil("bar hidden") { self.isHidden(pill) }

        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995)).tap()
        waitUntil("bar back whole") { pill.exists && abs(pill.frame.height - expanded) < 1 }
        XCTAssertFalse(app.textFields["searchField"].exists)
    }

    /// Reaching the end of the page brings the bar back, and the page's last line clears it.
    func testPageEndBringsTheBarBack() throws {
        let app = try launch()
        go(app, to: "/long")
        waitForPage(app, "Long Read")
        let pill = app.buttons["addressPill"]
        let expanded = pill.frame.height
        let webView = app.webViews.firstMatch

        webView.swipeUp(velocity: .slow)
        waitUntil("bar hidden") { self.isHidden(pill) }
        let last = webView.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Paragraph 80.'")).firstMatch
        for _ in 0..<12 where !(last.exists && last.isHittable) {
            webView.swipeUp(velocity: .fast)
        }
        waitUntil("bar back at the end", timeout: 6) { pill.exists && abs(pill.frame.height - expanded) < 1 }
        waitUntil("last line above the bar") { last.exists && last.frame.maxY <= pill.frame.minY + 1 }
    }

    /// The page's bottom inset follows the bar's resting state: a fixed footer sits above the
    /// expanded bar, moves down with the pill, further down to the home indicator when the bar
    /// hides, and comes back up with the bar.
    func testFixedFooterClearsTheRestingBar() throws {
        let app = try launch()
        go(app, to: "/footer")
        waitForPage(app, "Footer Page")
        let pill = app.buttons["addressPill"]
        let footer = app.webViews.staticTexts["Fixed Footer"]
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        let expandedHeight = pill.frame.height

        waitUntil("footer above the expanded bar") { footer.frame.maxY <= pill.frame.minY + 1 }
        let expandedFooterBottom = footer.frame.maxY

        drag(app, from: 0.6, to: 0.5)
        waitUntil("bar collapsed") { pill.exists && pill.frame.height < expandedHeight - 4 }
        waitUntil("footer down to the collapsed bar") {
            footer.frame.maxY > expandedFooterBottom + 20 && footer.frame.maxY <= pill.frame.minY + 1
        }
        let pillFooterBottom = footer.frame.maxY

        app.webViews.firstMatch.swipeUp(velocity: .slow)
        waitUntil("bar hidden") { self.isHidden(pill) }
        let screenBottom = app.windows.firstMatch.frame.maxY
        waitUntil("footer down to the home indicator") {
            footer.frame.maxY > pillFooterBottom + 10 && footer.frame.maxY < screenBottom
        }

        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995)).tap()
        waitUntil("bar back") { pill.exists && abs(pill.frame.height - expandedHeight) < 1 }
        waitUntil("footer back above the expanded bar") { footer.frame.maxY <= pill.frame.minY + 1 }
    }
}
