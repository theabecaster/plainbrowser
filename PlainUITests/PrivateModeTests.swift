import XCTest

/// Private mode you can't miss (docs/decisions.md): being in it shows on the pill, the start
/// screen and the switcher; leaving takes one tap; Close All Private Tabs is where people look
/// for it; a relaunch never comes back private. Pages come from the local TestServer.
@MainActor
final class PrivateModeTests: XCTestCase {
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
        XCTAssertTrue(app.waitForFirstScreen())
        return app
    }

    private func go(_ app: XCUIApplication, to path: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
    }

    private func waitForPage(_ app: XCUIApplication, _ heading: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show",
            file: file, line: line
        )
    }

    private func tabsMenu(_ app: XCUIApplication, pick item: String, file: StaticString = #filePath, line: UInt = #line) {
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 2), file: file, line: line)
        tabs.press(forDuration: 1.0)
        let action = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the tabs menu", file: file, line: line)
        action.tap()
    }

    /// Closes the search field by tapping the space above it.
    private func closeSearch(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func openGallery(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["tabs"].tap()
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        return gallery
    }

    private func waitForTabCount(_ gallery: XCUIElement, _ count: Int) -> Bool {
        let value = count == 1 ? "1 tab" : "\(count) tabs"
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: gallery)
        return XCTWaiter.wait(for: [expectation], timeout: 4) == .completed
    }

    private func waitForSelected(_ element: XCUIElement, _ selected: Bool = true) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == %@", NSNumber(value: selected)), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }

    // MARK: Tests

    /// Entering private shows everywhere the user looks: the pill's label and the switcher's
    /// selected Private side with both counts (the start screen: `testStartScreenLeavesPrivate`;
    /// New Private Tab from a page closes back to it untouched, so it is reached from the start).
    func testPrivateIsVisibleEverywhere() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        XCTAssertEqual(app.buttons["addressPill"].label, "Address")

        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/b")
        waitForPage(app, "Page B")
        XCTAssertEqual(app.buttons["addressPill"].label, "Private Address")

        let gallery = openGallery(app)
        XCTAssertTrue(waitForTabCount(gallery, 1))
        let privateSide = app.buttons["galleryPrivate"]
        let tabsSide = app.buttons["galleryRegular"]
        XCTAssertTrue(waitForSelected(privateSide), "the switcher opens on Private, selected")
        XCTAssertFalse(tabsSide.isSelected)
        XCTAssertEqual(privateSide.value as? String, "1 tab")
        XCTAssertEqual(tabsSide.value as? String, "1 tab", "the other side's count shows too")
    }

    /// Leaving private takes one tap in the switcher, and the regular tab opens as it was.
    func testLeavePrivateInOneTap() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/b")
        waitForPage(app, "Page B")

        let gallery = openGallery(app)
        app.buttons["galleryRegular"].tap()
        XCTAssertTrue(waitForSelected(app.buttons["galleryRegular"]), "one tap: the regular list")
        XCTAssertFalse(app.buttons["galleryPrivate"].isSelected)
        let card = gallery.descendants(matching: .any).matching(identifier: "tabCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.tap()
        waitForPage(app, "Page A")
        XCTAssertEqual(app.buttons["addressPill"].label, "Address", "out of private")
    }

    /// The start screen of an empty private tab says Private, and leaves private in one tap.
    func testStartScreenLeavesPrivate() throws {
        let app = try launch()
        closeSearch(app)
        app.buttons["start.privateTab"].tap()
        closeSearch(app)
        XCTAssertTrue(app.staticTexts["start.privateTitle"].waitForExistence(timeout: 2), "the start screen says Private")
        XCTAssertTrue(app.buttons["start.regularTab"].exists, "and how to leave")
        XCTAssertEqual(app.buttons["addressPill"].label, "Private Address")
        app.buttons["start.regularTab"].tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 2))
        closeSearch(app)
        XCTAssertEqual(app.buttons["addressPill"].label, "Address")
        XCTAssertFalse(app.staticTexts["start.privateTitle"].exists)
        XCTAssertTrue(app.buttons["start.privateTab"].exists)
    }

    /// Close All Private Tabs in the switcher's More menu, even with one private card; afterwards
    /// the regular tab is back and nothing private is left.
    func testCloseAllPrivateTabsFromTheSwitcher() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/b")
        waitForPage(app, "Page B")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/c")
        waitForPage(app, "Page C")

        let gallery = openGallery(app)
        XCTAssertTrue(waitForTabCount(gallery, 2))
        app.buttons["galleryMenu"].tap()
        let closeAll = app.buttons["gallery.closeAll"]
        XCTAssertTrue(closeAll.waitForExistence(timeout: 3))
        XCTAssertEqual(closeAll.label, "Close All Private Tabs")
        closeAll.tap()
        let confirm = app.buttons["Close All 2 Private Tabs"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        // Never an empty switcher: it moves to the regular list, the switch on Tabs.
        XCTAssertTrue(waitForSelected(app.buttons["galleryRegular"]), "the regular list, out of private")
        XCTAssertEqual(app.buttons["galleryPrivate"].value as? String, "0 tabs", "no private tab left")
        XCTAssertFalse(app.buttons["reopenTab"].exists, "private tabs never come back")
        let card = gallery.descendants(matching: .any).matching(identifier: "tabCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.tap()
        waitForPage(app, "Page A")
        XCTAssertEqual(app.buttons["addressPill"].label, "Address")
    }

    /// The tabs menu on a private page ends private browsing in one step with two or more open.
    func testCloseAllPrivateTabsFromTheTabsMenu() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/b")
        waitForPage(app, "Page B")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/c")
        waitForPage(app, "Page C")
        tabsMenu(app, pick: "Close All Private Tabs")
        waitForPage(app, "Page A")
        XCTAssertEqual(app.buttons["addressPill"].label, "Address")
    }

    /// Private tabs are never kept: after a relaunch the app is out of private, on the regular tab.
    func testRelaunchIsNeverPrivate() throws {
        var app = try launch(["-PlainTestStore", "-PlainResetStore"])
        go(app, to: "/a")
        waitForPage(app, "Page A")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/b")
        waitForPage(app, "Page B")
        XCUIApplication.leaveForAnotherApp()
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        app = try launch(["-PlainTestStore"])
        let pill = app.buttons["addressPill"]
        let field = app.textFields["searchField"]
        if field.exists, field.hasKeyboardFocus { closeSearch(app) }
        XCTAssertTrue(pill.waitForExistence(timeout: 3))
        XCTAssertEqual(pill.label, "Address", "a relaunch is never private")
        XCTAssertFalse(app.staticTexts["start.privateTitle"].exists)
    }

    // MARK: Captures

    /// Screenshots of each private state for design review, with `PLAIN_CAPTURE=1` only.
    func testCapturePrivateStates() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let app = try launch()
        go(app, to: "/long")
        waitForPage(app, "Long Read")
        pause(1.5)
        shot("p1-regular-page")

        tabsMenu(app, pick: "New Private Tab")
        pause(1)
        shot("p2-private-focus")
        // Typed straight away: closing the field untouched would go back to the regular page.
        go(app, to: "/long")
        waitForPage(app, "Long Read")
        pause(1.5)
        shot("p4-private-page")

        _ = openGallery(app)
        pause(1.2)
        shot("p5-private-switcher")
        app.buttons["galleryMenu"].tap()
        pause(0.8)
        shot("p6-private-switcher-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        pause(0.6)
        app.buttons["galleryRegular"].tap()
        pause(1.2)
        shot("p7-regular-switcher")
        app.terminate()

        // The empty private tab's start screen (`-PlainPrivate`: an empty private tab at launch).
        let start = try launch(["-PlainInMemoryStore", "-PlainPrivate"])
        if start.textFields["searchField"].waitForExistence(timeout: 3), start.textFields["searchField"].hasKeyboardFocus {
            closeSearch(start)
        }
        XCTAssertTrue(start.staticTexts["start.privateTitle"].waitForExistence(timeout: 5))
        pause(1)
        shot("p3-private-start")
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        // A hold before each shot lets a screen the runner can't see (the Duo's inner screen) be
        // captured from outside (`simctl io screenshot`).
        if let hold = Double(ProcessInfo.processInfo.environment["PLAIN_CAPTURE_HOLD"] ?? "") { pause(hold) }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
