import XCTest

/// The suggestion list while typing: rows stay put and tappable as each keystroke updates them.
@MainActor
final class SuggestionTests: XCTestCase {
    /// Typing fast never leaves a visible row mid-flight or untappable, and the right row is
    /// there to tap at the end.
    func testRowsStayHittableWhileTypingFast() throws {
        continueAfterFailure = false
        let server = try TestServer()
        try server.start()
        addTeardownBlock { server.stop() }
        let app = XCUIApplication.isolated()
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        for (path, heading) in [("/a", "Page A"), ("/b", "Page B"), ("/c", "Page C")] {
            if !(field.exists && field.hasKeyboardFocus) { app.buttons["addressPill"].tap() }
            field.typeText(server.address(path) + "\n")
            XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10))
        }
        // History is written in batches (FixedChoices.historyFlushInterval, 2 s).
        Thread.sleep(forTimeInterval: 2.5)

        app.buttons["addressPill"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion.'"))
        for letter in "Plain Test" {
            field.typeText(String(letter))
            for index in 0..<rows.count {
                let row = rows.element(boundBy: index)
                guard row.exists, !row.frame.isEmpty else { continue }
                XCTAssertTrue(row.isHittable, "row \(row.identifier) is not hittable after typing \"\(letter)\"")
            }
        }
        let row = app.buttons["Plain Test A"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "history suggestion for page A did not show")
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
    }

    /// Types "github" letter by letter with pauses, for a screen recording of the list
    /// (`xcrun simctl io <udid> recordVideo`). Not a test of behavior: it needs the network and
    /// runs only when `PLAIN_CAPTURE=1` reaches the runner (`TEST_RUNNER_PLAIN_CAPTURE=1`).
    func testCaptureTypingGithub() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let app = XCUIApplication.isolated()
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // History to match: the site and a page on it.
        for address in ["github.com", "github.com/features", "docs.github.com"] {
            if !(field.exists && field.hasKeyboardFocus) { app.buttons["addressPill"].tap() }
            field.typeText(address + "\n")
            Thread.sleep(forTimeInterval: 4)
        }
        Thread.sleep(forTimeInterval: 2.5)

        // Twice: once cold, once with the engine's answers cached.
        for _ in 0..<2 {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
            Thread.sleep(forTimeInterval: 1.5)
            for letter in "github" {
                field.typeText(String(letter))
                Thread.sleep(forTimeInterval: 0.15)
            }
            Thread.sleep(forTimeInterval: 2)
            field.buttons.firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.5)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
