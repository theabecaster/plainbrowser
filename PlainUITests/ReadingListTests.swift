import XCTest

/// Read Later and the Reading List (docs/research/bookmarks.md): saving a page with its reader
/// copy, the list's sections and swipes, the address bar ranking, and the saved copy opening when
/// the page can't load. Storage and the list's model are tested in StorageTests and FeatureUITests.
@MainActor
final class ReadingListTests: XCTestCase {
    private var server: TestServer!

    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication.isolated()
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

    private func save(_ app: XCUIApplication) {
        openPageMenu(app)
        let readLater = app.buttons["menu.readLater"]
        XCTAssertTrue(readLater.waitForExistence(timeout: 3))
        XCTAssertTrue(readLater.label.hasPrefix("Read Later"), readLater.label)
        readLater.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    private func openReadingList(_ app: XCUIApplication) -> XCUIElement {
        openPageMenu(app)
        app.buttons["menu.readingList"].tap()
        let sheet = app.otherElements["readingListSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        return sheet
    }

    func testReadLaterSavesTheArticleAndTheListMarksItRead() throws {
        let app = try launch()
        go(app, to: "/article", heading: "The Quiet Page")
        // Show Reader waits for the article check; Read Later saves the article with it.
        Thread.sleep(forTimeInterval: 1.5)
        save(app)
        go(app, to: "/a", heading: "Page A")
        save(app)

        openPageMenu(app)
        XCTAssertEqual(app.buttons["menu.readLater"].label, "Remove from Reading List", "the menu knows the page is saved")
        shot("r1-menu-saved")
        app.buttons["menu.readingList"].tap()
        XCTAssertTrue(app.otherElements["readingListSheet"].waitForExistence(timeout: 3))
        let rows = app.buttons.matching(identifier: "readingListRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(rows.count, 2)
        // Newest first; the article shows its reading time, the plain page only its site.
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("Page A"), rows.element(boundBy: 0).label)
        let article = rows.element(boundBy: 1)
        XCTAssertTrue(article.label.contains("The Quiet Page"), article.label)
        XCTAssertTrue(article.label.contains("min"), "a saved copy has a reading time: \(article.label)")
        shot("r2-list")

        // Swipe right: read, in the Read section.
        rows.element(boundBy: 0).swipeRight()
        let markRead = app.buttons["Mark Read"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 2))
        markRead.tap()
        XCTAssertTrue(app.staticTexts["Read"].waitForExistence(timeout: 2), "the Read section shows")
        XCTAssertEqual(rows.element(boundBy: 1).value as? String, "Read")
        shot("r3-read")

        // Opening the article loads it and marks it read.
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(app.webViews.staticTexts["The Quiet Page"].waitForExistence(timeout: 10))
        _ = openReadingList(app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue((0..<rows.count).allSatisfy { rows.element(boundBy: $0).value as? String == "Read" })
    }

    func testSavedPagesRankInTheAddressBar() throws {
        let app = try launch()
        go(app, to: "/article", heading: "The Quiet Page")
        Thread.sleep(forTimeInterval: 1.5)
        save(app)
        app.buttons["addressPill"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText("quiet")
        let first = app.buttons["suggestion.page.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertTrue(first.label.contains("The Quiet Page"), first.label)
        shot("r4-suggestion")
    }

    func testTheSavedCopyOpensWhenThePageCannotLoad() throws {
        let app = try launch()
        go(app, to: "/article", heading: "The Quiet Page")
        Thread.sleep(forTimeInterval: 1.5)
        save(app)
        go(app, to: "/a", heading: "Page A")
        // The site goes away: opening the saved page fails, and its copy shows in the reader.
        server.stop()
        _ = openReadingList(app)
        let row = app.buttons.matching(identifier: "readingListRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        let reader = app.webViews["readerView"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "the saved copy opens in the reader")
        XCTAssertTrue(reader.staticTexts["The Quiet Page"].waitForExistence(timeout: 5))
        shot("r5-offline-copy")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
