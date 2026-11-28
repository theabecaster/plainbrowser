import XCTest

/// The search sheet the pill grows into (docs/research/arc-address-expand.md): the field ends at
/// the sheet's top with the rows under it, and every way out is there: the handle, a swipe down,
/// a tap on the dimmed page, and Cancel under a top bar.
@MainActor
final class SearchSheetTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        let app = XCUIApplication.introSeen()
        app.launchArguments += extra
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.typeText(server.address("/a") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 15))
        return app
    }

    private func focus(_ app: XCUIApplication) -> XCUIElement {
        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3))
        pill.tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        // The sheet at rest.
        Thread.sleep(forTimeInterval: 0.6)
        return field
    }

    private func waitForClosed(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3), "the pill rests again", file: file, line: line)
        let gone = NSPredicate { _, _ in !app.keyboards.firstMatch.exists && !app.otherElements["searchCard"].exists }
        let waited = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 3)
        XCTAssertEqual(waited, .completed, "the sheet and the keyboard left", file: file, line: line)
        XCTAssertTrue(app.webViews.staticTexts["Page A"].exists, "the page is still there", file: file, line: line)
    }

    /// A tap on the pill: the field sits at the sheet's top, in the upper part of the screen, and
    /// the rows start right under it, top down.
    func testTapPutsTheFieldAtTheTopWithRowsUnderIt() throws {
        let app = try launch(["-PlainSeedFavorites", "-PlainSeedHistory"])
        let rest = app.buttons["addressPill"].frame
        let field = focus(app)
        let window = app.windows.firstMatch.frame
        let card = app.otherElements["searchCard"]
        XCTAssertTrue(card.exists)
        XCTAssertLessThan(field.frame.midY, window.height * 0.4, "the field is at the top")
        XCTAssertLessThan(field.frame.minY - card.frame.minY, 40, "the field is the sheet's first thing")
        XCTAssertTrue(app.buttons["field.copy"].waitForExistence(timeout: 1), "Copy inside the field, on the page's address")
        let page = app.buttons["suggestion.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 1), "a recent page's row")
        let favorite = app.buttons["favorite.0"]
        XCTAssertTrue(favorite.exists)
        XCTAssertGreaterThan(favorite.frame.minY, field.frame.maxY - 1, "favorites under the field")
        XCTAssertGreaterThan(page.frame.minY, favorite.frame.maxY - 1, "rows under the favorites")
        XCTAssertLessThan(page.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "rows over the keyboard")
        if rest.midY > window.height / 2 {
            // A bottom pill: the page shows above the sheet.
            XCTAssertGreaterThan(card.frame.minY, window.height * 0.1)
            XCTAssertTrue(app.buttons["search.close"].exists, "the sheet's handle")
        }
        field.typeText("pag")
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertLessThan(first.frame.minY - field.frame.maxY, 80, "the best suggestion is right under the field")
    }

    func testSwipeDownDismisses() throws {
        let app = try launch()
        let field = focus(app)
        try XCTSkipUnless(app.buttons["search.close"].exists, "a top bar's sheet has no swipe")
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.6))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 320)), withVelocity: 900, thenHoldForDuration: 0)
        waitForClosed(app)
    }

    /// A short, slow drag springs back: the sheet stays open and the field keeps the keyboard.
    func testShortDragSpringsBack() throws {
        let app = try launch()
        let field = focus(app)
        try XCTSkipUnless(app.buttons["search.close"].exists, "a top bar's sheet has no swipe")
        let top = field.frame.minY
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.6))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 40)), withVelocity: 120, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(field.hasKeyboardFocus)
        XCTAssertEqual(field.frame.minY, top, accuracy: 1, "the field is back at the top")
    }

    func testTapOnThePageDismisses() throws {
        let app = try launch()
        _ = focus(app)
        let card = app.otherElements["searchCard"].frame
        let window = app.windows.firstMatch
        // Outside the card: above a sheet, beside a top bar's card.
        let point = card.minY > 60
            ? CGVector(dx: window.frame.width / 2, dy: card.minY / 2)
            : CGVector(dx: max(8, card.minX / 2), dy: window.frame.height * 0.5)
        window.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
        waitForClosed(app)
    }

    /// The visible way out: the sheet's handle, or Cancel beside a top bar's field.
    func testTheVisibleAffordanceDismisses() throws {
        let app = try launch()
        _ = focus(app)
        let handle = app.buttons["search.close"]
        let cancel = app.buttons["search.cancel"]
        XCTAssertTrue(handle.exists || cancel.exists, "a visible way out")
        (handle.exists ? handle : cancel).tap()
        waitForClosed(app)
    }

    /// The Reopen toast leaves when the sheet opens: it sat over the rows, the closed tab's row
    /// among them (clarity audit).
    func testAToastLeavesWhenTheSheetOpens() throws {
        let app = try launch()
        func tabsMenu(_ item: String) {
            let tabs = app.buttons["tabs"]
            XCTAssertTrue(tabs.waitForExistence(timeout: 2))
            tabs.press(forDuration: 1.0)
            let action = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the tabs menu")
            action.tap()
        }
        tabsMenu("New Tab")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText(server.address("/b") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page B"].waitForExistence(timeout: 15))
        tabsMenu("Close Tab")
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
        let toast = app.buttons["toastButton"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3.5), "the close offers Reopen")
        _ = focus(app)
        let gone = NSPredicate { _, _ in !toast.exists || !toast.isHittable }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 2)
        XCTAssertEqual(result, .completed, "the toast left with the sheet's opening")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "toast-after-open"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Open, close and open again at once: the second tap takes the sheet mid-flight.
    func testReopeningMidCloseEndsOpen() throws {
        let app = try launch()
        let field = focus(app)
        let handle = app.buttons["search.close"]
        try XCTSkipUnless(handle.exists, "a top bar's field does not move")
        handle.tap()
        app.buttons["addressPill"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(field.hasKeyboardFocus)
        XCTAssertLessThan(field.frame.midY, app.windows.firstMatch.frame.height * 0.4)
        XCTAssertTrue(app.otherElements["searchCard"].exists)
    }

    /// Browse for Me from the field: armed while empty, Return browses; and the row under the
    /// field while typing.
    func testBrowseForMeIsReachableFromTheField() throws {
        let app = try launch(["-PlainTestSummaries"])
        let field = focus(app)
        let option = app.buttons["field.browse"]
        XCTAssertTrue(option.waitForExistence(timeout: 2), "Browse for Me in the empty field")
        field.typeText("trail shoes")
        let row = app.buttons["browseForMe"]
        XCTAssertTrue(row.waitForExistence(timeout: 2), "the row under the field while typing")
        XCTAssertLessThan(row.frame.minY - field.frame.maxY, 30)
        XCTAssertFalse(option.exists, "typing swaps the options for the clear button")
        field.clearText()
        XCTAssertTrue(option.waitForExistence(timeout: 2))
        option.tap()
        XCTAssertEqual(option.value as? String, "On")
        field.typeText("trail shoes\n")
        XCTAssertTrue(app.staticTexts["Browse for Me"].waitForExistence(timeout: 5), "Return browsed")
    }

    /// The microphone dictates into the field (a scripted phrase here) and suggestions follow.
    func testMicrophoneDictatesIntoTheField() throws {
        let app = try launch(["-PlainTestDictation"])
        let field = focus(app)
        let mic = app.buttons["field.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 2))
        mic.tap()
        let heard = NSPredicate { _, _ in (field.value as? String) == "plain browser" }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: heard, object: nil)], timeout: 3), .completed)
        XCTAssertTrue(field.hasKeyboardFocus)
    }

    /// Turning the phone with the sheet open lays it out again: the field stays on screen at the
    /// top, inside its card, and turning back restores it.
    func testRotationWhileOpenLaysOutAgain() throws {
        let app = try launch()
        let field = focus(app)
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1.5)
            let window = app.windows.firstMatch.frame
            let card = app.otherElements["searchCard"].frame
            XCTAssertTrue(field.hasKeyboardFocus, "the field keeps the keyboard")
            XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(field.frame), "the field is on screen: \(field.frame) in \(window)")
            XCTAssertTrue(card.insetBy(dx: -1, dy: -1).contains(field.frame), "the field is in its card: \(field.frame) in \(card)")
            XCTAssertLessThan(field.frame.minY, window.height * 0.45)
        }
    }
}
