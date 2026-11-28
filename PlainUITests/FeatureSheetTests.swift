import XCTest

/// The sheets the shell presents: Settings (the engine change reaches the next search), History
/// (visits show and search finds them, a row opens its page) and favorites (added from the page
/// menu, shown above the keyboard, edited from the strip).
@MainActor
final class FeatureSheetTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ arguments: [String] = []) throws -> XCUIApplication {
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore"] + arguments
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        return app
    }

    private func go(_ app: XCUIApplication, to path: String, heading: String) {
        type(app, server.address(path) + "\n")
        // A fresh simulator's first page can take a while (the matrix makes a new one per row).
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 30), "page \"\(heading)\" did not show")
    }

    /// Opens the address field when it is closed, then types `text`.
    private func type(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(text)
    }

    /// Opens the page menu from More (the glass bar, or the Duo's vertical bar) and picks `item`.
    private func pageMenu(_ app: XCUIApplication, pick item: String) {
        let more = app.buttons["more"]
        XCTAssertTrue(more.waitForExistence(timeout: 2))
        more.tap()
        let action = app.buttons[item]
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the page menu")
        action.tap()
    }

    /// The archive in sections by when tabs moved there (the seed puts tabs in all four), newest
    /// first, with the footer once under the last; one tap on a row brings its tab back.
    func testArchiveGroupsTabsByWhenTheyWereArchived() throws {
        let app = try launch(["-PlainSeedArchive"])
        // A page, so More is the page sheet; a cold simulator's first page can take a while.
        type(app, server.address("/a") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 30), "page \"Page A\" did not show")
        pageMenu(app, pick: "more.archivedTabs")
        let sheet = app.otherElements["archiveSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.staticTexts["Today"].waitForExistence(timeout: 3))
        // Newest first (the order itself is ArchiveModelTests').
        if sheet.staticTexts["Yesterday"].exists {
            XCTAssertLessThan(sheet.staticTexts["Today"].frame.minY, sheet.staticTexts["Yesterday"].frame.minY)
        }
        let headers = ["Today", "Yesterday", "This Week", "Earlier"]
        let list = sheet.collectionViews.firstMatch
        var seen = Set<String>()
        for _ in 0 ..< 4 {
            seen.formUnion(headers.filter { sheet.staticTexts[$0].exists })
            if seen.count == headers.count { break }
            list.swipeUp(velocity: .slow)
        }
        XCTAssertEqual(seen, Set(headers), "a section is missing")
        let footer = sheet.staticTexts["Tabs you haven't opened in a week move here and leave 30 days later."]
        if !footer.exists { list.swipeUp(velocity: .slow) }
        XCTAssertTrue(footer.waitForExistence(timeout: 2), "the footer says when tabs come and go")

        let row = sheet.buttons.matching(identifier: "archiveRow")
            .matching(NSPredicate(format: "label BEGINSWITH 'A farewell to Arc'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3), "one tap restores the tab and closes the archive")
    }

    func testSettingsEngineChangeReachesTheNextSearch() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")

        pageMenu(app, pick: "menu.settings")
        let engineRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Search Engine'")).firstMatch
        XCTAssertTrue(engineRow.waitForExistence(timeout: 3))
        XCTAssertEqual(engineRow.label, "Search Engine, Google")
        engineRow.tap()
        let duck = app.buttons["DuckDuckGo"]
        XCTAssertTrue(duck.waitForExistence(timeout: 2))
        duck.tap()
        // Back to Settings. On the Duo the sheet's back button sits in the vertical bar.
        let back = app.otherElements["settingsSheet"].buttons["BackButton"]
        if back.exists { back.tap() } else { app.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(app.buttons["Search Engine, DuckDuckGo"].waitForExistence(timeout: 2), "the row shows the new value")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 3))

        type(app, "plain browser test\n")
        let pill = app.buttons["addressPill"]
        let searched = NSPredicate { _, _ in (pill.value as? String)?.contains("duckduckgo.com") == true }
        wait(for: [XCTNSPredicateExpectation(predicate: searched, object: nil)], timeout: 5)
    }

    func testHistoryShowsVisitsSearchesAndOpens() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        go(app, to: "/b", heading: "Page B")

        // No wait for the 2 s history batch: History writes what is queued before it reads.
        pageMenu(app, pick: "History")
        let sheet = app.otherElements["historySheet"]
        XCTAssertTrue(sheet.staticTexts["Plain Test A"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Plain Test B"].exists)

        // The search field, or a Search button where the sheet's toolbar folds it away.
        if !sheet.searchFields.firstMatch.exists { sheet.buttons["Search"].tap() }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.tap()
        search.typeText("Test A")
        let gone = NSPredicate { _, _ in !sheet.staticTexts["Plain Test B"].exists }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 3)
        XCTAssertTrue(sheet.staticTexts["Plain Test A"].exists)
        sheet.staticTexts["Plain Test A"].tap()

        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["addressPill"].value as? String, "http://" + server.address("/a"))
    }

    /// The Favorites sheet opens a favorite on a tap (clarity audit 7); rename is in its row's
    /// swipe and menu, not on the tap.
    func testFavoritesSheetOpensAFavoriteOnATap() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        pageMenu(app, pick: "Add to Favorites")
        go(app, to: "/b", heading: "Page B")
        pageMenu(app, pick: "menu.editFavorites")
        let row = app.buttons["favoriteRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["menu.editFavorites"].exists, false, "the page sheet went down for the Favorites sheet")
        row.swipeRight()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 2), "a swipe offers Rename")
        row.swipeLeft()
        Thread.sleep(forTimeInterval: 0.5)
        row.tap()
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10), "a tap opens the favorite")
        XCTAssertFalse(app.otherElements["favoritesSheet"].exists)
    }

    func testAddedFavoriteShowsAboveTheKeyboardAndOpensTheEditor() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")

        pageMenu(app, pick: "Add to Favorites")
        app.buttons["addressPill"].tap()
        let tile = app.buttons["favorite.0"]
        XCTAssertTrue(tile.waitForExistence(timeout: 3), "the favorite should show above the keyboard")
        XCTAssertEqual(tile.label, "Plain Test A")

        tile.press(forDuration: 1)
        let edit = app.buttons["Edit Favorites"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
        XCTAssertTrue(app.staticTexts["Favorites"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Plain Test A"].exists)
        // Edit Favorites opens editing: its Done ends the editing, then the sheet's Done closes it.
        XCTAssertFalse(app.buttons["Edit"].exists, "already editing")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 2))
        app.buttons["Done"].tap()
        // The field comes back, favorites and all.
        XCTAssertTrue(app.buttons["favorite.0"].waitForExistence(timeout: 3))

        // The page menu now offers the way back.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
        pageMenu(app, pick: "Remove from Favorites")
        app.buttons["addressPill"].tap()
        let removed = NSPredicate { _, _ in !app.buttons["favorite.0"].exists }
        wait(for: [XCTNSPredicateExpectation(predicate: removed, object: nil)], timeout: 3)
    }

    /// Done and Back sit in the sheet's top corners, lined up with the edges of the list's cards
    /// under them, on every screen (owner feedback: on the Duo's inner screen Done sat far in from
    /// the edge). History's Clear lines up the same way.
    func testSheetDoneSitsInTheTrailingCorner() throws {
        let app = try launch()
        // Every sheet is measured and captured even when one is off.
        continueAfterFailure = true
        go(app, to: "/a", heading: "Page A")
        var cards: (minX: CGFloat, maxX: CGFloat)?
        var regular = false
        for (item, identifier) in [("menu.settings", "settingsSheet"), ("History", "historySheet")] {
            pageMenu(app, pick: item)
            let sheet = app.otherElements[identifier]
            // In a regular width History opens in the side pane, which has no Done.
            if identifier == "historySheet", regular, !sheet.waitForExistence(timeout: 3) { continue }
            XCTAssertTrue(sheet.waitForExistence(timeout: 3))
            let done = sheet.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 3))
            Thread.sleep(forTimeInterval: 1)
            shotEveryScreen("done-\(identifier)")
            if identifier == "settingsSheet" {
                regular = sheet.horizontalSizeClass == .regular
                let card = sheet.cells.firstMatch.frame
                cards = (card.minX, card.maxX)
            }
            let edges = try XCTUnwrap(cards)
            print("SHEETFRAMES \(identifier) regular=\(regular) sheet=\(sheet.frame) cards=\(edges) done=\(done.frame)")
            XCTAssertEqual(done.frame.maxX, edges.maxX, accuracy: 4, "\(identifier): Done ends at \(done.frame.maxX), the cards at \(edges.maxX)")
            XCTAssertGreaterThanOrEqual(sheet.frame.maxX - done.frame.maxX, 15, "\(identifier): Done keeps a margin")
            XCTAssertGreaterThanOrEqual(done.frame.width, 44, "Done's target")
            XCTAssertGreaterThanOrEqual(done.frame.height, 44, "Done's target")
            if identifier == "settingsSheet" {
                // A pushed screen: Back in the leading corner.
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Search Engine'")).firstMatch.tap()
                let back = sheet.buttons["BackButton"]
                XCTAssertTrue(back.waitForExistence(timeout: 3), "Back is in the sheet's header")
                Thread.sleep(forTimeInterval: 1)
                shotEveryScreen("done-searchEngine")
                print("SHEETFRAMES back=\(back.frame)")
                XCTAssertEqual(back.frame.minX, edges.minX, accuracy: 4, "Back starts at \(back.frame.minX), the cards at \(edges.minX)")
                back.tap()
                XCTAssertTrue(done.waitForExistence(timeout: 3))
            }
            if identifier == "historySheet" {
                let clear = sheet.buttons["Clear…"]
                XCTAssertTrue(clear.waitForExistence(timeout: 2), "History's Clear is in the header")
                print("SHEETFRAMES clear=\(clear.frame)")
                XCTAssertEqual(clear.frame.minX, edges.minX, accuracy: 4, "Clear starts at \(clear.frame.minX), the cards at \(edges.minX)")
                clear.tap()
                XCTAssertTrue(app.buttons["All History"].waitForExistence(timeout: 2), "Clear opens its menu")
                // A tap outside the menu closes it without picking anything.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
                if !app.buttons["All History"].waitForNonExistence(timeout: 2) {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            done.tap()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
        }
    }

    /// Every screen the app can show, named `<name>-<width>x<height>`: on the Duo the one that is
    /// off is black, and the matrix keeps the one that shows something.
    private func shotEveryScreen(_ name: String) {
        for screen in XCUIScreen.screens {
            let image = screen.screenshot()
            let size = image.image.size
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
