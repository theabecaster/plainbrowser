import XCTest

/// Private as a clear mode on wide screens (docs/decisions.md, "Private as a clear mode on wide
/// screens, in Night and Horizon"): the strip and the sidebar list one mode's tabs, never the two
/// mixed; their Private | Tabs switch enters and leaves in one tap and brings back the tab seen
/// last; a split shows one mode; Close All Private Tabs is on the switch's Private side.
///
/// They need a regular-width window: the Duo's inner screen unfolded (`scripts/duo-fold.sh <sim>
/// Open`) or an iPad-size resizable window. Elsewhere they skip.
@MainActor
final class PrivateWideTests: XCTestCase {
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
        if arguments.contains("-PlainTabLayout") || arguments.contains("-PlainOpen") {
            XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 8))
            let field = app.textFields["searchField"]
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !field.exists }, object: nil)
            _ = XCTWaiter().wait(for: [closed], timeout: 6)
        } else {
            XCTAssertTrue(app.waitForFirstScreen())
        }
        return app
    }

    /// Skips unless the window is regular width (the strip and the sidebar show only there).
    private func requireWide(_ app: XCUIApplication, landscape: Bool = false) throws {
        let width = app.windows.firstMatch.frame.width
        try XCTSkipUnless(width >= (landscape ? 900 : 640), "needs a regular-width window (window is \(Int(width)) pt wide)")
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

    private func tabsMenu(_ app: XCUIApplication, pick item: String) {
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 2))
        tabs.press(forDuration: 1.0)
        let action = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the tabs menu")
        action.tap()
    }

    private func pageMenu(_ app: XCUIApplication, pick item: String) {
        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 2))
        pill.press(forDuration: 1.0)
        let action = app.buttons[item]
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the page menu")
        action.tap()
    }

    private func wait(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, until condition: @escaping () -> Bool
    ) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, what, file: file, line: line)
    }

    private func pillShows(_ app: XCUIApplication, _ path: String) -> Bool {
        (app.buttons["addressPill"].value as? String)?.hasSuffix(path) == true
    }

    private func isPrivate(_ app: XCUIApplication) -> Bool {
        app.buttons["addressPill"].label == "Private Address"
    }

    /// Closes the search field by tapping the page area above it.
    private func closeSearch(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func stripTabs(_ app: XCUIApplication) -> XCUIElementQuery {
        app.otherElements["tabStrip"].descendants(matching: .any).matching(identifier: "stripTab")
    }

    private func sideRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.otherElements["sideTabs"].descendants(matching: .any).matching(identifier: "sideTab")
    }

    // MARK: The strip

    /// The strip lists the regular tabs only; Private at its end enters private in one tap (a new
    /// private tab, the field up), the strip then lists the private tabs only, and Tabs brings the
    /// regular tab seen last back in one tap. Private again brings the private tab back.
    func testTheStripShowsOneModeAndItsSwitchEntersAndLeaves() throws {
        let app = try launch()
        try requireWide(app)
        go(app, to: "/a", heading: "Page A")
        tabsMenu(app, pick: "New Tab")
        go(app, to: "/b", heading: "Page B")
        let tabs = stripTabs(app)
        wait("two regular tabs in the strip") { tabs.count == 2 }
        let privateSide = app.buttons["tabStrip.private"]
        let tabsSide = app.buttons["tabStrip.regular"]
        XCTAssertTrue(tabsSide.isSelected, "the shown mode is selected")
        XCTAssertFalse(privateSide.isSelected)

        privateSide.tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 3), "a new private tab, straight to the field")
        go(app, to: "/c", heading: "Page C")
        wait("in private") { self.isPrivate(app) }
        wait("the strip lists the private tab only") { tabs.count == 1 }
        XCTAssertTrue(privateSide.isSelected)
        XCTAssertEqual(tabsSide.value as? String, "2 tabs", "the other side's count")

        tabsSide.tap()
        wait("one tap back to the regular tab seen last") { self.pillShows(app, "/b") }
        XCTAssertFalse(isPrivate(app))
        wait("the strip lists the regular tabs again") { tabs.count == 2 }
        XCTAssertEqual(privateSide.value as? String, "1 tab", "the private tab stays open")

        privateSide.tap()
        wait("the private tab seen last comes back") { self.pillShows(app, "/c") }
        XCTAssertTrue(isPrivate(app))
    }

    /// Entering private with none open shows the private start screen behind the field, and
    /// closing the field untouched stays in private (it was asked for), with the way out on it.
    func testEnteringPrivateFromTheSwitchStaysPrivate() throws {
        let app = try launch()
        try requireWide(app)
        go(app, to: "/a", heading: "Page A")
        tabsMenu(app, pick: "New Tab")
        go(app, to: "/b", heading: "Page B")
        app.buttons["tabStrip.private"].tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 3))
        closeSearch(app)
        XCTAssertTrue(app.staticTexts["start.privateTitle"].waitForExistence(timeout: 3), "the private start screen")
        XCTAssertTrue(isPrivate(app))
        XCTAssertTrue(app.buttons["start.regularTab"].exists, "Leave Private is on it")
        app.buttons["tabStrip.regular"].tap()
        wait("out of private, on the regular tab seen last") { self.pillShows(app, "/b") }
        XCTAssertFalse(app.staticTexts["start.privateTitle"].exists)
    }

    /// The top bar's "+" opens the shown mode's kind; its long press, the other one.
    func testNewTabOpensTheShownModeAndItsLongPressTheOther() throws {
        let app = try launch()
        try requireWide(app)
        go(app, to: "/a", heading: "Page A")
        let plus = app.buttons["newTab"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 2))
        plus.press(forDuration: 1.0)
        let other = app.buttons["newTabMenu.private"]
        XCTAssertTrue(other.waitForExistence(timeout: 3), "New Private Tab on the long press")
        other.tap()
        go(app, to: "/b", heading: "Page B")
        wait("in private") { self.isPrivate(app) }
        plus.tap()
        go(app, to: "/c", heading: "Page C")
        wait("the \"+\" of a private page stays private") { self.isPrivate(app) }
        wait("two private tabs in the strip") { self.stripTabs(app).count == 2 }
    }

    /// Close All Private Tabs from the switch's Private side: every private tab goes, the regular
    /// tab seen last is back, nothing private is left to come back.
    func testCloseAllPrivateTabsFromTheSwitch() throws {
        let app = try launch()
        try requireWide(app)
        go(app, to: "/a", heading: "Page A")
        app.buttons["newTab"].firstMatch.press(forDuration: 1.0)
        app.buttons["newTabMenu.private"].tap()
        go(app, to: "/b", heading: "Page B")
        app.buttons["newTab"].firstMatch.tap()
        go(app, to: "/c", heading: "Page C")
        let privateSide = app.buttons["tabStrip.private"]
        wait("two private tabs") { privateSide.value as? String == "2 tabs" }
        privateSide.press(forDuration: 1.0)
        let closeAll = app.buttons["tabStrip.closeAllPrivate"]
        XCTAssertTrue(closeAll.waitForExistence(timeout: 3))
        closeAll.tap()
        wait("back on the regular tab") { self.pillShows(app, "/a") }
        XCTAssertFalse(isPrivate(app))
        XCTAssertFalse(app.buttons["reopenTab"].exists, "private tabs never come back")
    }

    // MARK: The sidebar

    /// The sidebar lists one mode's tabs; its head's Private and Tabs rows switch, one tap each.
    func testTheSidebarShowsOneModeAndItsHeadSwitches() throws {
        let app = try launch(["-PlainInMemoryStore", "-PlainTabLayout", "left"])
        try requireWide(app)
        go(app, to: "/a", heading: "Page A")
        tabsMenu(app, pick: "New Tab")
        go(app, to: "/b", heading: "Page B")
        let rows = sideRows(app)
        wait("two regular rows") { rows.count == 2 }
        let privateRow = app.otherElements["sideTabs"].descendants(matching: .any)["sideTabs.private"]
        let tabsRow = app.otherElements["sideTabs"].descendants(matching: .any)["sideTabs.regular"]
        XCTAssertTrue(tabsRow.isSelected)
        privateRow.tap()
        go(app, to: "/c", heading: "Page C")
        wait("in private") { self.isPrivate(app) }
        wait("the private row only") { rows.count == 1 }
        XCTAssertTrue(privateRow.isSelected)
        XCTAssertEqual(tabsRow.value as? String, "2 tabs")
        tabsRow.tap()
        wait("back to the regular tab seen last") { self.pillShows(app, "/b") }
        wait("the regular rows again") { rows.count == 2 }
        XCTAssertFalse(isPrivate(app))
    }

    // MARK: Split

    /// A split shows one mode: going private in a split ends it (the other pane's tab stays open
    /// in its list), and coming back shows the one regular page.
    func testASplitEndsWhenTheModeChanges() throws {
        let app = try launch()
        try requireWide(app, landscape: true)
        go(app, to: "/a", heading: "Page A")
        tabsMenu(app, pick: "New Tab")
        go(app, to: "/b", heading: "Page B")
        pageMenu(app, pick: "menu.otherPane")
        let a = app.webViews.staticTexts["Page A"]
        let b = app.webViews.staticTexts["Page B"]
        wait("pages A and B side by side", timeout: 10) { a.exists && b.exists && a.frame.maxX <= b.frame.minX }

        app.buttons["tabStrip.private"].tap()
        go(app, to: "/c", heading: "Page C")
        wait("in private, one pane") { self.isPrivate(app) && !a.exists && !b.exists }
        let c = app.webViews.staticTexts["Page C"]
        XCTAssertLessThan(c.frame.minX, app.windows.firstMatch.frame.width / 3, "the private page fills the window")

        app.buttons["tabStrip.regular"].tap()
        wait("back on the regular tab seen last, alone") { self.pillShows(app, "/b") && !a.exists }
        XCTAssertEqual(app.buttons["tabStrip.regular"].value as? String, "2 tabs", "A is still open")
    }

    // MARK: Captures

    /// Screenshots of wide private states for design review, with `PLAIN_CAPTURE=1` only:
    /// `PLAIN_CAPTURE_TAG` prefixes each (the row: inner landscape or portrait, light or dark).
    /// Each state is its own launch (`-PlainOpen`, `-PlainOpenPrivate`, `-PlainTabLayout`,
    /// `-PlainSidebar`), and each private one has its regular twin with the same tabs.
    func testCaptureWidePrivateStates() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let tag = environment["PLAIN_CAPTURE_TAG"] ?? "wide"
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let url = { (path: String) in "http://" + self.server.address(path) }
        let five = ["/long", "/light-site", "/article", "/a", "/dark-site"].map(url).joined(separator: ",")
        let two = ["/light-site", "/long"].map(url).joined(separator: ",")
        let one = url("/long")
        // name, regular pages, private pages, layout, sidebar
        let states: [(String, String, String?, String, String?)] = [
            ("strip-1", one, one, "above", nil),
            ("strip-2", two, two, "above", nil),
            ("strip-5", five, five, "above", nil),
            ("rail-2", two, two, "left", "rail"),
            ("rail-5", five, five, "left", "rail"),
            ("expanded-5", five, five, "left", "expanded"),
        ]
        for (name, regular, privatePages, layout, sidebar) in states {
            // Private: the regular tabs, then the private ones (the last on screen).
            var arguments = ["-PlainInMemoryStore", "-PlainTabLayout", layout, "-PlainOpen", regular]
            if let sidebar { arguments += ["-PlainSidebar", sidebar] }
            if let privatePages { arguments += ["-PlainOpenPrivate", privatePages] }
            let app = try launch(arguments)
            settle(4)
            shot("\(tag)-\(name)-private")
            // Its regular twin: one tap on Tabs, the same tabs open.
            let tabsSide = app.buttons["tabStrip.regular"].exists ? app.buttons["tabStrip.regular"]
                : app.otherElements["sideTabs"].descendants(matching: .any)["sideTabs.regular"]
            if tabsSide.exists {
                tabsSide.tap()
            } else {
                // One tab each (no list): the regular page through the tabs menu's switcher.
                app.buttons["tabs"].tap()
                if app.buttons["galleryRegular"].waitForExistence(timeout: 3) {
                    app.buttons["galleryRegular"].tap()
                    app.scrollViews["tabGallery"].descendants(matching: .any).matching(identifier: "tabCard").firstMatch.tap()
                }
            }
            settle(2)
            shot("\(tag)-\(name)-regular")
            app.terminate()
        }

        // The private start screen and the focused field in private, with the strip.
        var app = try launch(["-PlainInMemoryStore", "-PlainTabLayout", "above", "-PlainOpen", two])
        app.buttons["tabStrip.private"].tap()
        settle(1.5)
        shot("\(tag)-focus-private")
        closeSearch(app)
        settle(1)
        shot("\(tag)-start-private")
        // Entry and exit, frame by frame (as fast as the runner can take them).
        app.buttons["tabStrip.regular"].tap()
        for index in 0..<4 { shot("\(tag)-exit-\(index)") }
        settle(1)
        app.buttons["tabStrip.private"].tap()
        for index in 0..<4 { shot("\(tag)-entry-\(index)") }
        app.terminate()

        // A private split: two private pages side by side.
        app = try launch([
            "-PlainInMemoryStore", "-PlainTabLayout", "above", "-PlainOpen", one,
            "-PlainOpenPrivate", ["/long", "/light-site"].map(url).joined(separator: ","), "-PlainSplit",
        ])
        settle(4)
        shot("\(tag)-split-private")
        app.terminate()
    }

    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        // The largest screen that shows something (the Duo's inner one when open).
        let screens = XCUIScreen.screens.map { $0.screenshot() }
        guard let image = screens.max(by: { $0.image.size.width * $0.image.size.height < $1.image.size.width * $1.image.size.height })
        else { return }
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
