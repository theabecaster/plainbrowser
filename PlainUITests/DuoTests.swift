import XCTest

/// The Duo's inner-screen layouts: split tabs (open from the page menu, focus by touch, close a
/// pane) and Tab Layout (Above by default under the inner screen's top bar, Left, Right; the
/// setting survives a relaunch).
///
/// They need the iPhone Duo simulator unfolded: the fold is set only in Device Hub
/// (`scripts/duo-fold.sh <sim> Open`). Elsewhere, an iPhone or the Duo's outer screen, they skip.
@MainActor
final class DuoTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ arguments: [String] = ["-PlainInMemoryStore"]) throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication.isolated()
        app.launchArguments += arguments
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        return app
    }

    /// Skips unless the window is the Duo's inner screen in landscape (wide enough for a split).
    private func requireInnerLandscape(_ app: XCUIApplication) throws {
        let width = app.windows.firstMatch.frame.width
        try XCTSkipUnless(width >= 900, "needs the Duo's inner screen in landscape (window is \(Int(width)) pt wide)")
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

    /// The page menu from a long press on the pill (it acts on the focused pane), then `item`.
    private func pageMenu(_ app: XCUIApplication, pick item: String, file: StaticString = #filePath, line: UInt = #line) {
        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 2), file: file, line: line)
        pill.press(forDuration: 1.0)
        let action = app.buttons[item]
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the page menu", file: file, line: line)
        action.tap()
    }

    private func tabsMenu(_ app: XCUIApplication, pick item: String) {
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 2))
        tabs.press(forDuration: 1.0)
        let action = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the tabs menu")
        action.tap()
    }

    private func waitForPill(_ app: XCUIApplication, showing path: String, file: StaticString = #filePath, line: UInt = #line) {
        let pill = app.buttons["addressPill"]
        let shows = NSPredicate { _, _ in (pill.value as? String)?.hasSuffix(path) == true }
        let expectation = XCTNSPredicateExpectation(predicate: shows, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed,
                       "the pill shows \(String(describing: pill.value)), not \(path)", file: file, line: line)
    }

    /// Pages A and B both on screen, side by side, A first.
    private func waitForSplit(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let a = app.webViews.staticTexts["Page A"]
        let b = app.webViews.staticTexts["Page B"]
        let split = NSPredicate { _, _ in a.exists && b.exists && a.frame.maxX <= b.frame.minX }
        let expectation = XCTNSPredicateExpectation(predicate: split, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed,
                       "pages A and B are not side by side", file: file, line: line)
    }

    func testSplitOpensFromThePageMenuFocusesByTouchAndCloses() throws {
        let app = try launch()
        try requireInnerLandscape(app)
        go(app, to: "/a", heading: "Page A")
        tabsMenu(app, pick: "New Tab")
        go(app, to: "/b", heading: "Page B")

        // B moves to the other pane, A (its neighbour) fills the first; the new pane is focused.
        pageMenu(app, pick: "menu.otherPane")
        waitForSplit(app)
        waitForPill(app, showing: "/b")
        let pill = app.buttons["addressPill"]
        let headingA = app.webViews.staticTexts["Page A"]
        let headingB = app.webViews.staticTexts["Page B"]
        // One top bar spans both panes (docs/decisions.md, "Duo inner screen: Safari's top bar"):
        // the address is the focused pane's, and the bar stays where it is when focus moves.
        XCTAssertLessThan(pill.frame.minX, headingB.frame.minX, "the bar spans the panes, not only the focused one")

        // A touch on the first pane focuses it: the address shows its page; the bar still spans
        // both panes (its back and forward buttons may change its width, not its place).
        headingA.tap()
        waitForPill(app, showing: "/a")
        XCTAssertLessThan(pill.frame.minX, headingB.frame.minX, "the bar still spans both panes")
        XCTAssertGreaterThan(pill.frame.maxX, headingA.frame.maxX, "the bar still spans both panes")

        // Close Pane closes the focused one; its tab stays open, the other page fills the window.
        pageMenu(app, pick: "menu.closePane")
        XCTAssertTrue(headingA.waitForNonExistence(timeout: 5), "the closed pane's page left the screen")
        waitForPill(app, showing: "/b")
        let filled = NSPredicate { _, _ in headingB.frame.minX < 100 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: filled, object: nil)], timeout: 3), .completed,
                       "the remaining page fills the window")
        // The tab is still open: the tabs menu goes back to it.
        tabsMenu(app, pick: "Previous Tab")
        XCTAssertTrue(headingA.waitForExistence(timeout: 5))
    }

    func testOpenInOtherPaneFromTheLinkMenu() throws {
        let app = try launch()
        try requireInnerLandscape(app)
        go(app, to: "/a", heading: "Page A")
        app.webViews.links["Go to B"].press(forDuration: 1.2)
        let open = app.buttons["Open in Other Pane"]
        XCTAssertTrue(open.waitForExistence(timeout: 3), "the link menu offers the other pane")
        open.tap()
        waitForSplit(app)
        waitForPill(app, showing: "/b")
    }

    /// Settings > Tab Layout > `choice`, then Done.
    private func chooseTabLayout(_ app: XCUIApplication, _ choice: String, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["more"].tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3), file: file, line: line)
        settings.tap()
        let layout = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tab Layout'")).firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 3), "Tab Layout is in Settings", file: file, line: line)
        XCTAssertTrue(layout.isEnabled, "Tab Layout applies on the inner screen", file: file, line: line)
        layout.tap()
        let option = app.buttons[choice]
        XCTAssertTrue(option.waitForExistence(timeout: 2), "\"\(choice)\" is not a Tab Layout choice", file: file, line: line)
        option.tap()
        app.buttons["Done"].tap()
    }

    func testTabLayoutAboveByDefaultThenLeftThenRightAndItSurvivesRelaunch() throws {
        var app = try launch(["-PlainTestStore", "-PlainResetStore"])
        try requireInnerLandscape(app)
        go(app, to: "/a", heading: "Page A")
        let strip = app.otherElements["tabStrip"]
        let window = app.windows.firstMatch.frame
        // Above is the default, as Safari on the inner screen: the top bar holds the buttons, and
        // the strip shows from the second tab.
        XCTAssertLessThan(app.buttons["back"].frame.midY, window.midY, "the buttons are in the top bar")
        XCTAssertLessThan(app.buttons["addressPill"].frame.midY, window.midY, "the address is in the top bar")
        XCTAssertFalse(strip.exists, "one tab: no strip")
        tabsMenu(app, pick: "New Tab")
        go(app, to: "/b", heading: "Page B")
        XCTAssertTrue(strip.waitForExistence(timeout: 3), "two tabs: the strip shows")
        XCTAssertLessThan(strip.frame.maxY, app.webViews.staticTexts["Page B"].frame.minY, "the page starts under the strip")

        chooseTabLayout(app, "Left")
        let sidebar = app.otherElements["sideTabs"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3), "Left: the sidebar shows")
        XCTAssertLessThan(sidebar.frame.minX, window.midX)
        XCTAssertFalse(strip.exists)
        // One New Tab button: the bar's "+" on a page, so the sidebar shows none of its own.
        XCTAssertFalse(app.buttons["sideTabs.newTab"].exists)
        XCTAssertTrue(app.buttons["newTab"].firstMatch.exists)

        // The Tabs button hides the sidebar and brings it back.
        app.buttons["tabs"].tap()
        let hidden = NSPredicate { _, _ in !sidebar.exists }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 3), .completed)
        app.buttons["tabs"].tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3))

        chooseTabLayout(app, "Right")
        let onRight = NSPredicate { _, _ in sidebar.exists && sidebar.frame.minX > window.midX }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: onRight, object: nil)], timeout: 3), .completed,
                       "the sidebar moved to the right")

        // Settings are written at once.
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
        app = try launch(["-PlainTestStore"])
        let back = app.otherElements["sideTabs"]
        let comesBack = NSPredicate { _, _ in back.exists && back.frame.minX > window.midX }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: comesBack, object: nil)], timeout: 5), .completed,
                       "Right comes back after a relaunch")
    }

    func testSidebarAndStripListTheTabsAndSwitchThem() throws {
        let app = try launch()
        try requireInnerLandscape(app)
        go(app, to: "/a", heading: "Page A")
        tabsMenu(app, pick: "New Tab")
        go(app, to: "/b", heading: "Page B")

        let stripTabs = app.otherElements["tabStrip"].descendants(matching: .any).matching(identifier: "stripTab")
        let twoInStrip = NSPredicate { _, _ in stripTabs.count == 2 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: twoInStrip, object: nil)], timeout: 5), .completed)
        stripTabs.matching(NSPredicate(format: "label == 'Plain Test A'")).firstMatch.tap()
        waitForPill(app, showing: "/a")

        chooseTabLayout(app, "Left")
        let rows = app.otherElements["sideTabs"].descendants(matching: .any).matching(identifier: "sideTab")
        let two = NSPredicate { _, _ in rows.count == 2 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: two, object: nil)], timeout: 5), .completed)
        rows.matching(NSPredicate(format: "label == 'Plain Test B'")).firstMatch.tap()
        waitForPill(app, showing: "/b")

        // New Tab is the top bar's "+" over the strip (the strip has none of its own), straight to
        // the search field.
        chooseTabLayout(app, "Above")
        XCTAssertFalse(app.buttons["tabStrip.newTab"].exists, "one New Tab button on screen")
        app.buttons["newTab"].firstMatch.tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 3))
    }
}
