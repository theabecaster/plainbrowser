import XCTest

/// Page appearance (docs/decisions.md, "Page appearance"): Dark, Light or Off per site, learned as
/// the default from the first pick, separate from Plain's own Appearance; the one suggestion by
/// the address bar; the control in the pill and its menu; Site Settings; the Settings row. The
/// darkening itself is tested in WebEngineTests (DarkPagesTests).
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
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 15), "page \"\(heading)\" did not show")
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

    /// Settings > Appearance > `choice` (Plain's own colors), then Done.
    private func chooseAppearance(_ app: XCUIApplication, _ choice: String) {
        openSettings(app)
        let row = app.buttons["settings.appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: row)], timeout: 5), .completed)
        row.tap()
        XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 2))
        app.buttons[choice].tap()
        app.buttons["Done"].tap()
    }

    private func pageAppearanceRow(_ app: XCUIApplication) -> XCUIElement { app.buttons["settings.pageAppearance"] }

    private var suggestionWait: TimeInterval { 12 }

    private func suggestion(_ app: XCUIApplication) -> XCUIElement { app.buttons["darkPagesSuggestion.turnOn"] }
    private func control(_ app: XCUIApplication) -> XCUIElement { app.buttons["pill.pageAppearance"] }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// Picks `appearance` ("dark", "light", "off") from the control's menu in the pill.
    private func pick(_ app: XCUIApplication, _ appearance: String) {
        XCTAssertTrue(control(app).waitForExistence(timeout: 8))
        control(app).tap()
        let item = app.buttons["pageAppearance.\(appearance)"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "\(appearance) is in the menu")
        item.tap()
    }

    /// Picks `appearance` from Site Settings > Page Appearance (the way in while the pill shows no
    /// control: the page as the site made it).
    private func pickFromSiteSettings(_ app: XCUIApplication, _ appearance: String) {
        app.buttons["more"].tap()
        let site = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Site Settings'")).firstMatch
        if site.waitForExistence(timeout: 2) { site.tap() }
        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page Appearance'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "Site Settings offers Page Appearance")
        menu.tap()
        let item = app.buttons["pageAppearance.\(appearance)"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }

    /// A later session: the app leaves the screen and comes back.
    private func nextSession(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 5))
    }

    func testTurnOnMakesDarkTheDefaultAndASiteKeepsItsOwnChoice() throws {
        let app = try launch()
        chooseAppearance(app, "Dark")
        go(app, to: server.address("/light-site"), heading: "Light Only")
        XCTAssertFalse(control(app).exists, "nothing chosen: nothing changed, nothing to show")
        XCTAssertTrue(suggestion(app).waitForExistence(timeout: suggestionWait), "a light page in dark colors suggests it")
        suggestion(app).tap()
        XCTAssertTrue(waitForValue(control(app), "Dark, all sites"), "the control shows the default it applies")

        // A site that looks wrong: Off for it alone, the default stays.
        pick(app, "off")
        XCTAssertTrue(waitForValue(control(app), "Off, this site"))
        go(app, to: server.address("/light-site-2"), heading: "Light Only")
        XCTAssertTrue(waitForValue(control(app), "Off, this site"), "remembered for the site")
        go(app, to: otherSite("/light-site"), heading: "Light Only")
        XCTAssertTrue(waitForValue(control(app), "Dark, all sites"), "the default applies to a new site")
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: 4), "answered: never again")
        openSettings(app)
        XCTAssertTrue(pageAppearanceRow(app).waitForExistence(timeout: 3))
        XCTAssertTrue(pageAppearanceRow(app).label.contains("Dark"), "Turn On is the default in Settings: \(pageAppearanceRow(app).label)")
        app.buttons["Done"].tap()
    }

    func testTheFirstPickBecomesTheDefaultAndAnExceptionSurvivesItsChange() throws {
        let app = try launch()
        go(app, to: server.address("/light-site"), heading: "Light Only")
        XCTAssertFalse(control(app).exists)
        // Plain is light; the page can still be dark: the first pick is the default for every site.
        pickFromSiteSettings(app, "dark")
        XCTAssertTrue(waitForValue(control(app), "Dark, all sites"))
        let toast = app.buttons["toastButton"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "the toast says it is now the default, with This Site Only")
        go(app, to: otherSite("/light-site"), heading: "Light Only")
        XCTAssertTrue(waitForValue(control(app), "Dark, all sites"), "the learned default reaches another site")

        // This site its own Light; then the default changes in Settings: the exception stays.
        pick(app, "light")
        XCTAssertTrue(waitForValue(control(app), "Light, this site"))
        openSettings(app)
        pageAppearanceRow(app).tap()
        XCTAssertTrue(app.buttons["Off"].waitForExistence(timeout: 2))
        app.buttons["Off"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(waitForValue(control(app), "Light, this site"), "a site's own choice survives a change of the default")
        go(app, to: server.address("/light-site-2"), heading: "Light Only")
        XCTAssertFalse(control(app).waitForExistence(timeout: 3), "the default is Off now: the page as made")
    }

    func testNoThanksIsFinal() throws {
        let app = try launch()
        chooseAppearance(app, "Dark")
        go(app, to: server.address("/light-site"), heading: "Light Only")
        let noThanks = app.buttons["darkPagesSuggestion.noThanks"]
        XCTAssertTrue(noThanks.waitForExistence(timeout: suggestionWait))
        noThanks.tap()
        XCTAssertFalse(control(app).waitForExistence(timeout: 2), "declined: the page stays as made")
        nextSession(app)
        go(app, to: otherSite("/light-site"), heading: "Light Only")
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: suggestionWait), "declined once: never again")
    }

    func testIgnoredShowsAgainOnAnotherSiteNextTime() throws {
        let app = try launch()
        chooseAppearance(app, "Dark")
        go(app, to: server.address("/light-site"), heading: "Light Only")
        XCTAssertTrue(suggestion(app).waitForExistence(timeout: suggestionWait))
        XCTAssertTrue(suggestion(app).waitForNonExistence(timeout: 14), "it leaves after a few seconds")
        go(app, to: otherSite("/light-site"), heading: "Light Only")
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: 6), "not again in the same session")
        nextSession(app)
        go(app, to: otherSite("/light-site-2"), heading: "Light Only")
        XCTAssertTrue(suggestion(app).waitForExistence(timeout: suggestionWait), "ignored: it comes back next time")
    }

    func testLightColorsSuggestNothing() throws {
        let app = try launch()
        go(app, to: server.address("/light-site"), heading: "Light Only")
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: 6), "a light page in light colors: nothing to suggest")
        XCTAssertFalse(control(app).exists)
    }

    func testOwnDarkDesignIsUsedAndLightShowsItsLightDesign() throws {
        let app = try launch()
        chooseAppearance(app, "Dark")
        go(app, to: server.address("/dark-site"), heading: "Own Dark Design")
        XCTAssertFalse(suggestion(app).waitForExistence(timeout: 6), "its own dark design: nothing to suggest")
        XCTAssertFalse(control(app).exists)
        pickFromSiteSettings(app, "light")
        XCTAssertTrue(waitForValue(control(app), "Light, all sites"), "its light design, in a dark app")
    }

    /// Screenshots for review: the suggestion, the menu, the three states in a dark and a light
    /// app, Site Settings, Settings, and frames through the crossfade. Runs on request
    /// (`TEST_RUNNER_PLAIN_CAPTURE=1`, or `scripts/matrix.sh -only-testing:` this test).
    func testCaptureDarkPages() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let app = try launch()
        chooseAppearance(app, "Dark")
        go(app, to: server.address("/light-site"), heading: "Light Only")
        XCTAssertTrue(suggestion(app).waitForExistence(timeout: suggestionWait))
        Thread.sleep(forTimeInterval: 0.6)
        shot("dp-1-suggestion")
        suggestion(app).tap()
        for frame in 0..<4 { shot("dp-2-crossfade-\(frame)") }
        XCTAssertTrue(waitForValue(control(app), "Dark, all sites"))
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-3-app-dark-page-dark")
        control(app).tap()
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-4-menu")
        app.buttons["pageAppearance.light"].tap()
        XCTAssertTrue(waitForValue(control(app), "Light, this site"))
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-5-app-dark-page-light")
        pick(app, "off")
        XCTAssertTrue(waitForValue(control(app), "Off, this site"))
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-6-app-dark-page-off")
        app.buttons["more"].tap()
        let site = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Site Settings'")).firstMatch
        if site.waitForExistence(timeout: 2) { site.tap() }
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-7-site-settings")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        Thread.sleep(forTimeInterval: 0.6)
        openSettings(app)
        XCTAssertTrue(pageAppearanceRow(app).waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-8-settings")
        app.buttons["Done"].tap()
        // Plain light: the same three states on the page.
        chooseAppearance(app, "Light")
        pick(app, "dark")
        XCTAssertTrue(waitForValue(control(app), "Dark, all sites"))
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-9-app-light-page-dark")
        pick(app, "light")
        XCTAssertTrue(waitForValue(control(app), "Light, this site"))
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-10-app-light-page-light")
        pick(app, "off")
        XCTAssertTrue(waitForValue(control(app), "Off, this site"))
        Thread.sleep(forTimeInterval: 0.8)
        shot("dp-11-app-light-page-off")
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
}
