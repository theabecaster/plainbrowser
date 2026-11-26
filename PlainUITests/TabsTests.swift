import XCTest

/// Tabs end to end: the gallery over the tab store, flick to close and Reopen, the bar swipe,
/// every tab back after a relaunch, and a private tab leaving no history. Pages come from the
/// local TestServer.
@MainActor
final class TabsTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ arguments: [String] = ["-PlainInMemoryStore"]) throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
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

    private func waitForPage(
        _ app: XCUIApplication, _ heading: String, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let text = app.webViews.staticTexts[heading]
        XCTAssertTrue(text.waitForExistence(timeout: timeout), "page \"\(heading)\" did not show", file: file, line: line)
    }

    private func address(_ path: String) -> String {
        "http://" + server.address(path)
    }

    /// Picks `item` from the tabs button's menu (a long press).
    private func tabsMenu(_ app: XCUIApplication, pick item: String, file: StaticString = #filePath, line: UInt = #line) {
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 2), file: file, line: line)
        tabs.press(forDuration: 1.0)
        // Items with a subtitle read as "title, subtitle": match the start.
        let action = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the tabs menu", file: file, line: line)
        action.tap()
    }

    /// Opens `paths` each in its own tab, the first in the launch tab.
    private func openTabs(_ app: XCUIApplication, _ pages: [(path: String, heading: String)]) {
        for (index, page) in pages.enumerated() {
            if index > 0 { tabsMenu(app, pick: "New Tab") }
            go(app, to: page.path)
            waitForPage(app, page.heading)
        }
    }

    private func openGallery(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["tabs"].tap()
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        return gallery
    }

    private func card(_ gallery: XCUIElement, _ title: String) -> XCUIElement {
        gallery.descendants(matching: .any).matching(identifier: "tabCard").matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Waits until the gallery says it holds `count` tabs (its accessibility value), cards off
    /// screen included: XCUITest lists only the cells on screen.
    private func waitForTabCount(_ gallery: XCUIElement, _ count: Int, timeout: TimeInterval = 4) -> Bool {
        let value = count == 1 ? "1 tab" : "\(count) tabs"
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: gallery)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func testGalleryShowsEveryTabFlickClosesOneAndReopenBringsItBack() throws {
        let app = try launch()
        openTabs(app, [("/a", "Page A"), ("/b", "Page B"), ("/c", "Page C")])
        let gallery = openGallery(app)
        XCTAssertTrue(waitForTabCount(gallery, 3), "the gallery holds \(String(describing: gallery.value)), not 3 tabs")

        // Swipe Page A's card up (scrolled back to the first card: the gallery opens on the
        // selected, last one): it closes, and the toast offers it back.
        gallery.swipeRight(velocity: .fast)
        let first = card(gallery, "Plain Test A")
        XCTAssertTrue(first.waitForExistence(timeout: 2))
        first.swipeUp(velocity: .fast)
        XCTAssertTrue(waitForTabCount(gallery, 2))
        let reopen = app.buttons["reopenTab"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 2))
        reopen.tap()
        XCTAssertTrue(waitForTabCount(gallery, 3))
        XCTAssertTrue(card(gallery, "Plain Test A").waitForExistence(timeout: 2), "Page A came back")

        // Opening a card shows its page with its history.
        card(gallery, "Plain Test A").tap()
        waitForPage(app, "Page A")
        XCTAssertFalse(gallery.exists)
        XCTAssertEqual(app.buttons["addressPill"].value as? String, address("/a"))
    }

    func testSwipingTheAddressBarSwitchesTabs() throws {
        let app = try launch()
        openTabs(app, [("/a", "Page A"), ("/b", "Page B")])
        let pill = app.buttons["addressPill"]
        XCTAssertEqual(pill.value as? String, address("/b"))

        // Finger to the right: the previous tab.
        pill.swipeRight(velocity: .fast)
        waitForPage(app, "Page A")
        XCTAssertEqual(pill.value as? String, address("/a"))
        // And back.
        pill.swipeLeft(velocity: .fast)
        waitForPage(app, "Page B")
        XCTAssertEqual(pill.value as? String, address("/b"))

        // The menu way to the same thing.
        tabsMenu(app, pick: "Previous Tab")
        waitForPage(app, "Page A")
    }

    func testRelaunchRestoresEveryTab() throws {
        var app = try launch(["-PlainTestStore", "-PlainResetStore"])
        openTabs(app, [("/a", "Page A"), ("/b", "Page B"), ("/c", "Page C")])
        // Leaving the app writes the tab list and every tab's state.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        app = try launch(["-PlainTestStore"])
        // Search first; the selected tab is back under the sheet.
        XCTAssertTrue(app.textFields["searchField"].hasKeyboardFocus)
        Thread.sleep(forTimeInterval: 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
        waitForPage(app, "Page C")
        let gallery = openGallery(app)
        XCTAssertTrue(waitForTabCount(gallery, 3), "\(String(describing: gallery.value)) came back, not 3 tabs")
        // A tab that was never on screen this launch opens with its page.
        gallery.swipeRight(velocity: .fast)
        let first = card(gallery, "Plain Test A")
        XCTAssertTrue(first.waitForExistence(timeout: 2))
        first.tap()
        waitForPage(app, "Page A")
    }

    func testPrivateTabLeavesNoHistory() throws {
        let app = try launch()
        go(app, to: "/b")
        waitForPage(app, "Page B")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/a")
        waitForPage(app, "Page A")
        XCTAssertEqual(app.buttons["addressPill"].label, "Private Address")

        app.buttons["more"].tap()
        let history = app.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 3))
        history.tap()
        let sheet = app.otherElements["historySheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 3) || app.navigationBars["History"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Plain Test B"].waitForExistence(timeout: 3), "the regular tab's visit is in history")
        XCTAssertFalse(app.staticTexts["Plain Test A"].exists, "the private tab's visit must not be in history")
    }
}
