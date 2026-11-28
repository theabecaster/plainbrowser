import XCTest

/// The haptics, end to end (docs/research/haptics.md §6.2): each gesture or action plays exactly
/// the kinds listed, once, with no double fire, read from the app's `-PlainHapticLog`. The
/// simulator has no Taptic Engine, so this checks what plays and when in order, not the feel; the
/// owner's Duo checklist covers that (docs/research/haptics-checklist.md).
@MainActor
final class HapticsTests: XCTestCase {
    private var server: TestServer!

    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication.introSeen()
        app.launchArguments += [XCUIApplication.hapticLogArgument, "-PlainTranslateHintShown", "YES"]
        app.launch()
        XCTAssertTrue(app.waitForFirstScreen())
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "plainHapticLog").firstMatch.waitForExistence(timeout: 5),
                      "the app shows no haptic log")
        return app
    }

    private func go(_ app: XCUIApplication, to path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show")
        // The bar at rest before a gesture starts on it.
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func newTab(_ app: XCUIApplication) {
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 2))
        tabs.press(forDuration: 1.0)
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }

    /// Two tabs, Page A then Page B (on screen).
    private func twoTabs(_ app: XCUIApplication) {
        go(app, to: "/a", heading: "Page A")
        newTab(app)
        go(app, to: "/b", heading: "Page B")
    }

    /// Drags from `start` by `offset`, at `speed` pt/s, holding `hold` seconds before lifting
    /// (0: a flick that lifts while moving).
    private func drag(from start: XCUICoordinate, by offset: CGVector, speed: CGFloat, hold: TimeInterval) {
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(offset), withVelocity: XCUIGestureVelocity(speed), thenHoldForDuration: hold)
    }

    private func pillPoint(_ app: XCUIApplication, x: CGFloat = 0.5) -> XCUICoordinate {
        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 2))
        return pill.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5))
    }

    // MARK: Bar swipe

    /// A slow swipe arms once at half the width and lands silently; a flick that never armed
    /// ticks once as it commits.
    func testBarSwipeArmsOnceAndAFlickTicksOnce() throws {
        let app = try launch()
        twoTabs(app)
        let width = app.frame.width
        app.expectHaptics(["threshold"]) {
            drag(from: pillPoint(app, x: 0.1), by: CGVector(dx: width * 0.7, dy: 0), speed: 400, hold: 0.3)
        }
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        app.expectHaptics(["selection"]) {
            // Well short of half the width, lifted while moving: the projection carries it over.
            drag(from: pillPoint(app, x: 0.7), by: CGVector(dx: -min(140, width * 0.3), dy: 0), speed: 1200, hold: 0)
        }
        XCTAssertTrue(app.webViews.staticTexts["Page B"].waitForExistence(timeout: 5))
    }

    /// Past the last tab the New Tab card arms once, and the new tab opens silently.
    func testNewTabCardArmsOnceAndOpensSilently() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        let width = app.frame.width
        app.expectHaptics(["threshold"]) {
            drag(from: pillPoint(app, x: 0.9), by: CGVector(dx: -width * 0.75, dy: 0), speed: 400, hold: 0.4)
        }
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5), "the new tab's search field")
    }

    // MARK: Swipe up into the gallery

    func testSwipeUpArmsOnceAndOpensTheGallerySilently() throws {
        let app = try launch()
        twoTabs(app)
        let height = app.frame.height
        app.expectHaptics(["threshold"]) {
            drag(from: pillPoint(app), by: CGVector(dx: 0, dy: -height * 0.3), speed: 400, hold: 0.4)
        }
        XCTAssertTrue(app.scrollViews["tabGallery"].waitForExistence(timeout: 3), "the gallery opened")
    }

    // MARK: Gallery cards

    /// A card lifted past its close line arms, and the release closes it with the soft close.
    func testCardPastTheLineArmsThenClosesSoftly() throws {
        let app = try launch()
        twoTabs(app)
        app.buttons["tabs"].tap()
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        let card = gallery.descendants(matching: .any).matching(identifier: "tabCard")
            .matching(NSPredicate(format: "label BEGINSWITH 'Plain Test B'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.6)
        let lift = card.frame.height * 0.7
        app.expectHaptics(["threshold", "close"]) {
            drag(from: card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)), by: CGVector(dx: 0, dy: -lift), speed: 400, hold: 0.4)
        }
        let one = NSPredicate(format: "value == '1 tab'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: one, object: gallery)], timeout: 4), .completed)
    }

    /// A short held drag that never reaches the line plays nothing, and the card stays.
    func testShortCardDragIsSilent() throws {
        let app = try launch()
        twoTabs(app)
        app.buttons["tabs"].tap()
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        let card = gallery.descendants(matching: .any).matching(identifier: "tabCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.6)
        app.expectHaptics([]) {
            drag(from: card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)), by: CGVector(dx: 0, dy: -60), speed: 300, hold: 0.4)
        }
    }

    // MARK: Page sheet

    /// A tick per zoom step, a light tap at 100% (the detent).
    func testZoomTicksPerStepAndTapsAtActualSize() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        app.buttons["more"].tap()
        let zoomIn = app.buttons["menu.zoomIn"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 3))
        app.expectHaptics(["selection", "selection", "tap"]) {
            zoomIn.tap()
            app.buttons["menu.zoomIn"].tap()
            app.buttons["menu.zoomReset"].tap()
        }
        app.expectHaptics(["selection", "tap"]) {
            app.buttons["menu.zoomOut"].tap()
            app.buttons["menu.zoomIn"].tap()
        }
    }

    func testCopyLinkSucceedsOnce() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        app.buttons["more"].tap()
        let copy = app.buttons["menu.copyLink"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        app.expectHaptics(["success"]) { copy.tap() }
    }

    // MARK: Refusals and outcomes

    /// Return in an empty field bumps once (the rate limit itself is HapticTests').
    func testReturnInAnEmptyFieldBumps() throws {
        let app = try launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.expectHaptics(["nothingThere"]) { field.typeText("\n") }
    }

    /// A download plays a tap as it starts and a success with its toast.
    func testDownloadTapsThenSucceedsWithItsToast() throws {
        let app = try launch()
        go(app, to: "/files", heading: "Files")
        // The slow file: it starts at once and lands half a second later, so the two outcomes
        // are two moments (inside 60 ms the throttle would rightly keep only the first).
        let link = app.webViews.links["Download notes slowly"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        app.expectHaptics(["tap", "success"]) { link.tap() }
        XCTAssertTrue(app.buttons["toastButton"].waitForExistence(timeout: 3), "the downloaded toast")
    }

    /// Scrolling a page, with the chrome collapsing and coming back, plays nothing.
    func testScrollingIsSilent() throws {
        let app = try launch()
        go(app, to: "/article", heading: "The Quiet Page")
        let page = app.webViews.firstMatch
        app.expectHaptics([], settle: 1.5) {
            page.swipeUp(velocity: .fast)
            page.swipeUp(velocity: .slow)
            // Back a little, never to the top (a pull there is pull to refresh).
            drag(from: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)), by: CGVector(dx: 0, dy: 120), speed: 600, hold: 0)
        }
    }
}
