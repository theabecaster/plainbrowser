import XCTest

/// The launch splash (docs/state-rules.md, "Launch splash"): a cold launch shows the chosen icon's
/// world and dives through the P into the app, which is whole and takes touches underneath.
/// An isolated run plays it only with `-PlainSplash`. When it has ended, the app's window carries
/// an element (`plainLaunchSplash`) whose value says how: "metal" (the GPU dive), "iris" (Core
/// Animation), "crossfade" (Reduce Motion), "skipped" (a touch, a link) or "left".
@MainActor
final class LaunchSplashTests: XCTestCase {
    private var server: TestServer!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = [], splash: Bool = true) -> XCUIApplication {
        let app = XCUIApplication.introSeen()
        app.launchArguments += (splash ? ["-PlainSplash"] : []) + arguments
        app.launch()
        return app
    }

    /// How the splash ended, once it has.
    private func ending(_ app: XCUIApplication, within timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> String {
        let report = app.descendants(matching: .any).matching(identifier: "plainLaunchSplash").firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: timeout), "the splash did not end", file: file, line: line)
        let value = report.value as? String ?? ""
        let note = XCTAttachment(string: value)
        note.name = "splash report"
        note.lifetime = .keepAlways
        add(note)
        return value
    }

    private func keep(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A pixel of the screenshot, at a place given in fractions of its size.
    private func color(_ screenshot: XCUIScreenshot, x: CGFloat, y: CGFloat) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        guard let image = screenshot.image.cgImage,
              let pixel = image.cropping(to: CGRect(x: CGFloat(image.width) * x, y: CGFloat(image.height) * y, width: 1, height: 1)) else {
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

    // MARK: The dive

    /// No tab: the dive ends on the focused search field with the keyboard up.
    func testColdLaunchWithNoTabsDivesIntoSearch() {
        let app = launch()
        let how = ending(app)
        XCTAssertTrue(how.hasPrefix("metal") || how.hasPrefix("iris"), "the dive did not run to its end: \(how)")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no tab: search with the keyboard up")
        XCTAssertTrue(field.hasKeyboardFocus)
        keep(XCUIScreen.main.screenshot(), "after the dive")
    }

    /// A last tab: the dive opens onto its page, the bar resting.
    func testColdLaunchWithTabsDivesIntoTheLastTab() throws {
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        var app = launch(["-PlainTestStore", "-PlainResetStore"], splash: false)
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/launch") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Launch Page"].waitForExistence(timeout: 10))
        XCUIApplication.leaveForAnotherApp()
        Thread.sleep(forTimeInterval: 3)
        app.terminate()

        app = launch(["-PlainTestStore"])
        let how = ending(app)
        XCTAssertTrue(how.hasPrefix("metal") || how.hasPrefix("iris"), "the dive did not run to its end: \(how)")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the last tab opens with the bar resting, no keyboard")
        XCTAssertEqual(app.buttons["addressPill"].value as? String, "http://" + server.address("/launch"))
        XCTAssertTrue(app.webViews.staticTexts["Launch Page"].waitForExistence(timeout: 10))
        keep(XCUIScreen.main.screenshot(), "after the dive")
    }

    #if DEBUG
    /// Each icon's world, held on screen: its field at the screen's edge, and the same mark in
    /// the middle of every one.
    func testTheSplashIsTheChosenIconsWorld() {
        // The field a quarter down the left edge: Dawn's lagoon, Night's deep blue, Coral, Paper.
        let fields: [(String, (CGFloat, CGFloat, CGFloat) -> Bool)] = [
            ("Dawn", { r, g, b in g > 0.6 && b > 0.6 && r < 0.75 }),
            ("Night", { r, g, b in r < 0.3 && g < 0.4 && b < 0.6 }),
            ("Coral", { r, g, b in r > 0.85 && g > 0.35 && g < 0.85 && b < 0.8 }),
            ("Paper", { r, g, b in r > 0.9 && g > 0.85 && b > 0.75 }),
        ]
        for (icon, matches) in fields {
            let app = launch(["-PlainSplashIcon", icon, "-PlainSplashHold", "10"])
            // The system's fade from the launch screen takes a moment (longer on a loaded simulator).
            var shot = XCUIScreen.main.screenshot()
            var field = color(shot, x: 0.04, y: 0.25)
            let deadline = Date().addingTimeInterval(6)
            while !matches(field.red, field.green, field.blue), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.3)
                shot = XCUIScreen.main.screenshot()
                field = color(shot, x: 0.04, y: 0.25)
            }
            Thread.sleep(forTimeInterval: 0.4)
            shot = XCUIScreen.main.screenshot()
            field = color(shot, x: 0.04, y: 0.25)
            keep(shot, "splash \(icon)")
            XCTAssertTrue(matches(field.red, field.green, field.blue), "\(icon)'s field: \(field)")
            // The app is whole underneath: the search field is there while the splash is up.
            XCTAssertTrue(app.textFields["searchField"].exists, "\(icon): the app is not under the splash")
            app.terminate()
        }
    }

    /// Core Animation's iris, when the GPU dive isn't ready in time.
    func testTheIrisPlaysWithoutTheRenderer() {
        let app = launch(["-PlainSplashPath", "iris"])
        XCTAssertTrue(ending(app).hasPrefix("iris"))
        XCTAssertTrue(app.textFields["searchField"].hasKeyboardFocus)
    }

    /// A touch ends the splash at once and does nothing to the app underneath.
    func testATouchEndsItAndLeavesTheAppAsItWas() {
        let app = launch(["-PlainSplashHold", "20"])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "plainLaunchSplash").firstMatch.exists, "the splash ended by itself")
        // The field has focus under the splash; its keyboard waits for the splash to open.
        XCTAssertTrue(app.textFields["searchField"].hasKeyboardFocus)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard lies over the splash")
        // A tap ends the splash and is not passed on: in the middle of the screen it would fall
        // on the search sheet's empty space, which closes the search.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(ending(app, within: 2).hasPrefix("skipped"))
        XCTAssertTrue(app.textFields["searchField"].hasKeyboardFocus, "the tap that ended the splash acted on the app")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard did not come once the splash ended")
    }

    /// The first run: the dive opens onto the intro.
    func testTheIntroComesAfterTheSplash() {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainShowIntro", "-PlainSplash"]
        app.launch()
        let how = ending(app)
        XCTAssertTrue(how.hasPrefix("metal") || how.hasPrefix("iris"), how)
        XCTAssertTrue(app.buttons["introSkip"].waitForExistence(timeout: 5), "the intro is not under the splash")
    }
    #endif

    // MARK: When there is none

    /// An isolated run without `-PlainSplash`, and a launch from a link, have no splash.
    func testNoSplashUnlessAskedFor() {
        let app = launch(splash: false)
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "plainLaunchSplash").firstMatch.waitForExistence(timeout: 2))
    }
}
