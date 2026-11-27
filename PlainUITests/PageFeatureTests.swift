import XCTest

/// Translate Page, Print and Save as PDF, and cookie banners, through the page menu. The engine
/// side is tested in WebEngineTests (TranslationTests, PageExportTests) and ContentBlockingTests
/// (CookieBannerTests). Apple's Translation framework doesn't run in the simulator, so the app
/// uses its test translator here (`-PlainTestTranslator`), which knows `/french`'s sentences.
@MainActor
final class PageFeatureTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication()
        app.launchArguments = ["-PlainInMemoryStore", "-PlainTestTranslator", "-PlainTranslateHintShown", "YES"] + extra
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
        XCTAssertTrue(app.buttons["Settings…"].waitForExistence(timeout: 3))
    }

    private func closeMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    func testTranslatePageAndShowOriginal() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        openPageMenu(app)
        XCTAssertFalse(app.buttons["menu.translate"].waitForExistence(timeout: 1), "a page the user reads is not offered")
        closeMenu(app)

        go(app, to: "/french", heading: "Le marché du samedi")
        Thread.sleep(forTimeInterval: 1)
        openPageMenu(app)
        let translate = app.buttons["menu.translate"]
        XCTAssertTrue(translate.waitForExistence(timeout: 3), "a French page offers Translate Page")
        XCTAssertTrue(translate.label.hasPrefix("Translate Page"), translate.label)
        shot("t1-menu-translate")
        translate.tap()
        XCTAssertTrue(app.webViews.staticTexts["The Saturday market"].waitForExistence(timeout: 10), "the page is translated")
        XCTAssertTrue(app.webViews.links["Read more"].exists, "links keep working, translated")
        Thread.sleep(forTimeInterval: 0.8)
        shot("t2-translated")

        openPageMenu(app)
        let original = app.buttons["menu.translate"]
        XCTAssertTrue(original.waitForExistence(timeout: 3))
        XCTAssertTrue(original.label.hasPrefix("Show Original"), original.label)
        shot("t3-menu-show-original")
        original.tap()
        XCTAssertTrue(app.webViews.staticTexts["Le marché du samedi"].waitForExistence(timeout: 5), "the original is back")
        Thread.sleep(forTimeInterval: 0.5)
        shot("t4-original")
    }

    func testForeignPageHintShowsOnce() throws {
        let app = try launch(["-PlainTranslateHintShown", "NO"])
        go(app, to: "/french", heading: "Le marché du samedi")
        let button = app.buttons["Translate"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the one quiet hint offers Translate")
        XCTAssertTrue(app.staticTexts["This page is in French"].exists)
        shot("t5-hint")
        button.tap()
        XCTAssertTrue(app.webViews.staticTexts["The Saturday market"].waitForExistence(timeout: 10))
    }

    func testPrintAndSaveAsPDF() throws {
        let app = try launch()
        go(app, to: "/article", heading: "The Quiet Page")
        openPageMenu(app)
        let print = app.buttons["menu.print"]
        XCTAssertTrue(print.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["menu.saveAsPDF"].exists)
        shot("p1-menu-export")
        print.tap()
        // The system print sheet: a preview with its Print button.
        let printButton = app.buttons.matching(NSPredicate(format: "label == 'Print'")).firstMatch
        XCTAssertTrue(printButton.waitForExistence(timeout: 10), "the print sheet shows")
        Thread.sleep(forTimeInterval: 1.5)
        shot("p2-print-sheet")
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == 'Close'")).firstMatch
        if cancel.exists { cancel.tap() } else { app.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1)

        openPageMenu(app)
        app.buttons["menu.saveAsPDF"].tap()
        // The share sheet with the PDF: Save to Files is one of its actions.
        let files = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Save to Files'")).firstMatch
        let sheet = app.otherElements["ActivityListView"]
        let shown = files.waitForExistence(timeout: 10) || sheet.waitForExistence(timeout: 2)
        XCTAssertTrue(shown, "the share sheet offers the PDF")
        Thread.sleep(forTimeInterval: 1)
        shot("p3-pdf-share")
    }

    func testCookieBannerIsAnsweredAndTheSiteCanTurnItOff() throws {
        let app = try launch()
        go(app, to: "/consent", heading: "Fresh bread, every morning.")
        // Rejected by the engine, or hidden by the cookie list: either way the banner is gone and
        // nothing was accepted.
        let accept = app.webViews.buttons["Accept All"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: accept)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "the cookie banner is gone")
        XCTAssertFalse(app.webViews.staticTexts["Cookies accepted"].exists)
        Thread.sleep(forTimeInterval: 0.5)
        shot("c1-banner-gone")

        openPageMenu(app)
        let site = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Site Settings'")).firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 2))
        site.tap()
        let toggle = app.buttons["menu.cookieBanners"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        XCTAssertEqual(toggle.label, "Turn Off Cookie Banner Blocking")
        shot("c2-site-settings")
        toggle.tap()
        Thread.sleep(forTimeInterval: 1.5)
        openPageMenu(app)
        site.tap()
        XCTAssertTrue(app.buttons["menu.cookieBanners"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.buttons["menu.cookieBanners"].label, "Turn On Cookie Banner Blocking", "remembered for the site")
        closeMenu(app)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
