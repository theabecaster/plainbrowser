import XCTest

/// Dark Pages, off by default (docs/research/dark-pages-optin.md): the one suggestion by the
/// address bar, the indicator in the pill and its per-site toggle, Site Settings' item and the
/// Settings switch. The darkening itself is tested in WebEngineTests (DarkPagesTests).
///
/// `localhost` and `127.0.0.1` are two sites to Plain (the test server answers both).
@MainActor
final class DarkPagesUITests: XCTestCase {
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
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        return app
    }

    /// The other site: the same server by its address instead of `localhost`.
    private func otherSite(_ path: String) -> String {
        server.address(path).replacingOccurrences(of: "localhost", with: "127.0.0.1")
    }

    private func go(_ app: XCUIApplication, to address: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(address + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show")
    }

    private func openSettings(_ app: XCUIApplication) {
        let field = app.textFields["searchField"]
        if field.exists && field.hasKeyboardFocus {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
        }
        XCTAssertTrue(app.buttons["more"].waitForExistence(timeout: 3))
        app.buttons["more"].tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
    }

    /// Settings > Appearance > Dark, then Done. Dark Pages stays as it is.
    private func chooseDark(_ app: XCUIApplication) {
        openSettings(app)
        let row = app.buttons["settings.appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: row)], timeout: 5), .completed)
        row.tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 2))
        app.buttons["Dark"].tap()
        let toggle = app.switches["settings.darkPages"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.value as? String, "0", "Dark Pages starts off")
        app.buttons["Done"].tap()
    }

    private var suggestionWait: TimeInterval { 12 }

    private func suggestion(_ app: XCUIApplication) -> XCUIElement { app.buttons["darkPagesSuggestion.turnOn"] }
    private func indicator(_ app: XCUIApplication) -> XCUIElement { app.buttons["pill.darkPages"] }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// A later session: the app leaves the screen and comes back.
    private func nextSession(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 5))
    }

    func testTurnOnDarkensAndTheIndicatorTogglesPerSite() throws {
        let app = try launch()
        chooseDark(app)
        go(app, to: server.address("/light-site"), heading: "Light Only")
        XCTAssertFalse(indicator(app).exists, "off by default: nothing applied, nothing to show")
        XCTAssertTrue(suggestion(app).waitForExistence(timeout: suggestionWait), "a light page in dark colors suggests it")
        XCTAssertTrue(app.staticTexts["Darken websites that have no dark mode of their own?"].exists
            || app.otherElements["darkPagesSuggestion"].exists)
        suggestion(app).tap()
        XCTAssertTrue(indicator(app).waitForExistence(timeout: 5), "the indicator appears once it is applied")
        XCTAssertTrue(waitForValue(indicator(app), "On"))

        // Off for this site, at once; the indicator stays so it can come back.
        indicator(app).tap()
        XCTAssertTrue(waitForValue(indicator(app), "Off"))
        go(app, to: server.address("/light-site-2"), heading: "Light Only")
        XCTAssertTrue(waitForValue(indicator(app), "Off", timeout: 8), "remembered for the site")
        indicator(app).tap()
        XCTAssertTrue(waitForValue(indicator(app), "On"))

        // Another site follows the switch, which Turn On turned on.
        go(app, to: otherSite("/light-site"), heading: "Light Only")
        XCTAssertTrue(waitForValue(indicator(app), "On", timeout: 8))
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: 4), "answered: never again")
        openSettings(app)
        XCTAssertEqual(app.switches["settings.darkPages"].value as? String, "1", "Turn On is the Settings switch")
        app.buttons["Done"].tap()
    }

    func testNoThanksIsFinal() throws {
        let app = try launch()
        chooseDark(app)
        go(app, to: server.address("/light-site"), heading: "Light Only")
        let noThanks = app.buttons["darkPagesSuggestion.noThanks"]
        XCTAssertTrue(noThanks.waitForExistence(timeout: suggestionWait))
        noThanks.tap()
        XCTAssertFalse(indicator(app).waitForExistence(timeout: 2), "declined: the page stays as made")
        nextSession(app)
        go(app, to: otherSite("/light-site"), heading: "Light Only")
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: suggestionWait), "declined once: never again")
        // Still there to turn on, per site.
        app.buttons["more"].tap()
        let site = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Site Settings'")).firstMatch
        if site.waitForExistence(timeout: 2) { site.tap() }
        let item = app.buttons["menu.darkPages"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Site Settings offers Dark Pages for the site")
        item.tap()
        XCTAssertTrue(waitForValue(indicator(app), "On", timeout: 8), "on for this site while the switch stays off")
    }

    func testIgnoredShowsAgainOnAnotherSiteNextTime() throws {
        let app = try launch()
        chooseDark(app)
        go(app, to: server.address("/light-site"), heading: "Light Only")
        XCTAssertTrue(suggestion(app).waitForExistence(timeout: suggestionWait))
        // Left alone, it goes by itself.
        XCTAssertTrue(suggestion(app).waitForNonExistence(timeout: 14), "it leaves after a few seconds")
        // Same session, another site: not yet.
        go(app, to: otherSite("/light-site"), heading: "Light Only")
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: 6), "not again in the same session")
        // Next time, on another site than the one it was ignored on: again.
        nextSession(app)
        go(app, to: otherSite("/light-site-2"), heading: "Light Only")
        XCTAssertTrue(suggestion(app).waitForExistence(timeout: suggestionWait), "ignored: it comes back next time")
    }

    func testLightColorsShowNothing() throws {
        let app = try launch()
        go(app, to: server.address("/light-site"), heading: "Light Only")
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: 6), "light colors: nothing to darken")
        XCTAssertFalse(indicator(app).exists)
    }

    /// Screenshots for review: the suggestion, the indicator on and off, Site Settings' item, the
    /// Settings switch, and a strip of frames through the crossfade. Runs on request
    /// (`TEST_RUNNER_PLAIN_CAPTURE=1`, or `scripts/matrix.sh -only-testing:` this test).
    func testCaptureDarkPages() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let app = try launch()
        chooseDark(app)
        go(app, to: server.address("/light-site"), heading: "Light Only")
        XCTAssertTrue(suggestion(app).waitForExistence(timeout: suggestionWait))
        Thread.sleep(forTimeInterval: 0.6)
        shot("dp-1-suggestion")
        suggestion(app).tap()
        // The crossfade, frame by frame (each screenshot takes a moment, so a few frames of 0.25 s).
        for frame in 0..<6 { shot("dp-2-crossfade-on-\(frame)") }
        XCTAssertTrue(waitForValue(indicator(app), "On"))
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-3-indicator-on")
        indicator(app).tap()
        for frame in 0..<6 { shot("dp-4-crossfade-off-\(frame)") }
        XCTAssertTrue(waitForValue(indicator(app), "Off"))
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-5-indicator-off")
        app.buttons["more"].tap()
        let site = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Site Settings'")).firstMatch
        if site.waitForExistence(timeout: 2) { site.tap() }
        XCTAssertTrue(app.buttons["menu.darkPages"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        shot("dp-6-site-settings")
        app.buttons["menu.darkPages"].tap()
        XCTAssertTrue(waitForValue(indicator(app), "On", timeout: 5))
        openSettings(app)
        XCTAssertTrue(app.switches["settings.darkPages"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-7-settings")
        app.buttons["Done"].tap()
    }

    /// Every screen (the Duo has two, and the one that is off is black); the matrix keeps the one
    /// that shows something.
    private func shot(_ name: String) {
        for screen in XCUIScreen.screens {
            let image = screen.screenshot()
            let size = image.image.size
            let suffix = XCUIScreen.screens.count > 1 ? "-\(Int(size.width))x\(Int(size.height))" : ""
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = "\(name)\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testOwnDarkDesignShowsNoIndicatorOrSuggestion() throws {
        let app = try launch()
        chooseDark(app)
        go(app, to: server.address("/dark-site"), heading: "Own Dark Design")
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: 6))
        XCTAssertFalse(indicator(app).exists)
        // The switch on in Settings: still nothing on a site with its own dark design.
        openSettings(app)
        let toggle = app.switches["settings.darkPages"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue(toggle, "1"))
        app.buttons["Done"].tap()
        XCTAssertFalse(indicator(app).waitForExistence(timeout: 3), "its own dark design is left alone")
        go(app, to: server.address("/light-site"), heading: "Light Only")
        XCTAssertTrue(waitForValue(indicator(app), "On", timeout: 8))
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: 4), "the switch counts as the answer")
    }
}
