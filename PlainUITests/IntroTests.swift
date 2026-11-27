import XCTest

/// The first-run intro: skipping it and going through it both end in the focused search field.
/// `-PlainShowIntro` shows it even though the in-memory store would otherwise turn it off.
@MainActor
final class IntroTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainShowIntro"] + extra
        app.launch()
        return app
    }

    private func assertSearchFieldFocused(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field after the intro", file: file, line: line)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard is not up after the intro", file: file, line: line)
        XCTAssertTrue(field.hasKeyboardFocus, "search field is not first responder after the intro", file: file, line: line)
        // The intro is gone, not just hidden behind the field.
        XCTAssertFalse(app.buttons["introSkip"].exists, file: file, line: line)
    }

    private func tapNext(_ app: XCUIApplication, step: String) {
        XCTAssertTrue(app.otherElements["intro.\(step)"].waitForExistence(timeout: 5) || app.buttons["introNext"].waitForExistence(timeout: 1),
                      "step \(step) did not show")
        let next = app.buttons["introNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
    }

    func testSkipFromTheFirstStep() {
        let app = launch()
        let skip = app.buttons["introSkip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "the intro did not show")
        skip.tap()
        assertSearchFieldFocused(app)
    }

    /// "Made for iPhone Duo" shows only where the window can be a foldable's: the outer screen's
    /// vertical bar edge or a regular-by-regular window (`IntroRules`). The test tells the two
    /// simulators apart by size only: a portrait iPhone is under 450 pt wide and over 700 pt
    /// tall; the Duo's outer screen (466 x 678) and inner screen (951 x 669) are not.
    func testUnfoldRowOnlyOnAFoldable() {
        let app = launch()
        tapNext(app, step: "promise")
        XCTAssertTrue(app.staticTexts["Private Tabs"].waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        let plainIPhone = window.width < 450 && window.height > 700
        XCTAssertEqual(app.staticTexts["Made for iPhone Duo"].exists, !plainIPhone)
    }

    func testTapSkipsTheSplash() {
        let app = launch()
        // A tap during the splash lands the mark at once; the promise step follows.
        app.tap()
        XCTAssertTrue(app.buttons["introNext"].waitForExistence(timeout: 0.9), "the tap did not cut the splash short")
    }

    func testFullPath() {
        // The test store, so the "seen" flag (in the isolated defaults) survives the relaunch below.
        let app = launch(["-PlainTestStore", "-PlainResetStore"])
        tapNext(app, step: "promise")
        tapNext(app, step: "inside")

        // Pick an icon, then put the default back. An isolated run keeps the choice in memory and
        // never changes the Home Screen icon, so no system alert comes up.
        let night = app.buttons["introIcon.Night"]
        XCTAssertTrue(night.waitForExistence(timeout: 5))
        night.tap()
        XCTAssertTrue(night.isSelected, "the picked icon is not selected")
        app.buttons["introIcon.Dawn"].tap()
        XCTAssertTrue(app.buttons["introIcon.Dawn"].isSelected, "the default icon is not selected again")
        tapNext(app, step: "icon")

        // The demo plays by itself (clean), then can be flipped back and forth.
        let toggle = app.switches["introBlockingToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let on = NSPredicate(format: "value == '1'")
        expectation(for: on, evaluatedWith: toggle)
        waitForExpectations(timeout: 4)
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")

        // Without the default-browser step, the demo is the last step.
        let go = app.buttons["introLetsGo"]
        XCTAssertTrue(go.waitForExistence(timeout: 2))
        go.tap()
        assertSearchFieldFocused(app)

        // Seen: the next launch, where the saved flag decides as for a real user, goes straight to
        // the search field.
        app.terminate()
        let again = XCUIApplication.isolated()
        again.launchArguments += ["-PlainTestStore", "-PlainRespectIntroSeen"]
        again.launch()
        assertSearchFieldFocused(again)
    }

    func testDefaultBrowserStepWhenPromptsAreOn() {
        let app = launch(["-PlainForceDefaultBrowserPrompts"])
        for step in ["promise", "inside", "icon", "blocking"] { tapNext(app, step: step) }
        let notNow = app.buttons["introNotNow"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["introSetDefault"].exists)
        notNow.tap()
        assertSearchFieldFocused(app)
    }

    func testDefaultBrowserCardPreview() {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainPreviewEmptyTabCard"]
        app.launch()
        XCTAssertTrue(app.buttons["defaultBrowserCardButton"].waitForExistence(timeout: 5))
        app.buttons["defaultBrowserCardClose"].tap()
        XCTAssertFalse(app.buttons["defaultBrowserCardButton"].waitForExistence(timeout: 1))
    }
}

/// Walks the intro slowly for screen recordings and design review, attaching a screenshot of each
/// step. Runs only when `PLAIN_CAPTURE=1` reaches the runner (see CaptureTests).
@MainActor
final class IntroCaptureTests: XCTestCase {
    private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testCaptureIntro() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainShowIntro", "-PlainForceDefaultBrowserPrompts"]
        app.launch()
        pause(0.5)
        shot("0-splash", app)
        let next = app.buttons["introNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        pause(1.6)
        shot("1-promise", app)
        next.tap()
        pause(2.2)
        shot("2-inside", app)
        next.tap()
        pause(2.0)
        shot("3-icon", app)
        app.buttons["introIcon.Coral"].tap()
        pause(1.0)
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
        pause(1.0)
        shot("3b-icon-picked", app)
        app.buttons["introIcon.Dawn"].tap()
        pause(1.0)
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
        next.tap()
        pause(0.9)
        shot("4-blocking-cluttered", app)
        pause(2.0)
        shot("5-blocking-clean", app)
        app.switches["introBlockingToggle"].switches.firstMatch.tap()
        pause(1.5)
        shot("6-blocking-off", app)
        app.switches["introBlockingToggle"].switches.firstMatch.tap()
        pause(1.5)
        next.tap()
        pause(2.0)
        shot("7-default", app)
        app.buttons["introNotNow"].tap()
        pause(0.35)
        shot("8-dissolve", app)
        pause(1.5)
        shot("9-search", app)
    }

    func testCaptureEmptyTabCard() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainPreviewEmptyTabCard"]
        app.launch()
        XCTAssertTrue(app.buttons["defaultBrowserCardButton"].waitForExistence(timeout: 5))
        pause(1.0)
        shot("empty-tab-card", app)
    }
}
