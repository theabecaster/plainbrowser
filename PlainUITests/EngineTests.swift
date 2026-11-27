import XCTest

/// The shell on the web engine: pages load through the tab model and come back after a relaunch,
/// Desktop Site is remembered for the site, blocking turns off and on per site, and reader mode
/// opens on an article and closes back to the page. Pages come from the local TestServer.
@MainActor
final class EngineTests: XCTestCase {
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

    private func waitForPage(
        _ app: XCUIApplication, _ heading: String, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let text = app.webViews.staticTexts[heading]
        XCTAssertTrue(text.waitForExistence(timeout: timeout), "page \"\(heading)\" did not show", file: file, line: line)
    }

    /// Opens the page menu from More and returns `item`, or nil when the menu doesn't have it (the
    /// menu is closed again then).
    private func menuItem(_ app: XCUIApplication, _ item: String, timeout: TimeInterval = 3) -> XCUIElement? {
        let more = app.buttons["more"]
        XCTAssertTrue(more.waitForExistence(timeout: 2))
        more.tap()
        let action = app.buttons[item]
        // Desktop Site and the blocking toggle live in the Site Settings submenu.
        let site = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Site Settings'")).firstMatch
        if !action.waitForExistence(timeout: 1), site.exists { site.tap() }
        guard action.waitForExistence(timeout: timeout) else {
            // Close the menu with a tap above it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            // The page sheet goes down before the next tap can reach the bar.
            _ = app.buttons["menu.settings"].waitForNonExistence(timeout: 3)
            return nil
        }
        return action
    }

    private func pageMenu(_ app: XCUIApplication, pick item: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let action = menuItem(app, item) else {
            return XCTFail("\"\(item)\" is not in the page menu", file: file, line: line)
        }
        action.tap()
    }

    func testPageLoadsThroughTheEngineAndComesBackAfterRelaunch() throws {
        var app = try launch(["-PlainTestStore", "-PlainResetStore"])
        go(app, to: "/a")
        waitForPage(app, "Page A")
        let pill = app.buttons["addressPill"]
        XCTAssertEqual(pill.value as? String, "http://" + server.address("/a"))
        XCTAssertFalse(app.buttons["back"].isEnabled, "a first page has nothing to go back to")
        app.webViews.links["Go to B"].tap()
        waitForPage(app, "Page B")
        XCTAssertTrue(app.buttons["back"].isEnabled)
        // Leaving the app saves every tab (the engine also saves a second after each load).
        XCUIApplication.leaveForAnotherApp()
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        app = try launch(["-PlainTestStore"])
        // The last page, as it was: the bar resting, no keyboard.
        waitForPage(app, "Page B")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let restoredPill = app.buttons["addressPill"]
        XCTAssertTrue(restoredPill.waitForExistence(timeout: 2))
        XCTAssertEqual(restoredPill.value as? String, "http://" + server.address("/b"))
        // History came back with it.
        let back = app.buttons["back"]
        XCTAssertTrue(back.isEnabled)
        back.tap()
        waitForPage(app, "Page A")
    }

    func testDesktopSiteIsRememberedAcrossReloads() throws {
        let app = try launch()
        go(app, to: "/ua")
        waitForPage(app, "Mobile UA")

        pageMenu(app, pick: "Desktop Site")
        waitForPage(app, "Desktop UA")
        pageMenu(app, pick: "Reload")
        waitForPage(app, "Desktop UA")
        // Another page of the same site loads as desktop too.
        go(app, to: "/ua?again")
        waitForPage(app, "Desktop UA")

        pageMenu(app, pick: "Desktop Site")
        waitForPage(app, "Mobile UA")
        pageMenu(app, pick: "Reload")
        waitForPage(app, "Mobile UA")
    }

    func testBlockingTurnsOffAndOnForTheSite() throws {
        let app = try launch()
        go(app, to: "/blocking")
        // The first launch on a simulator compiles the rule lists in the background (seconds);
        // reload until they apply.
        let blocked = app.webViews.staticTexts["Ad blocked"]
        let deadline = Date().addingTimeInterval(90)
        while !blocked.waitForExistence(timeout: 3), Date() < deadline {
            pageMenu(app, pick: "Reload")
        }
        XCTAssertTrue(blocked.exists, "the rule lists never blocked the test ad")

        pageMenu(app, pick: "Turn Off Blocking on This Site")
        waitForPage(app, "Ad loaded")
        pageMenu(app, pick: "Reload")
        waitForPage(app, "Ad loaded")

        pageMenu(app, pick: "Turn On Blocking on This Site")
        waitForPage(app, "Ad blocked")
    }

    func testReaderOpensOnAnArticleAndBackReturnsToThePage() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        XCTAssertNil(menuItem(app, "Show Reader", timeout: 1), "Page A is no article: no Show Reader")

        go(app, to: "/article")
        waitForPage(app, "The Quiet Page")
        // The readerable check reports at DOMContentLoaded; the menu reads its answer.
        var show = menuItem(app, "Show Reader")
        if show == nil { show = menuItem(app, "Show Reader") }
        try XCTUnwrap(show, "an article offers Show Reader").tap()

        let reader = app.webViews["readerView"]
        XCTAssertTrue(reader.waitForExistence(timeout: 5), "the reader view did not open")
        XCTAssertTrue(reader.staticTexts["The Quiet Page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["back"].isEnabled, "Back closes the reader")

        app.buttons["back"].tap()
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: reader)], timeout: 3)
        waitForPage(app, "The Quiet Page")

        // A link in the reader closes it and opens in the tab.
        pageMenu(app, pick: "Show Reader")
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        let link = reader.links["read page B"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        waitForPage(app, "Page B")
        XCTAssertFalse(reader.exists)
    }
}
