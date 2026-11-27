import XCTest

/// Walks the shell through its states with pauses, attaching a screenshot of each, for design
/// review and screen recordings (docs/workflow.md, Verify). Not a test of behavior: it skips
/// itself unless `PLAIN_CAPTURE=1` reaches the runner. Run it alone:
/// `TEST_RUNNER_PLAIN_CAPTURE=1 xcodebuild ... -only-testing:PlainUITests/CaptureTests test-without-building`,
/// then export the attachments with `xcrun xcresulttool export attachments`.
@MainActor
final class CaptureTests: XCTestCase {
    func testCaptureShellStates() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainSeedFavorites"]
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        pause(1.5)
        shot("1-launch")

        for path in ["/a", "/b"] {
            if !(field.exists && field.hasKeyboardFocus) { app.buttons["addressPill"].tap() }
            field.typeText(server.address(path) + "\n")
            XCTAssertTrue(app.webViews.staticTexts[path == "/a" ? "Page A" : "Page B"].waitForExistence(timeout: 10))
        }
        app.buttons["addressPill"].tap()
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 10))
        pause(2.5)
        shot("2-page")

        // URL bar focus: the pill grows into the search sheet.
        app.buttons["addressPill"].tap()
        pause(1)
        shot("3-focus")
        field.typeText("Plain")
        pause(1.5)
        shot("4-suggestions")
        // Clear the field (no rows left), then close the sheet with a tap on its empty top.
        field.buttons.firstMatch.tap()
        pause(0.5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
        pause(1)

        // Toolbar collapse.
        let webView = app.webViews.firstMatch
        webView.swipeUp(velocity: .slow)
        pause(1)
        shot("5-collapsed")
        webView.swipeDown(velocity: .slow)
        pause(1)

        // Page menu from the pill.
        app.buttons["addressPill"].press(forDuration: 0.8)
        pause(1)
        shot("6-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        pause(1)

        // Pull to refresh, slowly, holding past the threshold.
        let start = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
        pause(2)
        shot("7-after-refresh")
    }

    /// The sheets the shell presents: page menu, Settings, Search Engine, History, and the
    /// favorites strip's menu and editor.
    func testCaptureSheets() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainSeedFavorites"]
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for (path, heading) in [("/a", "Page A"), ("/b", "Page B"), ("/long", "Long Read")] {
            if !(field.exists && field.hasKeyboardFocus) { app.buttons["addressPill"].tap() }
            field.typeText(server.address(path) + "\n")
            XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10))
        }
        pause(2.5)

        app.buttons["more"].tap()
        pause(1)
        shot("s1-page-menu")
        app.buttons["menu.settings"].tap()
        pause(1.5)
        shot("s2-settings")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Search Engine'")).firstMatch.tap()
        pause(1)
        shot("s3-search-engine")
        let back = app.otherElements["settingsSheet"].buttons["BackButton"]
        if back.exists { back.tap() } else { app.navigationBars["Search Engine"].buttons.firstMatch.tap() }
        pause(0.8)
        app.buttons["Done"].tap()
        pause(1)

        app.buttons["more"].tap()
        pause(1)
        app.buttons["History"].tap()
        pause(1.5)
        shot("s4-history")
        app.buttons["Done"].tap()
        pause(1)

        app.buttons["addressPill"].tap()
        pause(1)
        app.buttons["favorite.0"].press(forDuration: 1)
        pause(1)
        shot("s5-favorites-menu")
        app.buttons["Edit Favorites"].tap()
        pause(1.5)
        shot("s6-favorites-editor")
        app.buttons["Done"].tap()
        pause(1.5)
        shot("s7-back-to-search")
    }

    /// The bar over a page with a fixed footer, expanded and collapsed: the footer sits above
    /// the resting bar, and the scroll edge effect keeps text under the bar readable.
    func testCaptureFixedFooter() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore"]
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/footer") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Footer Page"].waitForExistence(timeout: 10))
        pause(2)
        shot("f1-footer-expanded")
        app.webViews.firstMatch.swipeUp(velocity: .slow)
        pause(2)
        shot("f2-footer-collapsed")
        // The page's end with the bar expanded: the last line clears the bar.
        for _ in 0..<10 { app.webViews.firstMatch.swipeUp(velocity: .fast) }
        pause(2)
        app.buttons["addressPill"].tap()
        pause(2)
        shot("f3-page-end")
    }

    /// The engine wiring: a page, its menu, the reader view and a permission prompt. Grant the
    /// app location first (`xcrun simctl privacy <udid> grant location <bundle id>`), so the
    /// site's prompt is Plain's, not the system's.
    func testCaptureEngine() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainSeedFavorites"]
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/article") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["The Quiet Page"].waitForExistence(timeout: 10))
        pause(2)
        shot("e1-page")

        app.buttons["more"].tap()
        pause(1)
        shot("e2-page-menu")
        let reader = app.buttons["Show Reader"]
        if reader.waitForExistence(timeout: 2) {
            reader.tap()
            XCTAssertTrue(app.webViews["readerView"].waitForExistence(timeout: 5))
            pause(1.5)
            shot("e3-reader")
            app.buttons["back"].tap()
            pause(1)
        }

        // The permission prompt: WebKit asks only on secure pages and the simulator has no camera,
        // so a debug launch argument shows the camera prompt over a page.
        app.terminate()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainPreviewPermissionPrompt"]
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/b") + "\n")
        let allow = app.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) {
            pause(1)
            shot("e4-permission")
            allow.tap()
        } else {
            shot("e4-no-prompt")
        }
        pause(1)
    }

    /// Tabs (M2): a few real pages, the gallery, a slow bar swipe and a slow swipe up (for the
    /// screen recording's mid-gesture frames), private tabs, the archive, the page menu with its
    /// zoom row, and the Downloads sheet. Real sites need the network; the download comes from the
    /// TestServer.
    func testCaptureTabs() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainSeedFavorites", "-PlainSeedArchive"]
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        let sites = ["en.wikipedia.org/wiki/Web_browser", "news.ycombinator.com", "www.apple.com/iphone/", "github.com/WebKit/WebKit"]
        for (index, site) in sites.enumerated() {
            if index > 0 {
                app.buttons["tabs"].press(forDuration: 1)
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch.tap()
            }
            if !(field.exists && field.hasKeyboardFocus) { app.buttons["addressPill"].tap() }
            field.typeText(site + "\n")
            _ = app.webViews.firstMatch.waitForExistence(timeout: 10)
            pause(4)
        }
        shot("t1-page")

        // Gallery from the tabs button, then back with a card.
        app.buttons["tabs"].tap()
        pause(1.5)
        shot("t2-gallery")
        let cards = app.scrollViews["tabGallery"].descendants(matching: .any).matching(identifier: "tabCard")
        app.scrollViews["tabGallery"].swipeRight(velocity: .fast)
        cards.matching(NSPredicate(format: "label BEGINSWITH %@", "Hacker News")).firstMatch.tap()
        pause(1.5)

        // A slow bar swipe toward the next tab, held mid-way, then let go.
        let pill = app.buttons["addressPill"]
        let start = pill.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: pill.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 1.2)
        pause(1.5)
        // And back.
        pill.swipeRight(velocity: .fast)
        pause(1.5)

        // A slow swipe up from the bar into the gallery.
        pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
            withVelocity: .slow, thenHoldForDuration: 0.8
        )
        pause(1.5)
        shot("t3-gallery-swipe")

        // Private: the toggle, a private page, the private gallery.
        app.buttons["galleryPrivate"].tap()
        pause(1.2)
        shot("t4-private-empty")
        // An empty list has one New Tab: the empty state's button (state rules, principle 8).
        app.buttons["emptyNewTab"].tap()
        pause(1)
        field.typeText("en.wikipedia.org/wiki/Private_browsing\n")
        pause(4)
        shot("t5-private-page")
        app.buttons["tabs"].tap()
        pause(1.5)
        shot("t6-private-gallery")
        app.buttons["galleryPrivate"].tap()
        pause(1)

        // The archive from the gallery's menu.
        app.buttons["galleryMenu"].tap()
        pause(0.8)
        app.buttons["Archived Tabs"].tap()
        pause(1.5)
        shot("t7-archive")
        app.navigationBars.buttons["Done"].tap()
        pause(1)
        app.buttons["galleryDone"].tap()
        pause(1.5)

        // The page menu with the zoom row, after one step in.
        app.buttons["more"].tap()
        pause(1)
        shot("t8-page-menu")
        app.buttons["menu.zoomIn"].tap()
        pause(1)
        shot("t8b-page-menu-zoomed")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        pause(1)

        // A download: the toast, then the Downloads sheet.
        app.buttons["addressPill"].tap()
        field.typeText(server.address("/files") + "\n")
        XCTAssertTrue(app.webViews.links["Download notes"].waitForExistence(timeout: 10))
        app.webViews.links["Download notes"].tap()
        pause(1.5)
        shot("t9-download-toast")
        let show = app.buttons["toastButton"]
        if show.waitForExistence(timeout: 3) { show.tap() }
        pause(1.5)
        shot("t10-downloads")
        app.navigationBars.buttons["Done"].tap()
        pause(1)
    }

    /// One page tab into the switcher: a slow swipe up held mid-way (for the recording's frames),
    /// the lone card, then Show All Tabs and the bar's + (New Tab).
    func testCaptureOneTab() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainSeedFavorites"]
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 10))
        pause(2.5)
        shot("o1-page")

        // The swipe up held at three heights, so the recording shows the page part way into its
        // card (a continuous drag drops frames in the simulator's recorder). The first is short of
        // the commit and goes back to the page; the others land in the switcher.
        let pill = app.buttons["addressPill"]
        for (index, height) in [0.8, 0.7, 0.6].enumerated() {
            pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: height)),
                withVelocity: .slow, thenHoldForDuration: 1.2
            )
            pause(1.5)
            if index > 0, app.buttons["galleryDone"].exists, index < 2 {
                app.buttons["galleryDone"].tap()
                pause(1.5)
            }
        }
        shot("o2-switcher")
        app.buttons["galleryDone"].tap()
        pause(1.5)

        app.buttons["tabs"].press(forDuration: 1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show All Tabs'")).firstMatch.tap()
        pause(1.5)
        app.buttons["galleryNewTab"].tap()
        pause(1.5)
        shot("o4-newtab-search")
    }

    /// The bar in each main state of docs/state-rules.md: first run, the start screen, one page,
    /// several tabs, loading and private; plus the More and tabs menus.
    func testCaptureStateRules() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.isolated()
        // An archive from the start, so the start screen and More show Archived Tabs.
        app.launchArguments += ["-PlainInMemoryStore", "-PlainSeedArchive"]
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        pause(1)
        shot("s1-first-run")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        pause(1)
        shot("s2-start")
        app.buttons["more"].tap()
        pause(1)
        shot("s2b-start-more")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        pause(0.8)

        app.buttons["addressPill"].tap()
        field.typeText(server.address("/a") + "\n")
        pause(2)
        shot("s3-one-page")
        // The start screen while typing: before (empty field) and after (a query with rows).
        app.buttons["tabs"].press(forDuration: 1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch.tap()
        pause(1.2)
        shot("s7a-start-typing-before")
        field.typeText("Plain Test")
        pause(1.5)
        shot("s7b-start-typing-after")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        pause(1)
        // Back to the page: the empty tab goes away when left.
        app.buttons["addressPill"].swipeRight(velocity: .fast)
        pause(1.5)
        app.buttons["tabs"].press(forDuration: 1)
        pause(1)
        shot("s3b-one-page-tabs-menu")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch.tap()
        field.typeText(server.address("/b") + "\n")
        pause(2)
        app.buttons["tabs"].press(forDuration: 1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch.tap()
        field.typeText(server.address("/c") + "\n")
        pause(2)
        shot("s4-several-tabs")
        app.buttons["more"].tap()
        pause(1)
        shot("s4b-several-tabs-more")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        pause(0.8)

        app.buttons["addressPill"].tap()
        field.typeText(server.address("/slow") + "\n")
        pause(1.5)
        shot("s5-loading")
        pause(8)

        app.buttons["tabs"].press(forDuration: 1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Private Tab'")).firstMatch.tap()
        field.typeText(server.address("/b") + "\n")
        pause(2)
        shot("s6-private")

        // Something closed: the start screen offers it back, with the archive.
        app.buttons["tabs"].press(forDuration: 1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch.tap()
        pause(0.8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        pause(0.8)
        app.buttons["addressPill"].swipeRight(velocity: .fast)
        pause(1.5)
        app.buttons["tabs"].press(forDuration: 1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close Tab'")).firstMatch.tap()
        pause(1)
        app.buttons["more"].tap()
        pause(1)
        shot("s8a-more-with-closed")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        pause(0.8)
        app.buttons["tabs"].press(forDuration: 1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch.tap()
        pause(0.8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        pause(1.2)
        shot("s8b-start-with-closed")
    }

    /// The Paper surfaces: the intro, the start screen (keyboard up and down), the reader view,
    /// Settings and the gallery. Set the simulator's appearance first (`xcrun simctl ui <udid>
    /// appearance dark`); `PLAIN_CAPTURE_TAG` names the shots (light, dark).
    func testCapturePaper() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        do {
            let name = ProcessInfo.processInfo.environment["PLAIN_CAPTURE_TAG"] ?? "light"
            let intro = XCUIApplication.isolated()
            intro.launchArguments += ["-PlainShowIntro"]
            intro.launch()
            pause(3)
            shot("p0-intro-\(name)")
            intro.terminate()

            let app = XCUIApplication.isolated()
            app.launchArguments += ["-PlainInMemoryStore"]
            app.launch()
            let field = app.textFields["searchField"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            pause(1.5)
            shot("p1-start-\(name)")

            field.typeText(server.address("/article") + "\n")
            XCTAssertTrue(app.webViews.staticTexts["The Quiet Page"].waitForExistence(timeout: 10))
            pause(1.5)
            app.buttons["more"].tap()
            let reader = app.buttons["Show Reader"]
            if reader.waitForExistence(timeout: 3) {
                reader.tap()
                XCTAssertTrue(app.webViews["readerView"].waitForExistence(timeout: 5))
                pause(1.5)
                shot("p2-reader-\(name)")
                app.buttons["back"].tap()
                pause(1)
            }

            app.buttons["more"].tap()
            app.buttons["menu.settings"].tap()
            pause(1.5)
            shot("p3-settings-\(name)")
            app.navigationBars.buttons["Done"].tap()
            pause(1)

            // A new tab beside the page: its start screen with the keyboard down, then the gallery
            // (an empty tab leaves it, docs/state-rules.md). The tabs button sits under the keyboard.
            app.buttons["tabs"].press(forDuration: 1)
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch.tap()
            pause(1)
            let start = app.otherElements["emptyTab"]
            if start.exists { start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap() }
            pause(1)
            shot("p4-start-keyboard-down-\(name)")
            if app.buttons["tabs"].waitForExistence(timeout: 2), app.buttons["tabs"].isHittable {
                app.buttons["tabs"].tap()
            } else {
                app.buttons["addressPill"].swipeUp(velocity: .fast)
            }
            pause(1.5)
            shot("p5-gallery-\(name)")
        }
    }

    /// The polish lane's states: the page menu and its Site Settings, Find on Page with the bar
    /// out of the way, a failed page's pill, the switcher with two cards, and the start screen
    /// with Tabs and More beside the pill.
    func testCapturePolish() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainSeedFavorites"]
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/a") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
        app.buttons["addressPill"].tap()
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 10))
        pause(2)

        app.buttons["more"].tap()
        pause(1)
        shot("p1-page-menu")
        let site = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Site Settings'")).firstMatch
        if site.exists {
            site.tap()
            pause(1)
            shot("p2-site-settings")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        pause(1)

        app.buttons["more"].tap()
        pause(0.8)
        app.buttons["Find on Page"].tap()
        pause(1.5)
        app.typeText("Paragraph")
        pause(1)
        shot("p3-find")
        app.typeText("\n")
        pause(1.5)
        shot("p4-find-keyboard-down")
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Done', 'Close'}")).firstMatch
        if close.exists { close.tap() }
        pause(1.5)
        shot("p5-find-closed")

        // A load that fails: the pill shows the address that was tried.
        app.buttons["addressPill"].tap()
        field.typeText("127.0.0.1:9/nothing-here\n")
        pause(4)
        shot("p6-failed")

        // Two cards in the switcher.
        app.buttons["tabs"].press(forDuration: 1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch.tap()
        pause(0.8)
        field.typeText(server.address("/b") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page B"].waitForExistence(timeout: 10))
        pause(2)
        let pill = app.buttons["addressPill"]
        pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
            withVelocity: .slow, thenHoldForDuration: 1.5
        )
        pause(1.5)
        shot("p7-switcher")

        // A new tab with others open: Tabs and More beside the pill.
        app.buttons["galleryNewTab"].tap()
        pause(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        pause(1.5)
        shot("p8-start-with-tabs")
    }

    /// Reading a long page with a fixed footer: expanded, the pill, hidden, and each way back
    /// (scroll up, a tap on the bottom edge, the page's end), for the scroll chrome's review.
    func testCaptureScrollChrome() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.typeText(server.address("/footer") + "\n")
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.staticTexts["Footer Page"].waitForExistence(timeout: 10))
        pause(2)
        shot("scroll-1-expanded")

        func drag(_ from: CGFloat, _ to: CGFloat) {
            let start = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            let end = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        drag(0.6, 0.5)
        pause(1.5)
        shot("scroll-2-pill")
        webView.swipeUp(velocity: .slow)
        pause(2)
        shot("scroll-3-hidden")
        drag(0.4, 0.5)
        pause(1.5)
        shot("scroll-4-back-scroll-up")
        webView.swipeUp(velocity: .slow)
        pause(1.5)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995)).tap()
        pause(1.5)
        shot("scroll-5-back-edge-tap")
        webView.swipeUp(velocity: .slow)
        pause(1)
        let end = webView.staticTexts["End of page."]
        for _ in 0..<14 where !(end.exists && end.isHittable) { webView.swipeUp(velocity: .fast) }
        pause(2.5)
        shot("scroll-6-back-page-end")
    }

    /// The hidden bar coming back over a fixed footer, for a frame strip: the caller records the
    /// screen (`simctl io recordVideo`) while this runs. Each reveal follows a 2 s still, so the
    /// strip can find it: a tap on the bottom edge, then a move up.
    func testCaptureRevealOverFooter() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.typeText(server.address("/footer") + "\n")
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.staticTexts["Footer Page"].waitForExistence(timeout: 10))
        pause(1.5)
        webView.swipeUp(velocity: .slow)
        pause(2)
        shot("reveal-0-hidden")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995)).tap()
        pause(2)
        shot("reveal-1-edge-tap")
        webView.swipeUp(velocity: .slow)
        pause(2)
        let start = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(2)
        shot("reveal-2-scroll-up")
    }

    /// The bar over pages with a fixed, a sticky, a dark page's and no header, on any screen (the
    /// Duo's inner top bar, or the bottom bar of phones and the outer screen, where the page runs
    /// under the status bar): at rest (no band of the header's color behind Plain's controls, the
    /// first line under them), read part way (the pill, then hidden), revealed mid-page, back at
    /// the top, and back from another page. Each step follows a 2 s still, so a screen recording
    /// made alongside (`simctl io recordVideo`) gives a frame strip of every collapse and reveal.
    /// On the unfolded Duo `XCUIScreen.main` is the outer screen, so record the inner display
    /// (`--display=<id>`); the attachments then only mark each step's time in the log. Pass the
    /// device's status corner with `TEST_RUNNER_PLAIN_STATUS_CORNER=828,24,100,45` there.
    func testCaptureBarOverHeaders() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        if let corner = ProcessInfo.processInfo.environment["PLAIN_STATUS_CORNER"] {
            app.launchArguments += ["-PlainStatusCorner", corner]
        }
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let webView = app.webViews.firstMatch
        func open(_ path: String, _ heading: String) {
            if !(field.exists && field.hasKeyboardFocus) {
                app.buttons["addressPill"].tap()
                XCTAssertTrue(field.waitForExistence(timeout: 2))
            }
            field.typeText(server.address(path) + "\n")
            XCTAssertTrue(webView.staticTexts[heading].waitForExistence(timeout: 10))
            pause(2)
        }
        func drag(_ from: CGFloat, _ to: CGFloat) {
            let start = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            let end = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        for (path, heading, name) in [
            ("/fixed-header", "Fixed Header Page", "fixed"), ("/sticky-header", "Sticky Header Page", "sticky"),
            ("/dark-header", "Dark Header Page", "dark"), ("/long", "Long Read", "none"),
        ] {
            open(path, heading)
            shot("\(name)-1-rest")
            drag(0.6, 0.45)
            pause(2)
            shot("\(name)-2-pill")
            webView.swipeUp(velocity: .slow)
            pause(2)
            shot("\(name)-3-hidden")
            drag(0.4, 0.55)
            pause(2)
            shot("\(name)-4-revealed")
            for _ in 0..<4 { webView.swipeDown(velocity: .fast) }
            pause(2)
            shot("\(name)-5-top")
        }
        // Back to a page with a fixed header from another page: restored at its top, as it was.
        open("/fixed-header", "Fixed Header Page")
        open("/b", "Page B")
        app.buttons["back"].tap()
        XCTAssertTrue(webView.staticTexts["Fixed Header Page"].waitForExistence(timeout: 10))
        pause(2)
        shot("fixed-6-back")
    }

    /// The page menu on a readerable page, a foreign page, and a readerable foreign page with a
    /// closed tab to reopen (its tallest common state), for the fit on the Duo's outer screen.
    func testCapturePageMenuStates() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainTestTranslator", "-PlainTranslateHintShown", "YES"]
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        func open(_ path: String, _ heading: String) {
            if !(field.exists && field.hasKeyboardFocus) {
                app.buttons["addressPill"].tap()
                XCTAssertTrue(field.waitForExistence(timeout: 2))
            }
            field.typeText(server.address(path) + "\n")
            XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10))
            pause(2)
        }
        func menuShot(_ name: String) {
            app.buttons["more"].tap()
            XCTAssertTrue(app.buttons["menu.settings"].waitForExistence(timeout: 3))
            pause(1)
            shot(name)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.1)).tap()
            pause(0.8)
        }
        open("/article", "The Quiet Page")
        menuShot("menu-1-readerable")
        open("/french", "Le marché du samedi")
        menuShot("menu-2-foreign")
        let tabs = app.buttons["tabs"]
        tabs.press(forDuration: 1.0)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch.tap()
        open("/b", "Page B")
        tabs.press(forDuration: 1.0)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close Tab'")).firstMatch.tap()
        pause(1)
        open("/french-article", "La page tranquille")
        menuShot("menu-3-readerable-foreign-reopen")
    }

    /// History and Archived Tabs with search under the title: at rest, with rows scrolled under the
    /// field, and searching.
    func testCaptureHistorySearch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainSeedArchive"]
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let pages = [("/a", "Page A"), ("/b", "Page B"), ("/c", "Page C"), ("/article", "The Quiet Page"),
                     ("/long", "Long Read"), ("/footer", "Footer Page"), ("/french", "Le marché du samedi"),
                     ("/files", "Files"), ("/count", "Load 1"), ("/light-site", "Light Only"), ("/french-article", "La page tranquille")]
        for (path, heading) in pages {
            if !(field.exists && field.hasKeyboardFocus) { app.buttons["addressPill"].tap() }
            field.typeText(server.address(path) + "\n")
            _ = app.webViews.staticTexts[heading].waitForExistence(timeout: 10)
        }
        pause(1.5)
        app.buttons["more"].tap()
        XCTAssertTrue(app.buttons["menu.history"].waitForExistence(timeout: 3))
        app.buttons["menu.history"].tap()
        pause(1.5)
        shot("h1-history")
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 2) {
            search.tap()
            search.typeText("Page")
            pause(1.5)
            shot("h2-history-searching")
            // Out of search (its close button).
            let close = app.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'Close', 'close'}")).firstMatch
            if close.exists { close.tap() }
            pause(1)
        }
        // Rows scrolled a little way (the field scrolls away under the title), then further.
        let list = app.collectionViews.firstMatch
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        pause(1.5)
        shot("h3-history-scrolled")
        app.swipeUp(velocity: .slow)
        pause(1.5)
        shot("h4-history-scrolled-more")
        app.swipeDown(velocity: .fast)
        pause(0.5)
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() } else { app.swipeDown(velocity: .fast) }
        pause(1.5)
        app.buttons["more"].tap()
        let archive = app.buttons["more.archivedTabs"]
        if archive.waitForExistence(timeout: 3) {
            archive.tap()
            pause(1.5)
            shot("h5-archive")
        }
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
