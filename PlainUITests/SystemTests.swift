import XCTest

/// The way in from the system: the `plainbrowser:` links widgets use (the same commands App
/// Intents send, docs/research/system-integration.md), opened by iOS while Plain runs and on a
/// cold launch. The intents themselves are performed in PlainTests.
@MainActor
final class SystemTests: XCTestCase {
    private var server: TestServer!

    override func setUp() async throws {
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
    }

    override func tearDown() async throws {
        server.stop()
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainInMemoryStore"]
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        return app
    }

    private func link(_ path: String, _ query: [String: String] = [:]) -> URL {
        var components = URLComponents(string: "plainbrowser://\(path)")!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }

    /// Opens `url` as iOS would for a widget. A link opened from outside an app asks "Open in
    /// Plain?" first (a widget tap does not), so the test answers Open.
    /// `XCUIApplication.open` relaunches the app; the system's open reaches the running one, as a
    /// widget tap does. `cold` uses the first, for a launch from a link.
    private func open(_ app: XCUIApplication, _ url: URL, cold: Bool = false) {
        if cold { app.open(url) } else { XCUIDevice.shared.system.open(url) }
        let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
    }

    func testAWidgetFavoriteOpensItsPage() {
        let app = launch()
        open(app, link("open", ["url": "http://" + server.address("/a")]))
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
    }

    func testAColdLaunchFromALinkOpensThePage() {
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainInMemoryStore"]
        open(app, link("open", ["url": "http://" + server.address("/b")]), cold: true)
        XCTAssertTrue(app.webViews.staticTexts["Page B"].waitForExistence(timeout: 15))
    }

    func testTheSearchWidgetFocusesANewTabsField() {
        let app = launch()
        let field = app.textFields["searchField"]
        field.typeText(server.address("/a") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
        open(app, link("search"))
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { field.hasKeyboardFocus }, "the search field takes focus")
        XCTAssertEqual(field.value as? String ?? "", field.placeholderValue ?? "", "a new tab's field is empty")
    }

    func testThePrivateTabControlOpensAPrivateTab() {
        let app = launch()
        let pill = app.descendants(matching: .any)["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertNotEqual(pill.label, "Private Address")
        open(app, link("private-tab"))
        XCTAssertTrue(waitFor { pill.label == "Private Address" }, "the pill says private, not \(pill.label)")
    }

    func testShowTabsOpensTheGallery() {
        let app = launch()
        let field = app.textFields["searchField"]
        field.typeText(server.address("/a") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
        open(app, link("tabs"))
        XCTAssertTrue(app.scrollViews["tabGallery"].waitForExistence(timeout: 5))
    }

    /// Siri's Show Tabs launching Plain cold: the switcher waits for the saved tabs, then opens.
    func testShowTabsOnAColdLaunchWaitsForTheSavedTabs() {
        var app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainTestStore", "-PlainResetStore"]
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/a") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
        // Leaving the app writes the tab list.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainTestStore"]
        open(app, link("tabs"), cold: true)
        XCTAssertTrue(app.scrollViews["tabGallery"].waitForExistence(timeout: 10))
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
