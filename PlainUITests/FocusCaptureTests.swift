import XCTest

/// Screenshots of the focused address bar (docs/research/address-focus.md), for design review:
/// the start screen, a loaded page, typing, and the page sheet. Not a test of behavior: it skips
/// itself unless `PLAIN_CAPTURE=1` reaches the runner (`TEST_RUNNER_PLAIN_CAPTURE=1`).
/// `PLAIN_CAPTURE_FAVORITES=1` seeds favorites and `PLAIN_CAPTURE_HISTORY=1` a few visited pages;
/// `PLAIN_CAPTURE_TAG` names the shots (for example `17-dark`).
@MainActor
final class FocusCaptureTests: XCTestCase {
    private var tag = ""

    func testCaptureAddressFocus() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        tag = environment["PLAIN_CAPTURE_TAG"] ?? "shot"
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        if environment["PLAIN_CAPTURE_FAVORITES"] == "1" { app.launchArguments += ["-PlainSeedFavorites"] }
        if environment["PLAIN_CAPTURE_HISTORY"] == "1" { app.launchArguments += ["-PlainSeedHistory"] }
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        pause(2)
        shot("1-start-focus")

        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 15))
        pause(2)
        shot("2-page")

        app.buttons["addressPill"].tap()
        pause(0.05)
        shot("3-page-focus-first-frames")
        pause(1.2)
        shot("4-page-focus")

        field.typeText("pla")
        pause(1.5)
        shot("5-page-typing")

        // Close the search, then open the page sheet from More, where it exists.
        app.swipeDown(velocity: .fast)
        pause(1.2)
        let more = app.buttons["more"]
        if more.exists, more.isHittable {
            more.tap()
            pause(1.2)
            shot("6-page-sheet")
            let host = app.buttons["pageSheet.address"]
            if host.waitForExistence(timeout: 2) {
                host.tap()
                pause(1.2)
                shot("7-edit-address")
            }
        }
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(tag)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
