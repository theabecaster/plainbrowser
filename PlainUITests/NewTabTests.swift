import XCTest

/// The quick ways to a new tab without the switcher (docs/research/new-tab.md): the bar's "+",
/// its long press for the other kind, and the swipe past the last tab. Each lands on a new tab
/// with its search field focused. Pages come from the local TestServer.
@MainActor
final class NewTabTests: XCTestCase {
    private var server: TestServer!

    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore"]
        app.launch()
        XCTAssertTrue(app.waitForFirstScreen())
        return app
    }

    private func go(_ app: XCUIApplication, to path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].firstMatch.waitForExistence(timeout: 10), "page \"\(heading)\" did not show")
    }

    /// The new tab's field has the keyboard, and it is empty: a new tab, not this page's address.
    private func expectNewTabField(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields["searchField"]
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [focused], timeout: 3), .completed, "the new tab's field is not focused", file: file, line: line)
        let text = (field.value as? String) ?? ""
        XCTAssertTrue(text.isEmpty || text == field.placeholderValue, "the field starts empty, got \(text)", file: file, line: line)
    }

    /// Opens the gallery and checks how many tabs the shown list holds (its accessibility value).
    private func expectTabCount(_ app: XCUIApplication, _ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["tabs"].firstMatch.tap()
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3), file: file, line: line)
        let value = count == 1 ? "1 tab" : "\(count) tabs"
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: gallery)
        XCTAssertEqual(XCTWaiter().wait(for: [counted], timeout: 4), .completed, "expected \(value)", file: file, line: line)
    }

    func testBarPlusOpensANewTabWithTheField() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        let plus = app.buttons["newTab"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 2), "the bar has New Tab on a page")
        XCTAssertEqual(plus.label, "New Tab")
        plus.tap()
        expectNewTabField(app)
        go(app, to: "/b", heading: "Page B")
        expectTabCount(app, 2)
    }

    func testClosingAnUntouchedNewTabGoesBackToThePage() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        app.buttons["newTab"].firstMatch.tap()
        expectNewTabField(app)
        // A stray "+": closing the field with nothing typed brings Page A back, and no empty tab
        // is left behind.
        app.swipeDown(velocity: .fast)
        let field = app.textFields["searchField"]
        if field.exists, field.hasKeyboardFocus { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap() }
        XCTAssertTrue(app.webViews.staticTexts["Page A"].firstMatch.waitForExistence(timeout: 3), "Page A came back")
        let pill = app.buttons["addressPill"]
        XCTAssertEqual(pill.value as? String, "http://" + server.address("/a"))
        XCTAssertTrue(app.buttons["newTab"].firstMatch.exists, "New Tab is back with the page")
        expectTabCount(app, 1)
    }

    func testNoNewTabButtonOnTheStartScreen() throws {
        let app = try launch()
        // First run: the field is up over the start screen; close it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.buttons["more"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["newTab"].exists, "already in a new tab")
    }

    func testBarPlusLongPressOpensTheOtherKind() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        let plus = app.buttons["newTab"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 2))
        plus.press(forDuration: 1)
        let toPrivate = app.buttons["newTabMenu.private"]
        XCTAssertTrue(toPrivate.waitForExistence(timeout: 3), "the long press offers New Private Tab")
        toPrivate.tap()
        expectNewTabField(app)
        go(app, to: "/b", heading: "Page B")
        // On a private page the tap stays private and the long press offers a regular tab.
        app.buttons["newTab"].firstMatch.press(forDuration: 1)
        XCTAssertTrue(app.buttons["newTabMenu.regular"].waitForExistence(timeout: 3), "the long press offers New Tab from a private page")
    }

    func testSwipePastTheLastTabOpensANewTab() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        let pill = app.buttons["addressPill"]
        // A long, slow drag on the pill toward the leading edge: past the card's line, then let go.
        let start = pill.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: pill.frame.midY - app.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        expectNewTabField(app)
        go(app, to: "/b", heading: "Page B")
        expectTabCount(app, 2)
    }
}
