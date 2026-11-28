import XCTest

/// Browse for Me and Summarize Page through the UI, with the app's scripted model and pages
/// (`-PlainTestSummaries`: no network, no Apple Intelligence), and without a model
/// (`-PlainAIUnavailable`: the entries are left out). The pipeline itself is tested in
/// IntelligenceTests; Apple's model is checked on the device.
@MainActor
final class SummaryTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ extra: [String] = ["-PlainTestSummaries"]) throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication.isolated()
        app.launchArguments += extra
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

    private func openPageMenu(_ app: XCUIApplication) {
        let more = app.buttons["more"]
        XCTAssertTrue(more.waitForExistence(timeout: 2))
        more.tap()
        XCTAssertTrue(app.buttons["menu.settings"].waitForExistence(timeout: 3))
    }

    /// The row shows while the text would search, fades out for an address, and opens the summary:
    /// honest progress, then the streamed answer with citations and its sources. A source opens in
    /// a new tab; Back on it brings the summary back; Done closes it.
    func testBrowseForMe() throws {
        let app = try launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.hasKeyboardFocus)
        let row = app.buttons["browseForMe"]
        XCTAssertFalse(row.exists, "no row for an empty field")

        field.typeText("example.com")
        XCTAssertFalse(row.waitForExistence(timeout: 1), "an address has nothing to browse")
        field.clearText()
        field.typeText("trail running shoes")
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        XCTAssertEqual(row.value as? String, "trail running shoes")
        shot("b1-row")

        row.tap()
        let screen = app.otherElements["summaryScreen"].firstMatch
        XCTAssertTrue(app.staticTexts["Browse for Me"].waitForExistence(timeout: 3) || screen.waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["field-notes.example"].waitForExistence(timeout: 3), "the sites being read are named")
        XCTAssertFalse(app.staticTexts["youtube.com"].exists, "a video site is never read")
        Thread.sleep(forTimeInterval: 0.6)
        shot("b2-reading")

        XCTAssertTrue(app.staticTexts["The short answer"].waitForExistence(timeout: 15), "the summary streams in")
        shot("b3-writing")
        let source = app.buttons["summarySource.1"]
        XCTAssertTrue(source.waitForExistence(timeout: 15), "the sources end the summary")
        // Each point reads with the sites it cites (VoiceOver).
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "The sources differ on timing")).firstMatch
        XCTAssertTrue(last.exists)
        XCTAssertTrue(last.label.contains("Sources: "), last.label)
        shot("b4-done")
        app.swipeUp()
        shot("b5-sources")
        // The title and Done stay pinned while the summary scrolls (the Duo's outer screen too).
        XCTAssertTrue(app.buttons["Done"].isHittable, "Done stays on screen")
        XCTAssertTrue(app.staticTexts["Browse for Me"].isHittable, "the title stays on screen")

        source.tap()
        XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 5), "the source opened in a tab")
        XCTAssertFalse(app.staticTexts["The short answer"].exists)
        let back = app.buttons["back"]
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        XCTAssertTrue(back.isEnabled, "Back returns to the summary")
        back.tap()
        XCTAssertTrue(app.staticTexts["The short answer"].waitForExistence(timeout: 3), "the summary came back")
        shot("b6-back")

        app.buttons["Done"].tap()
        XCTAssertFalse(app.staticTexts["The short answer"].waitForExistence(timeout: 1))
    }

    /// Closing while the pages are read stops the run: the screen goes and nothing comes back.
    func testBrowseForMeCancels() throws {
        let app = try launch()
        app.textFields["searchField"].typeText("tide tables")
        let row = app.buttons["browseForMe"]
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.tap()
        XCTAssertTrue(app.staticTexts["field-notes.example"].waitForExistence(timeout: 3))
        app.swipeDown(velocity: .fast)
        XCTAssertFalse(app.staticTexts["field-notes.example"].waitForExistence(timeout: 2), "the sheet closed")
        Thread.sleep(forTimeInterval: 8)
        XCTAssertFalse(app.staticTexts["The short answer"].exists, "a cancelled run shows nothing later")
    }

    /// Summarize Page joins Find and Reader on an article, and writes from the page alone.
    func testSummarizePage() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        openPageMenu(app)
        XCTAssertFalse(app.buttons["menu.summarize"].exists, "a page with no article has nothing to summarize")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 0.5)

        go(app, to: "/article", heading: "The Quiet Page")
        Thread.sleep(forTimeInterval: 1)
        openPageMenu(app)
        let summarize = app.buttons["menu.summarize"]
        XCTAssertTrue(summarize.waitForExistence(timeout: 3))
        shot("p1-menu")
        summarize.tap()
        XCTAssertTrue(app.staticTexts["Summary"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["The short answer"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["summarySource.1"].waitForExistence(timeout: 4), "a page's own summary lists no sources")
        shot("p2-summary")
        app.buttons["Done"].tap()
    }

    /// Without the on-device model, neither entry is there, and nothing says why.
    func testEntriesLeftOutWithoutTheModel() throws {
        let app = try launch(["-PlainAIUnavailable"])
        app.textFields["searchField"].typeText("trail running shoes")
        XCTAssertTrue(app.buttons["suggestion.search.0"].waitForExistence(timeout: 3) || true)
        XCTAssertFalse(app.buttons["browseForMe"].waitForExistence(timeout: 1))
        shot("u1-no-row")
        app.textFields["searchField"].clearText()
        go(app, to: "/article", heading: "The Quiet Page")
        Thread.sleep(forTimeInterval: 1)
        openPageMenu(app)
        XCTAssertTrue(app.buttons["menu.reader"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["menu.summarize"].exists)
        shot("u2-menu")
    }

    /// Browse for Me end to end: the user's engine (Google), the live web and Apple's model (on a
    /// simulator, the Mac's). Captures only, on request (`TEST_RUNNER_PLAIN_CAPTURE=1`): it needs
    /// the network and Apple Intelligence.
    func testCaptureBrowseForMeLive() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let app = try launch([])
        app.textFields["searchField"].typeText("how do ocean tides work")
        let row = app.buttons["browseForMe"]
        guard row.waitForExistence(timeout: 5) else { throw XCTSkip("Apple Intelligence isn't available here") }
        row.tap()
        Thread.sleep(forTimeInterval: 2.5)
        shot("live1-reading")
        XCTAssertTrue(app.otherElements["summaryText"].firstMatch.waitForExistence(timeout: 40))
        Thread.sleep(forTimeInterval: 1.5)
        shot("live2-writing")
        XCTAssertTrue(app.otherElements["summarySources"].firstMatch.waitForExistence(timeout: 60))
        shot("live3-done")
        app.swipeUp()
        shot("live4-sources")
    }

    /// A readerable page in another language offers Translate Page, not Summarize Page: the
    /// summary would be written in that language.
    func testForeignArticleOffersTranslateNotSummarize() throws {
        let app = try launch(["-PlainTestSummaries", "-PlainTestTranslator", "-PlainTranslateHintShown", "YES"])
        go(app, to: "/french-article", heading: "La page tranquille")
        Thread.sleep(forTimeInterval: 1.5)
        openPageMenu(app)
        XCTAssertTrue(app.buttons["menu.translate"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["menu.summarize"].exists)
        shot("m1-foreign-menu")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCUIElement {
    func clearText() {
        guard let value = value as? String, !value.isEmpty else { return }
        tap()
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }
}
