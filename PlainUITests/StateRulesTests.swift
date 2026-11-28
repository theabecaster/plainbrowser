import XCTest

/// docs/state-rules.md end to end: the tabs slot's faces, the start screen with nothing open,
/// empty tabs that never pile up, private closes that offer no regular Reopen, and closing the
/// last private tab back to the regular one. Pages come from the local TestServer.
@MainActor
final class StateRulesTests: XCTestCase {
    private var server: TestServer!

    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore"]
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        return app
    }

    private func go(_ app: XCUIApplication, to path: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
    }

    /// Edits the page's own address (the page's row above the field) and goes, in the same tab.
    private func edit(_ app: XCUIApplication, to path: String) {
        app.buttons["addressPill"].tap()
        let row = app.buttons["focus.currentPage"]
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.tap()
        app.textFields["searchField"].typeText(server.address(path) + "\n")
    }

    private func waitForPage(_ app: XCUIApplication, _ heading: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show",
            file: file, line: line
        )
    }

    /// Closes the search field by tapping the space above it.
    private func closeSearch(_ app: XCUIApplication) {
        // The sheet's grabber, or Cancel where the field is in the top bar (the inner screen).
        let grabber = app.buttons["search.close"]
        let cancel = app.buttons["search.cancel"]
        if grabber.exists, grabber.isHittable {
            grabber.tap()
        } else if cancel.exists, cancel.isHittable {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        }
        XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Closes a New Tab's field but keeps the empty tab: something typed, so the close is not the
    /// untouched one that goes back to the page (docs/research/new-tab.md).
    private func keepNewTabAndCloseSearch(_ app: XCUIApplication) {
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText("x")
        closeSearch(app)
    }

    /// Picks an item from the tabs slot's long-press menu.
    private func tabsMenu(_ app: XCUIApplication, pick item: String, file: StaticString = #filePath, line: UInt = #line) {
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 2), file: file, line: line)
        tabs.press(forDuration: 1.0)
        let action = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the tabs menu", file: file, line: line)
        action.tap()
    }

    private func waitForTabCount(_ gallery: XCUIElement, _ count: Int) -> Bool {
        let value = count == 1 ? "1 tab" : "\(count) tabs"
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: gallery)
        return XCTWaiter.wait(for: [expectation], timeout: 4) == .completed
    }

    // MARK: Tests

    /// A failed load names the address that was tried, and Find on Page takes the bar's place.
    func testFailedPillAndFindReplacesTheBar() throws {
        let app = try launch()
        go(app, to: "/long")
        waitForPage(app, "Long Read")
        let pill = app.buttons["addressPill"]

        app.buttons["more"].tap()
        let find = app.buttons["Find on Page"]
        XCTAssertTrue(find.waitForExistence(timeout: 3))
        find.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pill)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed, "the find bar replaces the page's bar")
        app.typeText("Paragraph\n")
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Done', 'Close'}")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 3), "the bar comes back when the find bar closes")

        pill.tap()
        app.textFields["searchField"].typeText("127.0.0.1:9/nothing-here\n")
        let tried = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '127.0.0.1:9'"), object: pill)
        XCTAssertEqual(XCTWaiter.wait(for: [tried], timeout: 10), .completed, "the pill shows the address that was tried")
    }

    /// Nothing open: no switcher, no Back, Forward or New Tab; More and the shortcuts reach the rest.
    func testEmptyStartScreenHasNoSwitcher() throws {
        let app = try launch()
        closeSearch(app)
        XCTAssertTrue(app.otherElements["emptyTab"].exists || app.buttons["start.privateTab"].exists)
        XCTAssertFalse(app.buttons["tabs"].exists, "nothing to switch to and already in a new tab")
        XCTAssertFalse(app.buttons["back"].exists)
        XCTAssertFalse(app.buttons["forward"].exists)
        let plus = app.buttons["newTab"].firstMatch
        XCTAssertFalse(plus.exists && plus.isHittable, "already in a new tab")
        XCTAssertTrue(app.buttons["more"].exists)
        if !app.toolbars.firstMatch.exists {
            // The glass bar: More is a round button beside the pill, not a full-width bar.
            let more = app.buttons["more"].frame
            let pill = app.buttons["addressPill"].frame
            XCTAssertEqual(more.midY, pill.midY, accuracy: 2, "More sits beside the pill on the start screen")
            XCTAssertGreaterThan(more.minX, pill.maxX)
        }
        XCTAssertTrue(app.buttons["start.privateTab"].exists, "a private tab is always one tap away")
        XCTAssertFalse(app.buttons["start.reopenClosedTab"].exists, "nothing was closed")

        // A swipe up on the bar bumps; it never opens the gallery or the search field.
        app.buttons["addressPill"].swipeUp(velocity: .fast)
        XCTAssertFalse(app.scrollViews["tabGallery"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.textFields["searchField"].exists && app.textFields["searchField"].hasKeyboardFocus)

        // More holds New Private Tab where they all can see it.
        app.buttons["more"].tap()
        XCTAssertTrue(app.buttons["more.newPrivateTab"].waitForExistence(timeout: 3))
    }

    /// One page tab: the slot is Tabs, and a tap opens the switcher the swipe up opens, with the
    /// page's card alone (no New Tab card); the bar's + adds the second tab.
    func testOneTabTabsButtonOpensTheSwitcher() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 2))
        XCTAssertEqual(tabs.label, "Tabs")
        // Forward hides in place until there is somewhere forward; the Duo's vertical bar dims it.
        let forward = app.buttons["forward"]
        XCTAssertFalse(forward.exists && forward.isEnabled, "Forward does nothing yet")
        XCTAssertTrue(app.buttons["back"].exists, "Back stays, dimmed")

        tabs.tap()
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3), "the tap reaches the switcher with one tab")
        XCTAssertTrue(waitForTabCount(gallery, 1))
        XCTAssertFalse(app.descendants(matching: .any)["galleryNewTabCard"].exists, "no New Tab card (owner, 2026-11-27)")
        let newTab = app.buttons["galleryNewTab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 2), "New Tab is the + under the cards")
        newTab.tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2) && field.hasKeyboardFocus, "the + opens a new tab's search field")
        go(app, to: "/b")
        waitForPage(app, "Page B")
        XCTAssertEqual(app.buttons["tabs"].label, "Tabs")
        app.buttons["tabs"].tap()
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForTabCount(gallery, 2))
    }

    /// One page tab: the swipe up opens the switcher with its card alone, and the bar's + opens a
    /// second tab's search field. There is no New Tab card (owner, 2026-11-27).
    func testOneTabSwipeUpShowsItsCardAlone() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        app.buttons["addressPill"].swipeUp(velocity: .fast)
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3), "the swipe up reaches the switcher with one tab")
        XCTAssertTrue(waitForTabCount(gallery, 1))
        let newTabCard = app.descendants(matching: .any)["galleryNewTabCard"]
        XCTAssertFalse(newTabCard.exists, "no New Tab card beside the lone card")
        XCTAssertTrue(app.buttons["galleryNewTab"].exists, "the bar keeps its +")
        XCTAssertTrue(app.buttons["galleryDone"].exists)

        // Done goes back to the page; Show All Tabs opens the same switcher.
        app.buttons["galleryDone"].tap()
        waitForPage(app, "Page A")
        XCTAssertTrue(gallery.waitForNonExistence(timeout: 3))
        tabsMenu(app, pick: "Show All Tabs")
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForTabCount(gallery, 1))

        app.buttons["galleryNewTab"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2) && field.hasKeyboardFocus, "the + opens a new tab's search field")
        XCTAssertTrue(gallery.waitForNonExistence(timeout: 3))
        go(app, to: "/b")
        waitForPage(app, "Page B")
        XCTAssertEqual(app.buttons["tabs"].label, "Tabs", "two tabs now")
    }

    /// One page tab: swiping its card up closes it and lands in the search field, never an empty
    /// switcher. With an empty tab alone, the swipe up bumps.
    func testOneTabCardSwipedAwayGoesToSearch() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        app.buttons["addressPill"].swipeUp(velocity: .fast)
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        let card = gallery.descendants(matching: .any).matching(identifier: "tabCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.swipeUp(velocity: .fast)
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3) && field.hasKeyboardFocus, "straight to search")
        XCTAssertTrue(gallery.waitForNonExistence(timeout: 3))

        // The start screen alone has nothing to show: the swipe up bumps.
        closeSearch(app)
        XCTAssertFalse(app.buttons["tabs"].exists)
        app.buttons["addressPill"].swipeUp(velocity: .fast)
        XCTAssertFalse(gallery.waitForExistence(timeout: 1))
    }

    /// New Tab on an empty tab reuses it, and leaving an empty tab drops it: no blank cards.
    func testEmptyTabsDoNotPileUp() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        tabsMenu(app, pick: "New Tab")
        keepNewTabAndCloseSearch(app)
        // The tabs menu on an empty tab has no New Tab: it would be this tab again.
        app.buttons["tabs"].press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["menu.newPrivateTab"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["menu.newTab"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        // On the empty tab: Tabs (Page A is somewhere to switch to), and the gallery shows one card.
        app.buttons["tabs"].tap()
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForTabCount(gallery, 1), "an empty tab is never a card; found \(String(describing: gallery.value))")
        // The gallery's + reuses the empty tab on screen.
        app.buttons["galleryNewTab"].tap()
        closeSearch(app)
        app.buttons["tabs"].tap()
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForTabCount(gallery, 1))
        // Opening Page A leaves the empty tab, which goes away for good.
        gallery.descendants(matching: .any).matching(identifier: "tabCard").firstMatch.tap()
        waitForPage(app, "Page A")
        XCTAssertTrue(gallery.waitForNonExistence(timeout: 3))
        app.buttons["tabs"].tap()
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForTabCount(gallery, 1), "one page tab left: the empty one was dropped")
    }

    /// Closing a private tab never offers a regular Reopen, and closing the last private tab goes
    /// back to the regular tab that was open.
    func testLastPrivateCloseReturnsToRegularWithNoReopen() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        // A regular close first, so a wrong Reopen would have something to bring back.
        tabsMenu(app, pick: "New Tab")
        go(app, to: "/c")
        waitForPage(app, "Page C")
        tabsMenu(app, pick: "Close Tab")
        waitForPage(app, "Page A")
        XCTAssertTrue(app.buttons["toastButton"].waitForExistence(timeout: 3.5), "a regular close offers Reopen")

        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/b")
        waitForPage(app, "Page B")
        XCTAssertEqual(app.buttons["addressPill"].label, "Private Address")
        tabsMenu(app, pick: "Close Tab")
        waitForPage(app, "Page A")
        XCTAssertNotEqual(app.buttons["addressPill"].label, "Private Address")
        let field = app.textFields["searchField"]
        XCTAssertFalse(field.exists && field.hasKeyboardFocus, "not an empty search field")
        XCTAssertFalse(app.buttons["toastButton"].exists, "a private close offers no Reopen")
    }

    /// In the gallery, a private card's close shows no Reopen toast.
    func testPrivateCardCloseOffersNoReopen() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/b")
        waitForPage(app, "Page B")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/c")
        waitForPage(app, "Page C")
        app.buttons["tabs"].tap()
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForTabCount(gallery, 2), "the private list: \(String(describing: gallery.value))")
        let card = gallery.descendants(matching: .any).matching(identifier: "tabCard").firstMatch
        card.swipeUp(velocity: .fast)
        XCTAssertTrue(waitForTabCount(gallery, 1))
        XCTAssertFalse(app.buttons["reopenTab"].waitForExistence(timeout: 1), "private tabs never come back")
    }

    /// An empty private tab's shortcut leaves private browsing, so it says so: "Regular Tab".
    func testEmptyPrivateTabOffersARegularTab() throws {
        let app = try launch()
        closeSearch(app)
        app.buttons["start.privateTab"].tap()
        closeSearch(app)
        let regular = app.buttons["start.regularTab"]
        XCTAssertTrue(regular.waitForExistence(timeout: 3))
        XCTAssertEqual(regular.label, "Regular Tab")
        XCTAssertFalse(app.buttons["start.privateTab"].exists, "already private")
    }

    /// With only private tabs open and an empty regular tab, the private tabs are one tap away.
    func testPrivateTabsReachableFromTheStartScreen() throws {
        let app = try launch()
        closeSearch(app)
        app.buttons["start.privateTab"].tap()
        go(app, to: "/b")
        waitForPage(app, "Page B")
        tabsMenu(app, pick: "New Tab")
        keepNewTabAndCloseSearch(app)
        app.buttons["tabs"].tap()
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForTabCount(gallery, 1), "opens on the private list, which has the tab")
        XCTAssertEqual(app.buttons["galleryPrivate"].value as? String, "On")
    }

    /// While a page loads, the page menu offers Stop in Reload's place; stopped before it
    /// committed, the tab stays on the page it showed.
    func testStopReplacesReloadWhileLoading() throws {
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        app.buttons["more"].tap()
        XCTAssertTrue(app.buttons["menu.reload"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["menu.stop"].exists)
        app.buttons["menu.reload"].tap()
        Thread.sleep(forTimeInterval: 1)

        // In the same tab: edit the page's address (a search from the pill would open a new tab).
        edit(app, to: "/slow")
        Thread.sleep(forTimeInterval: 1)
        app.buttons["more"].tap()
        let stop = app.buttons["menu.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "Stop shows while the page loads")
        XCTAssertFalse(app.buttons["menu.reload"].exists, "Reload and Stop share one place")
        stop.tap()
        // Stopped before it committed: the tab stays on Page A.
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 3))
    }

    /// The open search sheet is never empty and never draws over the start screen's mark: on a
    /// first run its one sentence shows and the mark steps back; rows do the same.
    func testStartScreenYieldsToSuggestions() throws {
        let app = try launch()
        let field = app.textFields["searchField"]
        let mark = app.images["startMark"]
        XCTAssertTrue(app.buttons["focus.hint"].waitForExistence(timeout: 2) || app.staticTexts["focus.hint"].exists, "first run: the sheet says what will show")
        XCTAssertTrue(mark.waitForNonExistence(timeout: 2), "the mark steps back for the sheet")
        go(app, to: "/a")
        waitForPage(app, "Page A")
        tabsMenu(app, pick: "New Tab")
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        // Page A is a recent page now: the field shows it, and the mark steps back for it.
        let recent = app.buttons["Plain Test A"]
        XCTAssertTrue(recent.waitForExistence(timeout: 3), "the recent page above the empty field")
        XCTAssertTrue(mark.waitForNonExistence(timeout: 2), "the mark recedes for the field's own rows")

        field.typeText("Plain Test")
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "history suggestion for page A, the same row")
        XCTAssertTrue(recent.isHittable, "rows sit above everything")

        // Cleared, the field's own rows come back, still without the mark under them.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Plain Test".count))
        XCTAssertTrue(recent.waitForExistence(timeout: 2))
        XCTAssertFalse(mark.exists)
    }
}
