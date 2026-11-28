import XCTest

/// The side pane's divider on a wide screen (the Duo's inner screen, an iPad window): drag to
/// resize, the rests, the pane taking the whole width and giving it back, dragging the pane thin
/// to close it, rotation, the haptics on the way, the menu, VoiceOver's adjust and a relaunch
/// (docs/research/resizable-pane.md). Elsewhere (a phone, the outer screen) they skip.
@MainActor
final class SidePaneDividerTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ arguments: [String] = []) throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication.isolated()
        app.launchArguments += [XCUIApplication.hapticLogArgument] + arguments
        app.launch()
        XCTAssertTrue(app.waitForFirstScreen())
        let width = app.windows.firstMatch.frame.width
        try XCTSkipUnless(width >= 600, "needs a wide screen (window is \(Int(width)) pt wide)")
        return app
    }

    private func go(_ app: XCUIApplication, to path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].firstMatch.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show")
    }

    private func more(_ app: XCUIApplication, pick item: String, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["more"].firstMatch.tap()
        let action = app.buttons[item]
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in More", file: file, line: line)
        action.tap()
    }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5, _ message: @autoclosure () -> String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message(), file: file, line: line)
    }

    /// The page on a long article with the pane open beside it, at rest.
    private func openPane(_ app: XCUIApplication) -> (pane: XCUIElement, divider: XCUIElement) {
        go(app, to: "/long", heading: "Long Read")
        more(app, pick: "menu.sidePane")
        let pane = app.otherElements["sidePane"]
        XCTAssertTrue(pane.waitForExistence(timeout: 3))
        let divider = app.descendants(matching: .any)["sidePane.divider"]
        XCTAssertTrue(divider.waitForExistence(timeout: 3), "the divider's handle shows on the seam")
        Thread.sleep(forTimeInterval: 0.6)
        return (pane, divider)
    }

    /// The pages' span: the window less a rail (Tab Layout Above by default: none).
    private func span(_ app: XCUIApplication) -> CGRect { app.windows.firstMatch.frame }

    /// Drags the handle sideways by `dx` at `speed` pt/s, holding `hold` s before lifting.
    private func drag(_ divider: XCUIElement, by dx: CGFloat, speed: CGFloat = 600, hold: TimeInterval = 0.25) {
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)),
                    withVelocity: XCUIGestureVelocity(speed), thenHoldForDuration: hold)
    }

    private func isWidth(_ pane: XCUIElement, _ share: CGFloat, of window: CGRect, minimum: CGFloat = 250) -> Bool {
        let expected = max(minimum, (window.width * share).rounded())
        return abs(pane.frame.width - expected) <= 2 && abs(pane.frame.maxX - window.maxX) <= 1
    }

    func testDragRestsAtHalfThenBackAtNarrowAndThePageFollows() throws {
        let app = try launch()
        let (pane, divider) = openPane(app)
        let window = span(app)
        XCTAssertTrue(isWidth(pane, 0.3, of: window), "opens Narrow (\(pane.frame))")
        // Half fits only where it leaves the page 375 pt (the inner landscape, iPads).
        try XCTSkipUnless(window.width * 0.5 >= 375, "no Half on this width")
        let half = window.width * 0.5
        drag(divider, by: -(half - pane.frame.width))
        wait({ self.isWidth(pane, 0.5, of: window) }, "rests at Half (\(pane.frame))")
        let heading = app.webViews.staticTexts["Long Read"]
        wait({ heading.frame.maxX <= pane.frame.minX + 1 }, "the page is beside the pane at its new width")
        XCTAssertEqual(divider.value as? String, "Half, 50 percent")
        // A short drag springs back to the rest it left.
        drag(divider, by: 40)
        wait({ self.isWidth(pane, 0.5, of: window) }, "a short drag springs back to Half")
        drag(divider, by: half - window.width * 0.3)
        wait({ self.isWidth(pane, 0.3, of: window) }, "back to Narrow (\(pane.frame))")
    }

    func testDragPastThePagesMinimumTakesTheWholeWidthAndTheButtonGivesItBack() throws {
        let app = try launch()
        let (pane, divider) = openPane(app)
        let window = span(app)
        // Past Half (a tick, where Half fits), then the line (the threshold); the release is silent.
        let passesHalf = window.width * 0.5 >= 375
        app.expectHaptics(passesHalf ? ["selection", "threshold"] : ["threshold"]) {
            drag(divider, by: -(window.width - pane.frame.width - 120), speed: 900, hold: 0.4)
        }
        wait({ abs(pane.frame.minX - window.minX) <= 1 && abs(pane.frame.width - window.width) <= 1 },
             "the pane has the whole width (\(pane.frame))")
        XCTAssertFalse(app.webViews.staticTexts["Long Read"].isHittable, "the page is out of sight")
        XCTAssertTrue(app.buttons["addressPill"].firstMatch.exists, "the top bar stays, spanning the pane")
        let expand = app.buttons["sidePane.expand"]
        XCTAssertEqual(expand.label, "Show Page")
        expand.tap()
        wait({ self.isWidth(pane, 0.3, of: window) }, "the page comes back at the window's width")
        wait({ app.webViews.staticTexts["Long Read"].isHittable }, "and shows again")
        XCTAssertEqual(app.buttons["sidePane.expand"].label, "Full Width")
        // The button hands it the whole width too, and a drag from the leading edge gives it back.
        app.buttons["sidePane.expand"].tap()
        wait({ abs(pane.frame.width - window.width) <= 1 }, "Full Width takes the whole width")
        Thread.sleep(forTimeInterval: 0.5)
        drag(divider, by: window.width * 0.62)
        wait({ !self.isWidth(pane, 1, of: window, minimum: 0) && pane.frame.minX > window.minX + 100 },
             "a drag from the leading edge gives the page back (\(pane.frame))")
    }

    func testDraggingThePaneThinClosesIt() throws {
        let app = try launch()
        let (pane, divider) = openPane(app)
        app.expectHaptics(["threshold"]) {
            drag(divider, by: pane.frame.width - 60, speed: 700, hold: 0.4)
        }
        wait({ !pane.exists || !pane.isHittable || pane.frame.width < 1 }, "the pane closed")
        app.buttons["more"].firstMatch.tap()
        let item = app.buttons["menu.sidePane"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        XCTAssertEqual(item.label, "Show Side Pane", "More offers it again")
        item.tap()
        XCTAssertTrue(pane.waitForExistence(timeout: 3))
        let window = span(app)
        wait({ self.isWidth(pane, 0.3, of: window) }, "it opens beside the page again (\(pane.frame))")
    }

    func testAFlickTowardTheEdgeClosesWithOneTap() throws {
        let app = try launch()
        let (pane, divider) = openPane(app)
        app.expectHaptics(["tap"]) {
            drag(divider, by: 110, speed: 3000, hold: 0)
        }
        wait({ !pane.exists || !pane.isHittable || pane.frame.width < 1 }, "a flick past Narrow closes it")
    }

    func testPassingHalfTicksOnce() throws {
        let app = try launch()
        let (pane, divider) = openPane(app)
        let window = span(app)
        try XCTSkipUnless(window.width * 0.5 >= 375, "no Half on this width")
        app.expectHaptics(["selection"]) {
            drag(divider, by: -(window.width * 0.5 - pane.frame.width + 30), speed: 500, hold: 0.3)
        }
        wait({ self.isWidth(pane, 0.5, of: window) }, "rests at Half")
    }

    func testTheWidthStaysWhenTheSectionChangesAndTheMenuSetsIt() throws {
        let app = try launch()
        let (pane, divider) = openPane(app)
        let window = span(app)
        try XCTSkipUnless(window.width * 0.5 >= 375, "no Half on this width")
        divider.press(forDuration: 1.0)
        let half = app.buttons["menu.sidePaneWidth.half"]
        XCTAssertTrue(half.waitForExistence(timeout: 3), "the handle's menu lists the widths")
        XCTAssertTrue(app.buttons["menu.sidePaneWidth.full"].exists)
        half.tap()
        wait({ self.isWidth(pane, 0.5, of: window) }, "the menu's Half")
        let picker = app.segmentedControls["sidePane.picker"]
        picker.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.descendants(matching: .any)["sidePane.findField"].waitForExistence(timeout: 2))
        XCTAssertTrue(isWidth(pane, 0.5, of: window), "Find keeps the width")
        picker.buttons.element(boundBy: 2).tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(isWidth(pane, 0.5, of: window), "History keeps the width")
        // A double tap on the handle goes back to the opening width.
        divider.doubleTap()
        wait({ self.isWidth(pane, 0.3, of: window) }, "double tap: back to Narrow")
    }

    func testFindKeepsItsKeyboardWhileTheDividerMoves() throws {
        let app = try launch()
        let (pane, divider) = openPane(app)
        app.segmentedControls["sidePane.picker"].buttons.element(boundBy: 1).tap()
        let field = app.descendants(matching: .any)["sidePane.findField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText("paragraph")
        wait({ field.hasKeyboardFocus }, "Find has the keyboard")
        let window = span(app)
        try XCTSkipUnless(window.width * 0.5 >= 375, "no Half on this width")
        drag(divider, by: -(window.width * 0.5 - pane.frame.width))
        wait({ self.isWidth(pane, 0.5, of: window) }, "rests at Half with the keyboard up")
        XCTAssertTrue(field.hasKeyboardFocus, "the field keeps the keyboard")
        XCTAssertTrue(app.cells["sidePane.match.0"].waitForExistence(timeout: 3), "the matches are still listed")
    }

    /// VoiceOver finds the handle as an adjustable element that names the width (its increment and
    /// decrement are the model's steps, `SidePaneDividerTests.stepsGoThroughTheRestsThenTheWholeWidth`).
    func testTheHandleIsAdjustableAndSaysTheWidth() throws {
        let app = try launch()
        let (_, divider) = openPane(app)
        XCTAssertEqual(divider.label, "Side Pane Width")
        XCTAssertEqual(divider.value as? String, "Narrow, 30 percent")
    }

    func testTheWidthComesBackAfterARelaunch() throws {
        var app = try launch(["-PlainTestStore", "-PlainResetStore"])
        let (pane, divider) = openPane(app)
        let window = span(app)
        try XCTSkipUnless(window.width * 0.5 >= 375, "no Half on this width")
        drag(divider, by: -(window.width * 0.5 - pane.frame.width))
        wait({ self.isWidth(pane, 0.5, of: window) }, "rests at Half")
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
        app = try launch(["-PlainTestStore"])
        let back = app.otherElements["sidePane"]
        XCTAssertTrue(back.waitForExistence(timeout: 8), "the pane comes back open with the window")
        wait({ self.isWidth(back, 0.5, of: window) }, "at Half (\(back.frame))")
    }

    func testRotationKeepsTheWidthItCanAndBringsHalfBack() throws {
        let app = try launch()
        let (pane, divider) = openPane(app)
        let window = span(app)
        try XCTSkipUnless(window.width > window.height && window.width * 0.5 >= 375, "starts in a wide landscape")
        drag(divider, by: -(window.width * 0.5 - pane.frame.width))
        wait({ self.isWidth(pane, 0.5, of: window) }, "rests at Half")
        XCUIDevice.shared.orientation = .portrait
        let rotated = NSPredicate { _, _ in app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height }
        guard XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: nil)], timeout: 5) == .completed else {
            XCUIDevice.shared.orientation = .landscapeLeft
            throw XCTSkip("the window did not rotate here")
        }
        let tall = app.windows.firstMatch.frame
        // Half would leave a portrait page under 375 pt on the inner screen: Narrow shows.
        let expected = tall.width * 0.5 >= 375 ? 0.5 : 0.3
        wait({ self.isWidth(pane, expected, of: tall) }, "portrait shows the widest rest that fits (\(pane.frame))")
        XCUIDevice.shared.orientation = .landscapeLeft
        let wide = app.windows.firstMatch.frame
        wait({ app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height && self.isWidth(pane, 0.5, of: app.windows.firstMatch.frame) },
             "landscape again: Half comes back (\(pane.frame), \(wide))")
    }

    /// Walks the drag for screen recordings from outside (frame strips): rest, a slow drag to Half,
    /// on to the whole width, back, and closed. Runs on request only (`TEST_RUNNER_PLAIN_CAPTURE=1`).
    func testCaptureDividerDrag() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        // `PLAIN_DIVIDER_LIVE=1`: the page's web view resizes every frame instead (the measurement's baseline).
        let live = ProcessInfo.processInfo.environment["PLAIN_DIVIDER_LIVE"] == "1"
        let app = try launch(["-PlainMeasureDivider"] + (live ? ["-PlainDividerLive"] : []))
        let (pane, divider) = openPane(app)
        let window = span(app)
        sleep(2)  // capture: at rest, Narrow
        drag(divider, by: -(window.width * 0.5 - pane.frame.width), speed: 300, hold: 0.6)
        sleep(2)  // capture: Half
        drag(divider, by: -(window.width * 0.5 - 100), speed: 400, hold: 0.8)
        sleep(2)  // capture: the whole width
        drag(divider, by: window.width * 0.5, speed: 500, hold: 0.3)
        sleep(2)  // capture: back beside the page
        drag(divider, by: 120, speed: 2000, hold: 0)
        sleep(2)  // capture: a flick closes it
    }
}
