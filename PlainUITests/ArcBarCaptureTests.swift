import XCTest

/// Drives the address bar's expand and dismiss at a steady pace while the screen is recorded
/// (`simctl io recordVideo`), for frame strips beside Arc Search's (docs/research/
/// arc-address-expand.md). Not a test of behavior: it skips itself unless `PLAIN_CAPTURE=1`
/// reaches the runner (`TEST_RUNNER_PLAIN_CAPTURE=1`). `PLAIN_CAPTURE_URL` picks the page
/// (default: the local long page).
@MainActor
final class ArcBarCaptureTests: XCTestCase {
    func testCaptureExpandAndDismiss() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        if let corner = environment["PLAIN_CAPTURE_CORNER"] { app.launchArguments += ["-PlainStatusCorner", corner] }
        app.launchArguments += ["-PlainSeedFavorites", "-PlainSeedHistory"]
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let address = environment["PLAIN_CAPTURE_URL"] ?? server.address("/long")
        field.typeText(address + "\n")
        pause(5)
        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))

        // 1. Tap, rest, type, then the handle.
        mark("open-1")
        pill.tap()
        pause(2)
        field.typeText("pla")
        pause(1.5)
        mark("close-handle")
        let handle = app.buttons["search.close"]
        (handle.exists ? handle : app.buttons["search.cancel"]).tap()
        pause(2)

        // 2. Tap, rest, then a tap on the page above the sheet.
        mark("open-2")
        pill.tap()
        pause(2)
        mark("close-page")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.06)).tap()
        pause(2)

        // 3. Tap, then a short drag that springs back, then a swipe down from the field.
        mark("open-3")
        pill.tap()
        pause(2)
        let top = field.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        mark("drag-back")
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 60)), withVelocity: 200, thenHoldForDuration: 0.2)
        pause(2)
        mark("close-swipe")
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 300)), withVelocity: 700, thenHoldForDuration: 0)
        pause(2)
    }

    /// Seconds since the test began, printed for cutting the recording.
    private let began = Date()
    private func mark(_ name: String) {
        print("MARK \(name) \(String(format: "%.2f", Date().timeIntervalSince(began)))")
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
