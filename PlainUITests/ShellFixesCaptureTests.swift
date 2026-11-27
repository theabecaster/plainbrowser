import XCTest

/// Captures for the UX-audit shell fixes (docs/research/ux-audit.md): the chrome over body text,
/// the one-row bar in compact height, Back to the opener, and the link preview. Not a test of
/// behavior: it skips unless `PLAIN_CAPTURE=1` reaches the runner, and attaches screenshots
/// (`xcrun xcresulttool export attachments`). Record the screen alongside for the motion, and
/// take landscape frames with `simctl io screenshot` (XCUITest's own are cut off there); each
/// landscape state holds for 3 s. Run it again under `simctl ui <udid> appearance dark`.
@MainActor
final class ShellFixesCaptureTests: XCTestCase {
    private var server: TestServer!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore"]
        app.launch()
        XCTAssertTrue(app.waitForFirstScreen())
        return app
    }

    private func go(_ app: XCUIApplication, _ path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10))
    }

    /// The whole screen as the user sees it, in any orientation (the app's own screenshot comes
    /// out rotated and cut off in landscape).
    private func screen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Every fix on whatever screen this runs on, portrait and then landscape, for the per-device
    /// check (smallest iPhone, Pro Max, the Duo's outer and inner screens).
    func testCaptureEveryFix() {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainShowIntro"]
        app.launch()
        // 8. The intro's inside step (the unfold row only on a foldable's window).
        let next = app.buttons["introNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        next.tap()
        XCTAssertTrue(app.staticTexts["Private Tabs"].waitForExistence(timeout: 5))
        pause(1.5)
        screen("all-8a-intro")
        app.buttons["introSkip"].tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        pause(0.8)
        // 8. The empty private tab's "Regular Tab".
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        if app.buttons["start.privateTab"].waitForExistence(timeout: 3) {
            app.buttons["start.privateTab"].tap()
            pause(0.8)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            XCTAssertTrue(app.buttons["start.regularTab"].waitForExistence(timeout: 3))
            pause(1)
            screen("all-8b-private-start")
            app.buttons["start.regularTab"].tap()
            pause(0.8)
        }
        // 1. The glass over body text.
        go(app, "/long", heading: "Long Read")
        let webView = app.webViews.firstMatch
        webView.swipeUp(velocity: .slow)
        webView.swipeDown(velocity: 300)
        pause(1.2)
        screen("all-1-glass")
        // 3. Back to the opener (before and after; the motion is in the screen recording).
        go(app, "/opener", heading: "Opener Page")
        app.webViews.links["Open B in a new tab"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Page B"].waitForExistence(timeout: 10))
        pause(1)
        app.buttons["back"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Opener Page"].waitForExistence(timeout: 5))
        pause(0.8)
        screen("all-3-back-opener")
        // 6. A refused connection.
        let closed = try? TestServer()
        try? closed?.start()
        let port = closed?.port ?? 1
        closed?.stop()
        app.buttons["addressPill"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText("http://127.0.0.1:\(port)/nothing\n")
        XCTAssertTrue(app.staticTexts["The site isn't answering."].waitForExistence(timeout: 6))
        pause(0.8)
        screen("all-6-refused")
        // 7. An empty sheet.
        app.buttons["more"].tap()
        let favorites = app.buttons["menu.editFavorites"]
        if favorites.waitForExistence(timeout: 3) {
            favorites.tap()
            pause(1.2)
            screen("all-7-favorites-empty")
            if app.buttons["Done"].waitForExistence(timeout: 2) { app.buttons["Done"].tap() }
            pause(1)
        }
        // 2. Landscape: the page, while reading, the link preview.
        go(app, "/long", heading: "Long Read")
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(2.5)
        screen("all-2a-landscape-page")
        webView.swipeUp(velocity: 200)
        pause(1.5)
        screen("all-2b-landscape-reading")
        webView.swipeDown(velocity: 300)
        pause(1.5)
        go(app, "/opener", heading: "Opener Page")
        pause(1)
        screen("all-2c-landscape-opener")
        // 4. The link preview and its whole menu, beside it here; last, since a live preview
        // keeps the app from idling for a minute after it closes.
        app.webViews.links["Read the long page"].press(forDuration: 1.2)
        if app.buttons["linkMenu.downloadLinkedFile"].waitForExistence(timeout: 5) {
            pause(1.2)
            screen("all-4b-landscape-preview")
        }
    }

    /// The pill and the buttons over body text, light and dark, at rest and as the pill.
    func testCaptureChromeOverText() {
        let app = launch()
        go(app, "/long", heading: "Long Read")
        let webView = app.webViews.firstMatch
        webView.swipeUp(velocity: .slow)
        webView.swipeDown(velocity: 300)
        pause(1.2)
        shot("glass-1", app)
        // A private tab's tint.
        app.buttons["more"].tap()
        let privateTab = app.buttons["more.newPrivateTab"]
        if privateTab.waitForExistence(timeout: 2) {
            privateTab.tap()
            go(app, "/long", heading: "Long Read")
            webView.swipeUp(velocity: .slow)
            webView.swipeDown(velocity: 300)
            pause(1.2)
            shot("glass-3-private", app)
        }
    }

    /// The same over a page in dark mode (Settings > Appearance > Dark).
    func testCaptureChromeOverTextDark() {
        let app = launch()
        go(app, "/long", heading: "Long Read")
        app.buttons["more"].tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Appearance'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        pause(1)
        row.tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 2))
        app.buttons["Dark"].tap()
        app.buttons["Done"].tap()
        pause(1)
        let webView = app.webViews.firstMatch
        webView.swipeUp(velocity: .slow)
        webView.swipeDown(velocity: 300)
        pause(1.5)
        shot("glass-4-dark", app)
    }

    /// Back on a link-opened tab: the tab slides away to the opener (record the screen for the
    /// motion; the shots are before and after).
    func testCaptureBackToOpener() {
        let app = launch()
        go(app, "/opener", heading: "Opener Page")
        app.webViews.links["Open B in a new tab"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Page B"].waitForExistence(timeout: 10))
        pause(1.5)
        shot("back-1-child", app)
        app.buttons["back"].tap()
        pause(0.12)
        shot("back-2-mid", app)
        XCTAssertTrue(app.webViews.staticTexts["Opener Page"].waitForExistence(timeout: 5))
        pause(1)
        shot("back-3-opener", app)
    }

    /// A long press on a link: the preview leaves room for the whole menu.
    func testCaptureLinkPreview() {
        let app = launch()
        go(app, "/opener", heading: "Opener Page")
        app.webViews.links["Read the long page"].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["linkMenu.downloadLinkedFile"].waitForExistence(timeout: 5))
        pause(1.5)
        shot("preview-1-portrait", app)
        let download = app.buttons["linkMenu.downloadLinkedFile"].frame
        XCTAssertLessThanOrEqual(download.maxY, app.windows.firstMatch.frame.maxY, "the menu's last item is on screen")
    }

    /// The intro's "What's inside", the empty private tab's shortcuts, and an empty sheet.
    func testCaptureSmallFixes() {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainShowIntro"]
        app.launch()
        let next = app.buttons["introNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        next.tap()
        XCTAssertTrue(app.staticTexts["Private Tabs"].waitForExistence(timeout: 5))
        pause(1.5)
        shot("small-1-intro-inside", app)
        app.buttons["introSkip"].tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        pause(0.8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.buttons["start.privateTab"].waitForExistence(timeout: 3))
        app.buttons["start.privateTab"].tap()
        pause(0.8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.buttons["start.regularTab"].waitForExistence(timeout: 3))
        pause(1)
        shot("small-2-private-start", app)
        app.buttons["more"].tap()
        let favorites = app.buttons["menu.editFavorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 3))
        favorites.tap()
        XCTAssertTrue(app.otherElements["sheetEmptyState"].waitForExistence(timeout: 3)
            || app.staticTexts["Add favorites from the page menu."].waitForExistence(timeout: 1))
        pause(1)
        shot("small-3-favorites-empty", app)
    }

    /// Compact height: one row, then the pill and hidden while reading, and the start screen.
    func testCaptureLandscape() {
        let app = launch()
        go(app, "/footer", heading: "Footer Page")
        go(app, "/long", heading: "Long Read")
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(3)
        let webView = app.webViews.firstMatch
        webView.swipeUp(velocity: 150)
        pause(3)
        webView.swipeUp(velocity: 600)
        pause(3)
        webView.swipeDown(velocity: 300)
        pause(3)
        app.buttons["back"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Footer Page"].waitForExistence(timeout: 5))
        pause(3)
        app.buttons["addressPill"].tap()
        pause(3)
    }
}
