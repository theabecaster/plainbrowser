import XCTest

/// Safari's gestures and keys in Plain (docs/research/gestures.md): the hardware keyboard's
/// shortcuts, the history list on a long press of Back and Forward, Close All Tabs from the tabs
/// button, the system's undo for a close, pull to refresh, and on the Duo's inner screen the pinch
/// in to the overview and the trailing edge going forward before it opens the side pane.
@MainActor
final class GestureTests: XCTestCase {
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
        XCTAssertTrue(app.waitForFirstScreen())
        return app
    }

    private func go(_ app: XCUIApplication, to path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].firstMatch.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
        waitForPage(app, heading)
    }

    private func waitForPage(_ app: XCUIApplication, _ heading: String, timeout: TimeInterval = 10,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: timeout),
                      "page \"\(heading)\" did not show", file: file, line: line)
    }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message, file: file, line: line)
    }

    /// Page A, then its link to B: one page back.
    private func openAThenB(_ app: XCUIApplication) {
        go(app, to: "/a", heading: "Page A")
        app.webViews.links["Go to B"].tap()
        waitForPage(app, "Page B")
    }

    // MARK: Keys

    func testKeyboardShortcutsMoveThroughHistoryAndTabs() throws {
        let app = try launch()
        openAThenB(app)

        // ⌘[ and ⌘]: Back and Forward.
        app.typeKey("[", modifierFlags: .command)
        waitForPage(app, "Page A")
        app.typeKey("]", modifierFlags: .command)
        waitForPage(app, "Page B")

        // ⌘T: a new tab with the field open; Escape closes the field, back to the empty tab.
        app.typeKey("t", modifierFlags: .command)
        let field = app.textFields["searchField"]
        wait({ field.exists && field.hasKeyboardFocus }, "⌘T opens the field")
        field.typeText(server.address("/c") + "\n")
        waitForPage(app, "Page C")

        // ⌘1 the first tab, ⌘9 the last, ⌃Tab the next, ⌃⇧Tab the previous.
        app.typeKey("1", modifierFlags: .command)
        waitForPage(app, "Page B")
        app.typeKey("9", modifierFlags: .command)
        waitForPage(app, "Page C")
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [.control, .shift])
        waitForPage(app, "Page B")
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: .control)
        waitForPage(app, "Page C")

        // ⌘W closes the tab; ⌘⇧T brings it back.
        app.typeKey("w", modifierFlags: .command)
        waitForPage(app, "Page B")
        app.typeKey("t", modifierFlags: [.command, .shift])
        waitForPage(app, "Page C")

        // ⌘L: the field; ⌘. (iOS's Cancel): back to the page. Escape in the field is the search
        // sheet's own (AddressField); the simulator's typed Escape doesn't reach a focused field.
        app.typeKey("l", modifierFlags: .command)
        wait({ field.exists && field.hasKeyboardFocus }, "⌘L opens the field")
        app.typeKey(".", modifierFlags: .command)
        wait({ !(field.exists && field.hasKeyboardFocus) }, "⌘. closes the field")
        waitForPage(app, "Page C")

        // ⌘⇧\: the overview; again: back to the page.
        app.typeKey("\\", modifierFlags: [.command, .shift])
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3), "⌘⇧\\ shows all tabs")
        app.typeKey("\\", modifierFlags: [.command, .shift])
        wait({ !gallery.exists || !gallery.isHittable }, "⌘⇧\\ again goes back to the page")
        // Escape leaves the overview too.
        app.typeKey("\\", modifierFlags: [.command, .shift])
        wait({ gallery.exists && gallery.isHittable }, "the overview is up again")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        wait({ !gallery.exists || !gallery.isHittable }, "Escape leaves the overview")
    }

    func testCommandRReloads() throws {
        let app = try launch()
        go(app, to: "/count", heading: "Load 1")
        app.typeKey("r", modifierFlags: .command)
        waitForPage(app, "Load 2")
    }

    func testUndoReopensTheClosedTab() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        app.typeKey("t", modifierFlags: .command)
        app.textFields["searchField"].typeText(server.address("/b") + "\n")
        waitForPage(app, "Page B")
        app.typeKey("w", modifierFlags: .command)
        waitForPage(app, "Page A")
        // The system's undo (shake, three fingers, ⌘Z): "Undo Close Tab".
        app.typeKey("z", modifierFlags: .command)
        waitForPage(app, "Page B")
    }

    // MARK: Long presses

    func testLongPressOnBackAndForwardListsTheHistory() throws {
        let app = try launch()
        openAThenB(app)
        let back = app.buttons["back"].firstMatch
        back.press(forDuration: 1.0)
        let pageA = app.buttons["history.-1"]
        XCTAssertTrue(pageA.waitForExistence(timeout: 3), "Back's long press lists Page A")
        XCTAssertTrue(pageA.label.hasPrefix("Plain Test A"), "named by its title (\(pageA.label))")
        pageA.tap()
        waitForPage(app, "Page A")

        let forward = app.buttons["forward"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 2))
        forward.press(forDuration: 1.0)
        let pageB = app.buttons["history.1"]
        XCTAssertTrue(pageB.waitForExistence(timeout: 3), "Forward's long press lists Page B")
        pageB.tap()
        waitForPage(app, "Page B")
    }

    func testTabsButtonClosesAllTabsAfterAsking() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        app.typeKey("t", modifierFlags: .command)
        app.textFields["searchField"].typeText(server.address("/b") + "\n")
        waitForPage(app, "Page B")

        let tabs = app.buttons["tabs"].firstMatch
        tabs.press(forDuration: 1.0)
        let closeAll = app.buttons["menu.closeAllTabs"]
        XCTAssertTrue(closeAll.waitForExistence(timeout: 3), "Close All is in the tabs menu")
        XCTAssertEqual(closeAll.label, "Close All 2 Tabs")
        closeAll.tap()
        let confirm = app.buttons["confirm.closeAllTabs"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "it asks first")
        confirm.tap()
        // Nothing left: the search field, and Reopen brings both back.
        let field = app.textFields["searchField"]
        wait({ field.exists && field.hasKeyboardFocus }, "the search field opens")
        let reopen = app.buttons["toastButton"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 3), "a Reopen toast")
    }

    // MARK: Pull to refresh

    func testPullingThePageDownReloadsIt() throws {
        let app = try launch()
        go(app, to: "/count", heading: "Load 1")
        let page = app.webViews.firstMatch
        let start = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForPage(app, "Load 2")
    }

    // MARK: The Duo's inner screen

    private func skipUnlessWide(_ app: XCUIApplication) throws {
        let width = app.windows.firstMatch.frame.width
        try XCTSkipUnless(width >= 600, "needs the Duo's inner screen (window is \(Int(width)) pt wide)")
    }

    func testPinchInOnAPageOpensTheOverview() throws {
        let app = try launch()
        try skipUnlessWide(app)
        go(app, to: "/long", heading: "Long Read")
        app.webViews.firstMatch.pinch(withScale: 0.4, velocity: -1)
        XCTAssertTrue(app.scrollViews["tabGallery"].waitForExistence(timeout: 3), "the pinch in shows all tabs")
    }

    func testTrailingEdgeGoesForwardBeforeItOpensTheSidePane() throws {
        let app = try launch()
        try skipUnlessWide(app)
        openAThenB(app)
        app.buttons["back"].firstMatch.tap()
        waitForPage(app, "Page A")
        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
        waitForPage(app, "Page B")
        XCTAssertFalse(app.otherElements["sidePane"].exists, "with a page forward the edge goes forward")
        // Nothing forward now: the same swipe opens the side pane.
        edge.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
        XCTAssertTrue(app.otherElements["sidePane"].waitForExistence(timeout: 3), "then it opens the side pane")
    }
}
