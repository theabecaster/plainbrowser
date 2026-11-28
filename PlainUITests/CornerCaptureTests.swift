import XCTest

/// Holds each floating-chrome state still while the script outside takes the screen with the
/// display's physical corners on it (`xcrun simctl io <udid> screenshot --mask=black`): a
/// screenshot otherwise shows square corners, so chrome the real screen cuts looks fine there
/// (docs/ui-reference.md, "Corners"). Not a test of behavior: it skips unless `PLAIN_CAPTURE=1`
/// and `PLAIN_CORNER_DIR` (a folder on the Mac) reach the runner. At each state it writes
/// `<dir>/<n>-<name>.ready` and waits for `<dir>/<n>-<name>.done`. `PLAIN_CORNER_FLOW` picks the
/// states: `phone` (portrait, then landscape), `duo-outer`, `duo-inner`.
@MainActor
final class CornerCaptureTests: XCTestCase {
    private var server: TestServer!
    private var directory: URL!
    private var step = 0

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let path = try XCTUnwrap(environment["PLAIN_CORNER_DIR"], "PLAIN_CORNER_DIR: where the handshake files go")
        directory = URL(fileURLWithPath: path)
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// One state, held until the script has taken it (at most 30 s).
    private func hold(_ name: String) {
        pause(1.2)
        step += 1
        let base = String(format: "%02d-%@", step, name)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("\(base).ready").path, contents: nil)
        let done = directory.appendingPathComponent("\(base).done").path
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: done), Date() < deadline { pause(0.2) }
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore"] + arguments
        app.launch()
        XCTAssertTrue(app.waitForFirstScreen(timeout: 10))
        return app
    }

    private func go(_ app: XCUIApplication, _ path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 3))
        }
        field.typeText(server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10))
    }

    /// Start, a page, reading (the bar collapsed), the search sheet, a toast and the switcher.
    private func pageStates(_ app: XCUIApplication, prefix: String, toast: Bool) {
        hold("\(prefix)start")
        go(app, "/launch", heading: "Launch Page")
        hold("\(prefix)page")
        go(app, "/long", heading: "Long Read")
        app.webViews.firstMatch.swipeUp(velocity: 400)
        hold("\(prefix)reading")
        app.webViews.firstMatch.swipeDown(velocity: 300)
        pause(0.8)
        app.buttons["addressPill"].tap()
        hold("\(prefix)search")
        let field = app.textFields["searchField"]
        field.typeText(server.address("/files") + "\n")
        if toast, app.webViews.links["Download notes"].waitForExistence(timeout: 10) {
            app.webViews.links["Download notes"].tap()
            pause(0.4)
            hold("\(prefix)toast")
            pause(3)
        }
        if app.buttons["tabs"].waitForExistence(timeout: 3) {
            app.buttons["tabs"].tap()
            hold("\(prefix)switcher")
            if app.buttons["galleryDone"].waitForExistence(timeout: 2) { app.buttons["galleryDone"].tap() }
            pause(1)
        }
    }

    func testCaptureCorners() {
        let flow = ProcessInfo.processInfo.environment["PLAIN_CORNER_FLOW"] ?? "phone"
        switch flow {
        case "duo-inner":
            let pages = ["/launch", "/a", "/long"].map { "http://" + server.address($0) }.joined(separator: ",")
            var app = launch()
            pageStates(app, prefix: "", toast: true)
            app.terminate()
            app = launch(["-PlainOpen", pages])
            pause(4)
            hold("strip")
            app.terminate()
            app = launch(["-PlainOpen", pages, "-PlainSplit"])
            pause(4)
            hold("split")
            app.terminate()
            app = launch(["-PlainOpen", pages, "-PlainTabLayout", "left", "-PlainSidebar", "expanded"])
            pause(4)
            hold("sidebar")
            app.terminate()
            app = launch(["-PlainOpen", pages, "-PlainTabLayout", "left", "-PlainSidebar", "rail"])
            pause(4)
            hold("rail")
            app.terminate()
            app = launch(["-PlainOpen", pages, "-PlainSidePane", "history"])
            pause(6)
            hold("sidepane")
        case "duo-outer":
            let app = launch()
            pageStates(app, prefix: "", toast: true)
            let pages = ["/launch", "/a"].map { "http://" + server.address($0) }.joined(separator: ",")
            app.terminate()
            let privateApp = launch(["-PlainOpen", pages, "-PlainOpenPrivate", "http://" + server.address("/launch")])
            pause(4)
            hold("private")
            privateApp.terminate()
        default:
            let app = launch()
            pageStates(app, prefix: "", toast: true)
            go(app, "/launch", heading: "Launch Page")
            XCUIDevice.shared.orientation = .landscapeLeft
            pause(2)
            hold("land-page")
            go(app, "/long", heading: "Long Read")
            app.webViews.firstMatch.swipeUp(velocity: 400)
            hold("land-reading")
            app.webViews.firstMatch.swipeDown(velocity: 300)
            pause(0.8)
            app.buttons["addressPill"].tap()
            hold("land-search")
        }
    }
}
