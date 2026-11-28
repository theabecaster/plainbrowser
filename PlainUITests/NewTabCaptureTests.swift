import XCTest

/// Screenshots of the quick ways to a new tab (docs/research/new-tab.md), for design review: the
/// bar with New Tab on a page, its long-press menu, a strip of frames right after the tap, the new
/// tab's field, the start screen with no "+", two tabs (the inner screen's strip without a "+" of
/// its own), and a stray "+" closed untouched going back to the page. Not a test of behavior: it
/// skips unless `PLAIN_CAPTURE=1` reaches the runner.
@MainActor
final class NewTabCaptureTests: XCTestCase {
    private var tag = ""

    func testCaptureNewTab() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        tag = environment["PLAIN_CAPTURE_TAG"] ?? "shot"
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore"]
        app.launch()
        XCTAssertTrue(app.waitForFirstScreen())

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // The start screen, field closed: no "+" (already a new tab).
        closeSheet(app)
        pause(1.2)
        shot("nt-0-start-no-plus")
        app.buttons["addressPill"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].firstMatch.waitForExistence(timeout: 15))
        pause(1.5)
        shot("nt-1-page-bar")

        let plus = app.buttons["newTab"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 2))
        plus.press(forDuration: 1)
        pause(0.8)
        shot("nt-2-plus-menu")
        // Close the menu without choosing.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        pause(0.8)

        // The tap, and the frames right after it, as fast as the runner takes them.
        plus.tap()
        for frame in 1...6 { shot("nt-3-after-tap-\(frame)") }
        pause(1)
        shot("nt-4-new-tab-field")

        field.typeText(server.address("/a") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page A"].firstMatch.waitForExistence(timeout: 10))
        pause(1.5)
        shot("nt-5-two-tabs")

        // A stray "+": the field closed untouched goes back to the page, with frames of the way.
        plus.tap()
        pause(1)
        closeSheet(app)
        for frame in 1...4 { shot("nt-6-cancel-\(frame)") }
        pause(1.5)
        shot("nt-7-back-on-page")
    }

    /// Closes the search sheet by hand, as a person would on any screen: its grabber, or Cancel
    /// where the field sits in the top bar (the Duo's inner screen).
    private func closeSheet(_ app: XCUIApplication) {
        let grabber = app.buttons["search.close"]
        let cancel = app.buttons["search.cancel"]
        if grabber.exists, grabber.isHittable {
            grabber.tap()
        } else if cancel.exists, cancel.isHittable {
            cancel.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Every screen that shows something (the Duo's inner screen when it is open), named by size.
    private func shot(_ name: String) {
        for screen in XCUIScreen.screens {
            let image = screen.screenshot()
            let size = image.image.size
            let suffix = XCUIScreen.screens.count > 1 ? "-\(Int(size.width))x\(Int(size.height))" : ""
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = "\(tag)-\(name)\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
