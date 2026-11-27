import XCTest

/// The focused address bar (docs/decisions.md, "Address focus and the page sheet"): never empty,
/// a search over a page opens a new tab, editing the page's address stays in its tab, Copy in the
/// field copies, a copied link is offered, and private tabs show no history.
@MainActor
final class AddressFocusTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        let app = XCUIApplication.introSeen()
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 10))
        return app
    }

    /// From the open field (or the pill): types `path`'s address and goes.
    private func go(_ app: XCUIApplication, to path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
        waitForPage(app, heading)
    }

    private func waitForPage(_ app: XCUIApplication, _ heading: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 15), "page \"\(heading)\" did not show", file: file, line: line)
    }

    private func focus(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["addressPill"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        return field
    }

    func testFocusOnAPageShowsThePageFavoritesAndRecentPages() throws {
        let app = try launch(["-PlainSeedFavorites", "-PlainSeedHistory"])
        go(app, to: "/a", heading: "Page A")
        let field = focus(app)
        // The field opens empty: typing goes somewhere new.
        XCTAssertEqual(field.value as? String ?? "", field.placeholderValue ?? "")
        XCTAssertTrue(app.buttons["focus.currentPage"].waitForExistence(timeout: 1), "the page's own row")
        XCTAssertTrue(app.buttons["focus.copyAddress"].exists, "Copy on the page's row")
        XCTAssertTrue(app.buttons["favorite.0"].exists, "favorites above the keyboard")
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion.page.'"))
        XCTAssertGreaterThan(recent.count, 0, "recently visited pages")
        XCTAssertFalse(app.buttons["focus.hint"].exists)
    }

    func testSearchFromAPageOpensANewTabAndKeepsThePage() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        _ = focus(app)
        go(app, to: "/b", heading: "Page B")
        // Page A is still there: Back on the new tab's first page closes it and returns to it.
        let back = app.buttons["back"]
        XCTAssertTrue(back.waitForExistence(timeout: 2))
        XCTAssertTrue(back.isEnabled)
        back.tap()
        waitForPage(app, "Page A")
        XCTAssertFalse(app.buttons["forward"].isEnabled, "Page A's own tab never went to B")
    }

    func testEditingTheAddressLoadsInTheSameTab() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        let field = focus(app)
        app.buttons["focus.currentPage"].tap()
        XCTAssertEqual(field.value as? String, "http://" + server.address("/a"), "the page's address, to edit")
        XCTAssertTrue(app.buttons["field.copy"].exists, "Copy inside the field")
        field.typeText(server.address("/b") + "\n")
        waitForPage(app, "Page B")
        // Same tab: Back goes to A in its history, and Forward returns to B.
        app.buttons["back"].tap()
        waitForPage(app, "Page A")
        XCTAssertTrue(app.buttons["forward"].isEnabled)
    }

    func testThePageSheetsAddressEditsInPlace() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        app.buttons["more"].tap()
        let address = app.buttons["pageSheet.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 3), "the page sheet's address row")
        XCTAssertTrue(app.buttons["menu.copyLink"].exists)
        address.tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertEqual(field.value as? String, "http://" + server.address("/a"))
        XCTAssertFalse(address.exists, "the sheet went down as the field came up")
    }

    func testCopiedLinkIsOfferedOnAnotherPage() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        let field = focus(app)
        app.buttons["focus.currentPage"].tap()
        app.buttons["field.copy"].tap()
        // Still on A: its own address is not offered.
        field.typeText(server.address("/b") + "\n")
        waitForPage(app, "Page B")
        _ = focus(app)
        let copied = app.buttons["focus.copiedLink"]
        XCTAssertTrue(copied.waitForExistence(timeout: 2), "Open Copied Link")
        XCTAssertTrue((copied.value as? String ?? "").contains("/a"), "Plain knows the address it copied")
        copied.tap()
        waitForPage(app, "Page A")
    }

    func testPrivateTabShowsNoHistory() throws {
        let app = try launch(["-PlainSeedHistory"])
        go(app, to: "/a", heading: "Page A")
        app.buttons["more"].tap()
        let privateTab = app.buttons["more.newPrivateTab"]
        XCTAssertTrue(privateTab.waitForExistence(timeout: 3))
        privateTab.tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion.page.'"))
        XCTAssertEqual(recent.count, 0, "no history in a private tab")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'focus.closed.'")).firstMatch.exists)
    }
}
