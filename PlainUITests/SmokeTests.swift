import XCTest

/// The app launches into a focused search field, and a submitted address opens a page.
@MainActor
final class SmokeTests: XCTestCase {
    func testLaunchFocusesSearchField() {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard is not up at launch")
        XCTAssertTrue(field.hasKeyboardFocus, "search field is not first responder at launch")
    }

    func testSubmittingAnAddressOpensAWebView() {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("example.com\n")

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "no web view after submit")
        XCTAssertEqual(field.value as? String, "https://example.com")
        XCTAssertFalse(field.hasKeyboardFocus, "field should give up focus after submit")
    }
}

@MainActor
extension XCUIElement {
    var hasKeyboardFocus: Bool {
        (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }
}
