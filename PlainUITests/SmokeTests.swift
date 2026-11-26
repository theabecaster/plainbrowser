import XCTest

/// The app launches into a focused search field, and a submitted address opens a page.
@MainActor
final class SmokeTests: XCTestCase {
    func testLaunchFocusesSearchField() {
        let app = XCUIApplication.introSeen()
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard is not up at launch")
        XCTAssertTrue(field.hasKeyboardFocus, "search field is not first responder at launch")
    }

    func testSubmittingAnAddressOpensAWebView() {
        let app = XCUIApplication.introSeen()
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("example.com\n")

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "no web view after submit")
        // After submit the field rests as the URL pill, which carries the full address.
        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue((pill.value as? String)?.hasPrefix("https://example.com") ?? false)
        XCTAssertFalse(field.exists && field.hasKeyboardFocus, "field should give up focus after submit")
    }
}

@MainActor
extension XCUIApplication {
    /// The app as a returning user launches it: the first-run intro already seen. The argument
    /// sets the same user default the intro writes (argument domain), in Release builds too.
    static func introSeen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PlainIntroSeen", "YES"]
        return app
    }
}

@MainActor
extension XCUIElement {
    var hasKeyboardFocus: Bool {
        (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }
}
