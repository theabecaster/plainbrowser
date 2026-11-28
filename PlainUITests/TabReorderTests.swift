import XCTest

/// Drag to reorder in the Duo's tab strip: across other tabs, at the private tabs' boundary (a
/// regular tab never becomes private, nor the reverse), and quick drags one after another.
/// TestFlight 2611280102 crashed here ("holding a tab and moved it around").
///
/// Needs the iPhone Duo simulator unfolded (`scripts/duo-fold.sh <sim> Open`); elsewhere it skips.
@MainActor
final class TabReorderTests: XCTestCase {
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
        try XCTSkipUnless(app.windows.firstMatch.frame.width >= 900, "needs the Duo's inner screen (window is \(Int(app.windows.firstMatch.frame.width)) pt wide)")
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

    private func tabsMenu(_ app: XCUIApplication, pick item: String) {
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 2))
        tabs.press(forDuration: 1.0)
        let action = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the tabs menu")
        action.tap()
    }

    private func stripTabs(_ app: XCUIApplication) -> XCUIElementQuery {
        app.otherElements["tabStrip"].descendants(matching: .any).matching(identifier: "stripTab")
    }

    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        stripTabs(app).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// The strip's titles left to right, once all five tabs are where they settle.
    private func order(_ app: XCUIApplication) -> [String] {
        var last: [String] = []
        for _ in 0..<15 {
            let now = stripTabs(app).allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }.map(\.label)
            if now.count == regular.count + privateTitles.count, now == last { return now }
            last = now
            Thread.sleep(forTimeInterval: 0.3)
        }
        return last
    }

    /// Holds `title`'s tab, then moves it onto `target`'s and lets go.
    private func drag(_ app: XCUIApplication, _ title: String, onto target: String, hold: TimeInterval = 0.8,
                      velocity: XCUIGestureVelocity = .default, settle: TimeInterval = 0.4) {
        let from = tab(app, title), to = tab(app, target)
        XCTAssertTrue(from.waitForExistence(timeout: 3), "\(title) is not in the strip")
        XCTAssertTrue(to.exists, "\(target) is not in the strip")
        from.press(forDuration: hold, thenDragTo: to, withVelocity: velocity, thenHoldForDuration: settle)
    }

    private func assertAlive(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "Plain stopped after: \(step)", file: file, line: line)
    }

    private let regular = ["Plain Test A", "Plain Test B", "Plain Test C"]
    private let privateTitles = ["Plain Long Read", "Plain Files"]

    /// Regular tabs first, private ones after, every tab once.
    private func assertListsApart(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = order(app)
        XCTAssertEqual(Set(shown), Set(regular + privateTitles), "after \(step): \(shown)", file: file, line: line)
        XCTAssertEqual(Set(shown.prefix(regular.count)), Set(regular), "after \(step), lists mixed: \(shown)", file: file, line: line)
    }

    func testDraggingStripTabsAcrossOthersAndListsKeepsPlainRunning() throws {
        let app = try launch()
        go(app, to: "/a", heading: "Page A")
        tabsMenu(app, pick: "New Tab")
        go(app, to: "/b", heading: "Page B")
        tabsMenu(app, pick: "New Tab")
        go(app, to: "/c", heading: "Page C")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/long", heading: "Long Read")
        tabsMenu(app, pick: "New Private Tab")
        go(app, to: "/files", heading: "Files")
        let five = NSPredicate { _, _ in self.stripTabs(app).count == 5 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: five, object: nil)], timeout: 5), .completed,
                       "the strip lists five tabs")
        XCTAssertEqual(order(app), regular + privateTitles)

        // Across the others, to the end of its list, and back.
        drag(app, "Plain Test A", onto: "Plain Test C")
        assertAlive(app, "A onto C")
        assertListsApart(app, "A onto C")
        XCTAssertNotEqual(order(app).first, "Plain Test A", "A moved along")
        drag(app, "Plain Test C", onto: order(app)[0])
        assertAlive(app, "C to the front")
        assertListsApart(app, "C to the front")

        // Into the private tabs and out of them: refused, the lists stay apart.
        drag(app, "Plain Test B", onto: "Plain Files")
        assertAlive(app, "regular into private")
        assertListsApart(app, "regular into private")
        drag(app, "Plain Files", onto: order(app)[0])
        assertAlive(app, "private into regular")
        assertListsApart(app, "private into regular")
        // Within the private tabs.
        drag(app, "Plain Files", onto: "Plain Long Read")
        assertAlive(app, "private within private")
        assertListsApart(app, "private within private")

        // Quick drags, one straight after another.
        for (index, step) in [("Plain Test A", "Plain Test B"), ("Plain Test B", "Plain Test C"), ("Plain Test C", "Plain Test A"),
                              ("Plain Test A", "Plain Long Read"), ("Plain Test B", "Plain Test A")].enumerated() {
            // A short hover before letting go: a release with no hover at all can leave the
            // simulator's drag session waiting, so XCTest never sees the app idle.
            drag(app, step.0, onto: step.1, hold: 0.6, velocity: .fast, settle: 0.15)
            assertAlive(app, "quick drag \(index + 1)")
        }
        assertListsApart(app, "quick drags")

        // The strip still switches tabs.
        tab(app, "Plain Test B").tap()
        let pill = app.buttons["addressPill"]
        let showsB = NSPredicate { _, _ in (pill.value as? String)?.hasSuffix("/b") == true }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: showsB, object: nil)], timeout: 5), .completed)
    }
}
