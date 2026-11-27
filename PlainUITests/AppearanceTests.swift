import XCTest

/// Settings > Appearance (System, Light, Dark; saved) and dark pages' per-site switch in the
/// page menu. The darkening itself is tested in WebEngineTests (DarkPagesTests).
@MainActor
final class AppearanceTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ arguments: [String] = ["-PlainInMemoryStore"]) throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
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
    }

    private func openSettings(_ app: XCUIApplication) {
        let field = app.textFields["searchField"]
        if field.exists && field.hasKeyboardFocus {
            // The search field covers the bar: close it with a tap above it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
        }
        XCTAssertTrue(app.buttons["more"].waitForExistence(timeout: 3))
        app.buttons["more"].tap()
        let settings = app.buttons["Settings…"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
    }

    private func appearanceRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Appearance'")).firstMatch
    }

    /// Settings > Appearance > `choice`, then Done.
    private func chooseAppearance(_ app: XCUIApplication, _ choice: String) {
        openSettings(app)
        let row = appearanceRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Appearance is in Settings")
        // The row waits for the saved settings.
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: row)], timeout: 3), .completed)
        row.tap()
        let option = app.buttons[choice]
        XCTAssertTrue(option.waitForExistence(timeout: 2), "\"\(choice)\" is an Appearance choice")
        option.tap()
        app.buttons["Done"].tap()
    }

    /// The page menu's items, by label, while it is open.
    private func menuHas(_ app: XCUIApplication, _ label: String) -> Bool {
        app.buttons[label].waitForExistence(timeout: 1)
    }

    private func openPageMenu(_ app: XCUIApplication) {
        let more = app.buttons["more"]
        XCTAssertTrue(more.waitForExistence(timeout: 2))
        more.tap()
        XCTAssertTrue(app.buttons["Settings…"].waitForExistence(timeout: 3))
    }

    private func closeMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
    }

    func testAppearanceIsSystemByDefaultAndSurvivesRelaunch() throws {
        var app = try launch(["-PlainIntroSeen", "YES", "-PlainTestStore", "-PlainResetStore"])
        openSettings(app)
        XCTAssertTrue(appearanceRow(app).waitForExistence(timeout: 3))
        XCTAssertTrue(appearanceRow(app).label.contains("System"), "System is the default: \(appearanceRow(app).label)")
        app.buttons["Done"].tap()

        chooseAppearance(app, "Dark")
        app.terminate()
        app = try launch(["-PlainIntroSeen", "YES", "-PlainTestStore"])
        openSettings(app)
        let row = appearanceRow(app)
        let dark = NSPredicate(format: "label CONTAINS 'Dark'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: dark, object: row)], timeout: 3), .completed,
                       "Dark came back after relaunch: \(row.label)")
        app.buttons["Done"].tap()
        chooseAppearance(app, "System")
    }

    func testDarkPagesSwitchShowsOnlyWhileDarkAndIsRememberedForTheSite() throws {
        let app = try launch()
        go(app, to: "/light-site", heading: "Light Only")
        openPageMenu(app)
        XCTAssertFalse(menuHas(app, "Turn Off Dark Pages for This Site"), "a light app darkens nothing")
        closeMenu(app)

        chooseAppearance(app, "Dark")
        openPageMenu(app)
        XCTAssertTrue(menuHas(app, "Turn Off Dark Pages for This Site"), "the light-only page is darkened")
        app.buttons["Turn Off Dark Pages for This Site"].tap()

        // Remembered for the site: another page on it opens with dark pages off.
        go(app, to: "/light-site-2", heading: "Light Only")
        openPageMenu(app)
        XCTAssertTrue(menuHas(app, "Turn On Dark Pages for This Site"))
        app.buttons["Turn On Dark Pages for This Site"].tap()
        openPageMenu(app)
        XCTAssertTrue(menuHas(app, "Turn Off Dark Pages for This Site"), "back on, at once")
        closeMenu(app)

        // A site with its own dark design is left alone: nothing to turn off.
        go(app, to: "/dark-site", heading: "Own Dark Design")
        openPageMenu(app)
        XCTAssertFalse(menuHas(app, "Turn Off Dark Pages for This Site"))
        XCTAssertFalse(menuHas(app, "Turn On Dark Pages for This Site"))
        closeMenu(app)
        chooseAppearance(app, "System")
    }

    /// Scroll proxy for dark pages (docs/research/dark-mode.md): frames the page drew while a
    /// fast scroll ran, and how many took over 25 ms, darkened and with dark pages off. The
    /// simulator has no hitch metric; the device perf gate's `hitchMsPerS` is the real number.
    /// Runs on request: `TEST_RUNNER_PLAIN_DARK_PERF=1`.
    func testScrollFramesWithAndWithoutDarkPages() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_DARK_PERF"] == "1", "perf proxy runs on request only")
        let app = try launch()
        chooseAppearance(app, "Dark")
        func run(_ label: String) {
            go(app, to: "/light-site?\(label)", heading: "Light Only")
            Thread.sleep(forTimeInterval: 1)
            let web = app.webViews.firstMatch
            for _ in 0..<4 {
                web.swipeUp(velocity: .fast)
                web.swipeUp(velocity: .fast)
                web.swipeDown(velocity: .fast)
                web.swipeDown(velocity: .fast)
            }
            for _ in 0..<4 { web.swipeUp(velocity: .fast) }
            Thread.sleep(forTimeInterval: 1.5)
            let stats = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Frames:'")).firstMatch
            XCTAssertTrue(stats.waitForExistence(timeout: 5))
            print("[plain-measure] scroll \(label): \(stats.label)")
            let attachment = XCTAttachment(string: "\(label): \(stats.label)")
            attachment.lifetime = .keepAlways
            add(attachment)
            // Back to the top, where the bar is expanded again.
            for _ in 0..<6 { web.swipeDown(velocity: .fast) }
            Thread.sleep(forTimeInterval: 1)
        }
        run("darkened")
        openPageMenu(app)
        app.buttons["Turn Off Dark Pages for This Site"].tap()
        run("off")
        openPageMenu(app)
        app.buttons["Turn On Dark Pages for This Site"].tap()
        run("darkened-again")
        chooseAppearance(app, "System")
    }

    /// The device number for dark pages: `XCTHitchMetric` while scrolling the light-only page,
    /// darkened and with dark pages off (one `measure` per test). The simulator reports no hitch
    /// data. Runs on request (`TEST_RUNNER_PLAIN_DARK_PERF=1`), on the device by the lead.
    func testScrollHitchesDarkened() throws { try measureScrollHitches(darkPagesOff: false) }
    func testScrollHitchesDarkPagesOff() throws { try measureScrollHitches(darkPagesOff: true) }

    private func measureScrollHitches(darkPagesOff: Bool) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_DARK_PERF"] == "1", "perf runs on request only")
        let app = try launch()
        chooseAppearance(app, "Dark")
        go(app, to: "/light-site", heading: "Light Only")
        if darkPagesOff {
            openPageMenu(app)
            app.buttons["Turn Off Dark Pages for This Site"].tap()
        }
        Thread.sleep(forTimeInterval: 1)
        let web = app.webViews.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTHitchMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            web.swipeUp(velocity: .fast)
            stopMeasuring()
            web.swipeDown(velocity: .fast)
        }
        for _ in 0..<4 { web.swipeDown(velocity: .fast) }
        chooseAppearance(app, "System")
    }

    /// Screenshots for review: Settings with Appearance, the app light and dark, a site with its
    /// own dark design, a light-only site darkened, and the same with dark pages off. Runs on
    /// request: `TEST_RUNNER_PLAIN_CAPTURE=1`.
    func testCaptureAppearance() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let app = try launch(["-PlainInMemoryStore", "-PlainSeedFavorites"])
        go(app, to: "/light-site", heading: "Light Only")
        Thread.sleep(forTimeInterval: 1)
        shot("a1-light-app-light-site")
        openSettings(app)
        Thread.sleep(forTimeInterval: 1)
        shot("a2-settings-light")
        appearanceRow(app).tap()
        Thread.sleep(forTimeInterval: 0.8)
        shot("a3-appearance-menu")
        app.buttons["Dark"].tap()
        Thread.sleep(forTimeInterval: 1)
        shot("a4-settings-dark")
        app.buttons["Done"].tap()
        Thread.sleep(forTimeInterval: 1.2)
        shot("a5-light-site-darkened")
        openPageMenu(app)
        Thread.sleep(forTimeInterval: 0.8)
        shot("a6-page-menu-dark-pages")
        app.buttons["Turn Off Dark Pages for This Site"].tap()
        Thread.sleep(forTimeInterval: 1)
        shot("a7-light-site-dark-pages-off")
        openPageMenu(app)
        app.buttons["Turn On Dark Pages for This Site"].tap()
        go(app, to: "/dark-site", heading: "Own Dark Design")
        Thread.sleep(forTimeInterval: 1)
        shot("a8-own-dark-design")
        app.buttons["addressPill"].tap()
        Thread.sleep(forTimeInterval: 1)
        shot("a9-search-dark")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        chooseAppearance(app, "System")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
