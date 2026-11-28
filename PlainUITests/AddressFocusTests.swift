import XCTest

/// The focused address bar (docs/decisions.md, "Address focus and the page sheet" and "The page's
/// address in the field"): never empty, the page's address opens selected with Copy inside the
/// field, typing over it opens a new tab, editing part of it stays in its tab, Copy copies, a
/// copied link is offered, and private tabs show no history.
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

    /// Puts the caret at the end of the field's text, as a tap past the text does (just before
    /// Copy; the test addresses are short): the opening selection goes, and what is typed next
    /// edits the address.
    private func placeCaretAtEnd(_ field: XCUIElement, _ app: XCUIApplication) {
        let copy = app.buttons["field.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 2))
        // The sheet at rest: the field stops moving.
        var last = field.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if field.frame == last { break }
            last = field.frame
        }
        let x = copy.frame.minX - field.frame.minX - 10
        field.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: field.frame.height / 2)).tap()
        Thread.sleep(forTimeInterval: 0.4)
    }

    func testFocusOnAPageShowsItsAddressFavoritesAndRecentPages() throws {
        let app = try launch(["-PlainSeedFavorites", "-PlainSeedHistory"])
        go(app, to: "/a", heading: "Page A")
        let field = focus(app)
        // The field opens with the page's address and Copy inside it; no row stands for the page.
        XCTAssertEqual(field.value as? String, "http://" + server.address("/a"), "the page's address in the field")
        XCTAssertTrue(app.buttons["field.copy"].waitForExistence(timeout: 1), "Copy inside the field")
        XCTAssertFalse(app.buttons["focus.currentPage"].exists, "no suggestion-like row for the page")
        XCTAssertFalse(app.buttons["focus.copyAddress"].exists)
        XCTAssertTrue(app.buttons["favorite.0"].exists, "favorites above the keyboard")
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion.page.'"))
        XCTAssertGreaterThan(recent.count, 0, "recently visited pages")
        XCTAssertFalse(app.buttons["focus.hint"].exists)
    }

    /// The address opens all selected: the first keystroke replaces it, and Copy gives way to the
    /// field's own controls.
    func testTheAddressOpensSelected() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        let field = focus(app)
        XCTAssertTrue(app.buttons["field.copy"].waitForExistence(timeout: 1))
        field.typeText("q")
        XCTAssertEqual(field.value as? String, "q", "one keystroke replaced the whole address")
        XCTAssertFalse(app.buttons["field.copy"].exists, "Copy only while the address is untouched")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(field.value as? String ?? "", field.placeholderValue ?? "", "cleared")
        XCTAssertFalse(app.buttons["field.copy"].exists)
    }

    /// Typing over the selected address is a new query: it opens a new tab and keeps the page.
    func testReplacingTheAddressOpensANewTabAndKeepsThePage() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        let field = focus(app)
        XCTAssertEqual(field.value as? String, "http://" + server.address("/a"))
        go(app, to: "/b", heading: "Page B")
        // Page A is still there: Back on the new tab's first page closes it and returns to it.
        let back = app.buttons["back"]
        XCTAssertTrue(back.waitForExistence(timeout: 2))
        XCTAssertTrue(back.isEnabled)
        back.tap()
        waitForPage(app, "Page A")
        // Forward shows only where there is somewhere to go (a phone's bar leaves it out).
        let forward = app.buttons["forward"]
        XCTAssertFalse(forward.exists && forward.isEnabled, "Page A's own tab never went to B")
    }

    /// The caret put in the address and part of it changed: an edit of this page, in its tab.
    func testEditingTheAddressLoadsInTheSameTab() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        let field = focus(app)
        XCTAssertEqual(field.value as? String, "http://" + server.address("/a"), "the page's address, to edit")
        placeCaretAtEnd(field, app)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(field.value as? String, "http://" + server.address("/"), "one letter went, the rest stayed")
        XCTAssertFalse(app.buttons["field.copy"].exists, "Copy only while the address is untouched")
        field.typeText("b\n")
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
        XCTAssertTrue(app.buttons["field.copy"].exists, "Copy inside the field")
        // The caret waits at the end: what is typed edits this page, in its tab.
        Thread.sleep(forTimeInterval: 0.6)
        field.typeText(XCUIKeyboardKey.delete.rawValue + "b\n")
        waitForPage(app, "Page B")
        app.buttons["back"].tap()
        waitForPage(app, "Page A")
        XCTAssertTrue(app.buttons["forward"].isEnabled, "the same tab went to B")
    }

    /// Copy inside the field copies the page's address and says so; another page offers it.
    func testCopiedLinkIsOfferedOnAnotherPage() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        let field = focus(app)
        let copy = app.buttons["field.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 1))
        copy.tap()
        XCTAssertEqual(copy.label, "Copied", "the check mark answers the copy")
        // Still on A: its own address is not offered.
        XCTAssertFalse(app.buttons["focus.copiedLink"].exists, "the page on screen is never offered")
        XCTAssertEqual(field.value as? String, "http://" + server.address("/a"), "the address stays, selected")
        field.typeText(server.address("/b") + "\n")
        waitForPage(app, "Page B")
        _ = focus(app)
        let copied = app.buttons["focus.copiedLink"]
        XCTAssertTrue(copied.waitForExistence(timeout: 2), "Open Copied Link")
        XCTAssertTrue((copied.value as? String ?? "").contains("/a"), "Plain knows the address it copied")
        copied.tap()
        waitForPage(app, "Page A")
    }

    /// A favorite picked from the untouched address goes somewhere new: a new tab, the page kept.
    func testAFavoriteFromThePageOpensANewTab() throws {
        let app = try launch(["-PlainSeedFavorites"])
        go(app, to: "/a", heading: "Page A")
        _ = focus(app)
        let favorite = app.buttons["favorite.0"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 2))
        favorite.tap()
        XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let back = app.buttons["back"]
        XCTAssertTrue(back.waitForExistence(timeout: 2))
        XCTAssertTrue(back.isEnabled, "the new tab's first page goes back to the page")
        back.tap()
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
