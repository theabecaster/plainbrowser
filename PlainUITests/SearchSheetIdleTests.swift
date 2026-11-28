import XCTest

/// The search sheet left open costs nothing: with nothing changing, the app goes idle at once,
/// on every screen (the Duo's inner screen, regular width, included). XCUITest waits for the app
/// to idle before each action (up to 60 s, then "App animations complete notification not
/// received"), so an action's whole time bounds that wait. Measured 0.4 to 1.4 s per action on a
/// test Mac (2026-11-28); the budget leaves room for a loaded Mac and still catches the 60 s wait.
@MainActor
final class SearchSheetIdleTests: XCTestCase {
    /// How long one action may take, its wait for idle included.
    private let idleBudget: TimeInterval = 15

    private func timed(_ what: String, _ action: () -> Void) -> TimeInterval {
        let start = Date()
        action()
        let elapsed = Date().timeIntervalSince(start)
        print("idle step \(what): \(String(format: "%.2f", elapsed)) s")
        return elapsed
    }

    func testTheOpenSheetLetsTheAppIdle() throws {
        continueAfterFailure = false
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        let width = app.windows.firstMatch.frame.width
        print("idle window width: \(width)")

        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3))
        // Closed: the tap waits for the page at rest.
        let closed = timed("tap the pill (sheet closed)") { pill.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Open and still for a moment: each keystroke waits for the app to idle first.
        Thread.sleep(forTimeInterval: 1.5)
        let open1 = timed("type with the sheet open") { field.typeText("p") }
        Thread.sleep(forTimeInterval: 1.5)
        let open2 = timed("type again with the sheet open") { field.typeText("l") }
        XCTAssertLessThan(closed, idleBudget, "the app idles with the sheet closed")
        XCTAssertLessThan(open1, idleBudget, "the app idles with the search sheet open")
        XCTAssertLessThan(open2, idleBudget, "the app idles with the search sheet open")
    }
}
