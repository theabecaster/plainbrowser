import XCTest

/// What Plain opens to (docs/state-rules.md, "Launch and return"): the last tab from the first
/// screen, search when there is no tab, and a fresh search over the last tab after a long time
/// away (`-PlainAwayOffset` runs the rules' clock ahead). Relaunches use the test store.
@MainActor
final class LaunchTests: XCTestCase {
    private var server: TestServer!
    /// Five hours: past `FixedChoices.freshSearchAfter` (4 hours).
    private static let longAway = ["-PlainAwayOffset", "18000"]

    private func launch(_ arguments: [String]) throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication.introSeen()
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func address(_ path: String) -> String {
        "http://" + server.address(path)
    }

    private func waitForPage(_ app: XCUIApplication, _ heading: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show",
                      file: file, line: line)
    }

    private func type(_ app: XCUIApplication, _ path: String) {
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if !field.hasKeyboardFocus { app.buttons["addressPill"].tap() }
        field.typeText(server.address(path) + "\n")
    }

    /// Opens the strong-colored page in a fresh test store, leaves the app (which remembers the
    /// page and its picture) and ends it.
    private func leaveWithLaunchPage() throws {
        let app = try launch(["-PlainTestStore", "-PlainResetStore"])
        type(app, "/a")
        waitForPage(app, "Page A")
        app.buttons["tabs"].press(forDuration: 1)
        let newTab = app.buttons["menu.newTab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 3))
        newTab.tap()
        type(app, "/launch")
        waitForPage(app, "Launch Page")
        keep(XCUIScreen.main.screenshot(), "left on")
        XCUIApplication.leaveForAnotherApp()
        // The picture has up to 2 s to come back, then is encoded and written.
        Thread.sleep(forTimeInterval: 3)
        app.terminate()
    }

    /// The screenshot's color a tenth of the way down at a third of the width, where the page
    /// shows and no chrome sits (above the open search sheet, clear of the status items).
    private func pageColor(_ screenshot: XCUIScreenshot) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        guard let image = screenshot.image.cgImage,
              let pixel = image.cropping(to: CGRect(x: image.width / 3, y: image.height / 10, width: 1, height: 1)) else {
            return (0, 0, 0)
        }
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (CGFloat(rgba[0]) / 255, CGFloat(rgba[1]) / 255, CGFloat(rgba[2]) / 255)
    }

    private func keep(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRelaunchWithTabsShowsTheLastTabOnTheFirstScreen() throws {
        try leaveWithLaunchPage()
        let app = try launch(["-PlainTestStore"])
        // The first screen after launch returns: the page (blue), never bare paper.
        let first = XCUIScreen.main.screenshot()
        keep(first, "first screen")
        let color = pageColor(first)
        XCTAssertTrue(color.blue > 0.8 && color.red < 0.4, "the first screen shows the last tab's page, not paper: \(color)")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the last tab opens with the bar resting, no keyboard")
        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 2))
        XCTAssertEqual(pill.value as? String, address("/launch"))
        // The live page takes over, still with no keyboard, and the other tab is a swipe away.
        waitForPage(app, "Launch Page")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        pill.swipeRight(velocity: .fast)
        waitForPage(app, "Page A")
        keep(XCUIScreen.main.screenshot(), "live page")
    }

    func testRelaunchWithNoTabsOpensSearch() throws {
        var app = try launch(["-PlainTestStore", "-PlainResetStore"])
        type(app, "/a")
        waitForPage(app, "Page A")
        app.buttons["tabs"].press(forDuration: 1)
        let close = app.buttons["menu.closeTab"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCUIApplication.leaveForAnotherApp()
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        app = try launch(["-PlainTestStore"])
        keep(XCUIScreen.main.screenshot(), "first screen")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no tab: search with the keyboard up")
        XCTAssertTrue(field.hasKeyboardFocus)
    }

    func testLongAwayOpensSearchOverTheLastTab() throws {
        try leaveWithLaunchPage()
        let app = try launch(["-PlainTestStore"] + Self.longAway)
        let first = XCUIScreen.main.screenshot()
        keep(first, "first screen")
        // The page shows above the sheet: dimmed, but clearly blue.
        let color = pageColor(first)
        XCTAssertTrue(color.blue > color.red + 0.1, "the last tab shows behind the search: \(color)")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "a fresh search, keyboard up")
        XCTAssertTrue(field.hasKeyboardFocus)
        XCTAssertFalse((field.value as? String ?? "").contains("/launch"), "the fresh search starts empty")

        // A swipe down goes back to the tab, as it was.
        Thread.sleep(forTimeInterval: 1)
        app.otherElements["searchCard"].swipeDown()
        let gone = NSPredicate { _, _ in !app.keyboards.firstMatch.exists }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 3), .completed)
        waitForPage(app, "Launch Page")
        XCTAssertEqual(app.buttons["addressPill"].value as? String, address("/launch"))
        keep(XCUIScreen.main.screenshot(), "back on the tab")
    }

    func testReturnAfterALongTimeOpensAFreshSearchThatOpensANewTab() throws {
        let app = try launch(["-PlainTestStore", "-PlainResetStore"] + Self.longAway)
        type(app, "/launch")
        waitForPage(app, "Launch Page")
        XCUIApplication.leaveForAnotherApp()
        Thread.sleep(forTimeInterval: 1)
        app.activate()

        let field = app.textFields["searchField"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "back after a long time: a fresh search")
        XCTAssertTrue(field.hasKeyboardFocus)
        keep(XCUIScreen.main.screenshot(), "fresh search on return")
        // A search from it opens a new tab; the page the user came back to stays.
        field.typeText(server.address("/c") + "\n")
        waitForPage(app, "Page C")
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 3))
        XCTAssertEqual(tabs.value as? String, "2 tabs")
    }

    func testReturnAfterAShortTimeChangesNothing() throws {
        let app = try launch(["-PlainTestStore", "-PlainResetStore"])
        type(app, "/launch")
        waitForPage(app, "Launch Page")
        XCUIApplication.leaveForAnotherApp()
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        waitForPage(app, "Launch Page")
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1), "a short break comes back to the page as it was")
    }
}
