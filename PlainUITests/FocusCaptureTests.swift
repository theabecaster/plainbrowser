import XCTest

/// Screenshots of the focused address bar (docs/research/address-focus.md), for design review:
/// the start screen, a loaded page, typing, and the page sheet. Not a test of behavior: it skips
/// itself unless `PLAIN_CAPTURE=1` reaches the runner (`TEST_RUNNER_PLAIN_CAPTURE=1`).
/// `PLAIN_CAPTURE_FAVORITES=1` seeds favorites and `PLAIN_CAPTURE_HISTORY=1` a few visited pages;
/// `PLAIN_CAPTURE_TAG` names the shots (for example `17-dark`).
@MainActor
final class FocusCaptureTests: XCTestCase {
    private var tag = ""

    func testCaptureAddressFocus() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        tag = environment["PLAIN_CAPTURE_TAG"] ?? "shot"
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        if environment["PLAIN_CAPTURE_FAVORITES"] == "1" { app.launchArguments += ["-PlainSeedFavorites"] }
        if environment["PLAIN_CAPTURE_HISTORY"] == "1" { app.launchArguments += ["-PlainSeedHistory"] }
        // Browse for Me with the scripted model, where Apple Intelligence can't run.
        if environment["PLAIN_CAPTURE_AI"] == "1" { app.launchArguments += ["-PlainTestSummaries"] }
        if let corner = environment["PLAIN_CAPTURE_CORNER"] { app.launchArguments += ["-PlainStatusCorner", corner] }
        app.launch()

