import XCTest

/// Sign-in on web pages (docs/research/sign-in.md): a login field brings up the keyboard (with
/// the AutoFill passwords button once Apple grants the web-browser entitlement), and a passkey
/// request Plain can't serve yet says why in a toast. Pages come from the local TestServer.
@MainActor
final class SignInTests: XCTestCase {
    private var server: TestServer!

    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["-PlainInMemoryStore"]
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        return app
    }

    private func go(_ app: XCUIApplication, to path: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The keyboard comes up for a login field with the page's own form bar: nothing of Plain's
    /// replaces or hides it. The suggestion bar's AutoFill button ("Passwords") is the system's
    /// call: on iOS 27.2 it shows for a native username field and in Safari, but not for a web
    /// field in an app without the web-browser entitlement (measured with a bare `WKWebView`,
    /// docs/research/sign-in.md). Until the entitlement lands this test skips at that check.
    func testLoginFieldBringsUpTheKeyboard() throws {
        let app = try launch()
        go(app, to: "/login")
        // The username field, not the password one: iOS blanks the keyboard in screenshots while a
        // secure field is focused.
        let user = app.webViews.textFields.firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        user.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard came up")
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 2), "the page's form bar is there")
        let autoFill = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'password'")).firstMatch
        let shown = autoFill.waitForExistence(timeout: 3)
        attachScreenshot("login-keyboard")
        if !shown {
            throw XCTSkip("No AutoFill button for web fields without the web-browser entitlement")
        }
    }

    func testPasskeyRequestSaysWhyItFailed() throws {
        let app = try launch()
        go(app, to: "/passkey")
        let button = app.webViews.buttons["Sign In with a Passkey"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        // The toast first: it lives a few seconds, and reading a page's text through
        // accessibility can take about as long.
        let toastText = app.staticTexts["Passkeys will work once Apple approves Plain"]
        XCTAssertTrue(toastText.waitForExistence(timeout: 3))
        attachScreenshot("passkey-toast")
        // The page still gets WebKit's refusal, so its own password sign-in can take over.
        XCTAssertTrue(app.webViews.staticTexts["Passkey NotAllowedError"].waitForExistence(timeout: 10))
        // Once per site per launch: a second try stays quiet.
        XCTAssertTrue(toastText.waitForNonExistence(timeout: 10))
        button.tap()
        XCTAssertFalse(toastText.waitForExistence(timeout: 2))
    }
}