        if environment["PLAIN_CAPTURE_ORIENTATION"] == "landscape" { XCUIDevice.shared.orientation = .landscapeLeft }
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        pause(2)
        shot("1-start-focus")

        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 15))
        pause(2)
        shot("2-page")

        app.buttons["addressPill"].tap()
        pause(0.05)
        shot("3-page-focus-first-frames")
        pause(1.2)
        shot("4-page-focus")
        if environment["PLAIN_CAPTURE_DEBUG"] == "1" { print("HIERARCHY\n" + app.debugDescription) }

        field.typeText("pla")
        pause(1.5)
        shot("5-page-typing")

        // The empty field's options: Browse for Me armed, then dictation (scripted).
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        let browse = app.buttons["field.browse"]
        if browse.waitForExistence(timeout: 1) {
            browse.tap()
            pause(0.6)
            shot("5a-browse-armed")
            browse.tap()
        }

        // Close the search (the sheet's handle, or Cancel under a top bar), then open the page
        // sheet (More, or a long press on the pill where More sits in the system bar).
        let close = app.buttons["search.close"]
        let cancel = app.buttons["search.cancel"]
        if close.exists, close.isHittable { close.tap() } else if cancel.exists { cancel.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
        pause(1.2)
        shot("5b-closed")
        let more = app.buttons["more"]
        let pill = app.buttons["addressPill"]
        if (more.exists && more.isHittable) || pill.exists {
            if more.exists, more.isHittable { more.tap() } else { pill.press(forDuration: 0.8) }
            pause(1.2)
            shot("6-page-sheet")
            let host = app.buttons["pageSheet.address"]
            if host.waitForExistence(timeout: 2) {
                host.tap()
                pause(1.2)
                shot("7-edit-address")
            }
        }
    }

    /// Holds the sheet open over a page and shoots every 3 s for 36 s, while the script folds,
    /// unfolds or rotates the device (`MARK hold` in the log says when it started).
    func testCaptureHoldOpen() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        tag = environment["PLAIN_CAPTURE_TAG"] ?? "hold"
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainSeedFavorites", "-PlainSeedHistory"]
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 15))
        pause(1)
        app.buttons["addressPill"].tap()
        pause(1.5)
        print("MARK hold")
        let rotates = environment["PLAIN_CAPTURE_ROTATE"] == "1"
        for step in 0..<12 {
            shot(String(format: "hold-%02d", step))
            if rotates, step == 2 { XCUIDevice.shared.orientation = .landscapeLeft }
            if rotates, step == 5 { XCUIDevice.shared.orientation = .portrait }
            pause(3)
        }
        // After it all: the sheet still closes to the resting pill.
        let close = app.buttons["search.close"]
        let cancel = app.buttons["search.cancel"]
        if close.exists, close.isHittable { close.tap() } else if cancel.exists, cancel.isHittable { cancel.tap() }
        pause(1.5)
        shot("hold-closed")
    }

    /// The same states with no touch at all: Command-L opens, Command-period closes. For the simulator's
    /// resizable window (the stand-in for the Duo's inner screen where Device Hub can't be
    /// driven), where XCUITest's taps miss: the window reports its frames at a third of their size.
    func testCaptureByKeyboard() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        tag = environment["PLAIN_CAPTURE_TAG"] ?? "keys"
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainSeedFavorites", "-PlainSeedHistory", "-PlainTestSummaries"]
        if let corner = environment["PLAIN_CAPTURE_CORNER"] { app.launchArguments += ["-PlainStatusCorner", corner] }
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        pause(2)
        shot("1-start-focus")
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 15))
        pause(2)
        shot("2-page")
        // Closed, the sheet is out of the hierarchy's reach.
        XCTAssertFalse(app.otherElements["searchCard"].exists, "the sheet is gone after the first close")
        print("MARK open")
        app.typeKey("l", modifierFlags: .command)
        pause(0.05)
        shot("3-page-focus-first-frames")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Command-L opened the search sheet")
        pause(1.2)
        shot("4-page-focus")
        field.typeText("pla")
        pause(1.5)
        shot("5-page-typing")
        print("MARK close")
        app.typeKey(".", modifierFlags: .command)
        pause(1.5)
        shot("6-closed")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Command-period closed the search sheet")
        app.typeKey("l", modifierFlags: .command)
        pause(1.5)
        // Held open while the window is resized from outside (a fold, a rotation).
        print("MARK hold")
        for step in 0..<10 {
            shot(String(format: "hold-%02d", step))
            pause(3)
        }
        app.typeKey(".", modifierFlags: .command)
        pause(1.5)
        shot("hold-closed")
    }

    /// The sheet under a top bar, by touch: Cancel, a tap on the dimmed page and a swipe down
    /// each close it. Runs in the simulator's resizable window too (`PLAIN_TAP_SCALE`).
    func testCaptureDropdownTouch() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        tag = environment["PLAIN_CAPTURE_TAG"] ?? "touch"
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainSeedFavorites", "-PlainSeedHistory"]
        if let corner = environment["PLAIN_CAPTURE_CORNER"] { app.launchArguments += ["-PlainStatusCorner", corner] }
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 15))
        pause(1.5)
        let pill = app.buttons["addressPill"]
        let keyboard = app.keyboards.firstMatch
        func open(_ name: String) {
            tap(pill, app)
            XCTAssertTrue(keyboard.waitForExistence(timeout: 4), "\(name): the tap opened the sheet")
            pause(1)
        }
        func closed(_ name: String) {
            let gone = NSPredicate { _, _ in !keyboard.exists }
            let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 4)
            XCTAssertEqual(result, .completed, "\(name) closed the sheet")
            pause(1)
            shot(name)
        }
        open("cancel")
        shot("1-open")
        tap(app.buttons["search.cancel"], app)
        closed("2-after-cancel")
        open("page")
        // The dimmed page beside the card, at the window's leading edge.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 320)).tap()
        closed("3-after-page-tap")
        open("swipe")
        let frame = app.otherElements["searchCard"].frame
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX * tapScale, dy: (frame.minY + 120 / tapScale) * tapScale))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)))
        closed("4-after-swipe")
    }

    /// The sheet over split panes and beside the open side pane (the Duo's inner screen).
    func testCaptureSplitAndSidePane() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        tag = environment["PLAIN_CAPTURE_TAG"] ?? "split"
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        if let corner = environment["PLAIN_CAPTURE_CORNER"] { app.launchArguments += ["-PlainStatusCorner", corner] }
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        try XCTSkipUnless(app.windows.firstMatch.frame.width * tapScale >= 900, "needs the Duo's inner screen in landscape")
        let pill = app.buttons["addressPill"]
        func go(_ path: String, _ heading: String) {
            if !(field.exists && field.hasKeyboardFocus) { tap(pill, app) }
            field.typeText(server.address(path) + "\n")
            XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10))
        }
        func pageMenu(_ item: String) {
            press(pill, app)
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 3), "\(item) is not in the page menu")
            tap(app.buttons[item], app)
        }
        func focusShot(_ name: String) {
            pause(1)
            tap(pill, app)
            pause(1.5)
            shot(name)
            field.typeText("pla")
            pause(1.2)
            shot(name + "-typing")
            let cancel = app.buttons["search.cancel"]
            tap(cancel.exists ? cancel : app.buttons["search.close"], app)
            pause(1.2)
            shot(name + "-closed")
        }
        go("/a", "Page A")
        press(app.buttons["tabs"], app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Tab")).firstMatch, app)
        go("/b", "Page B")
        pageMenu("menu.otherPane")
        focusShot("split")
        pageMenu("menu.closePane")
        pause(1)
        tap(app.buttons["more"].firstMatch, app)
        if app.buttons["menu.sidePane"].waitForExistence(timeout: 3) {
            tap(app.buttons["menu.sidePane"], app)
            focusShot("sidepane")
        }
    }

    /// The simulator's resizable window reports its frames at a third of their size while touches
    /// land in real points (`PLAIN_TAP_SCALE=3` there): a tap goes to the frame's center, scaled.
    private var tapScale: CGFloat {
        CGFloat(Double(ProcessInfo.processInfo.environment["PLAIN_TAP_SCALE"] ?? "") ?? 1)
    }

    private func point(_ element: XCUIElement, _ app: XCUIApplication) -> XCUICoordinate {
        let frame = element.frame
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX * tapScale, dy: frame.midY * tapScale))
    }

    private func tap(_ element: XCUIElement, _ app: XCUIApplication) {
        if tapScale == 1 { element.tap() } else { point(element, app).tap() }
    }

    private func press(_ element: XCUIElement, _ app: XCUIApplication) {
        if tapScale == 1 { element.press(forDuration: 1.0) } else { point(element, app).press(forDuration: 1.0) }
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Every screen that shows something (the Duo's inner screen when it is open), named by size.
    private func shot(_ name: String) {
        for screen in XCUIScreen.screens {
            let image = screen.screenshot()
            let size = image.image.size
            let suffix = XCUIScreen.screens.count > 1 ? "-\(Int(size.width))x\(Int(size.height))" : ""
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = "\(tag)-\(name)\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
