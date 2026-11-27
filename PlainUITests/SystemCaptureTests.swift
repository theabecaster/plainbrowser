import XCTest

/// Screenshots of Plain outside Plain, for design review: the search widget on the Home Screen
/// and a favorite in Spotlight. Drives SpringBoard and Spotlight,
/// so it is best effort and skips itself unless `PLAIN_CAPTURE=1` reaches the runner (like
/// CaptureTests). Export the attachments with `xcrun xcresulttool export attachments`.
@MainActor
final class SystemCaptureTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        continueAfterFailure = true
    }

    /// Plain runs once with favorites, so the widget has them (the sync writes them a few seconds
    /// after launch) and iOS knows its widgets and shortcuts.
    private func launchPlainWithFavorites() {
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainInMemoryStore", "-PlainSeedFavorites"]
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        pause(8)
        XCUIDevice.shared.press(.home)
        pause(1.5)
    }

    func testCaptureHomeScreenWidgets() {
        launchPlainWithFavorites()
        addWidget(sizeSwipes: 1)
        addWidget(sizeSwipes: 0)
        pause(2)
        shot("widgets-home")
    }

    func testCaptureSpotlight() {
        launchPlainWithFavorites()
        // The Home Screen's Search pill, or a swipe down where there is none.
        let pill = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == 'Search'")).firstMatch
        if pill.waitForExistence(timeout: 2) { pill.tap() } else { springboard.swipeDown(velocity: .slow) }
        pause(1.5)
        // Spotlight is its own process, with the keyboard up on its field.
        let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
        spotlight.typeText("Plain")
        pause(3)
        shot("spotlight-plain")
        let clear = spotlight.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'clear'")).firstMatch
        if clear.exists { clear.tap() }
        spotlight.typeText("Wikipedia")
        pause(3)
        shot("spotlight-favorite")
        XCUIDevice.shared.press(.home)
    }

    /// Edit mode, the widget gallery, Plain's search widget at the size `sizeSwipes` pages in
    /// (0 small, 1 medium), Add Widget, out of edit mode.
    private func addWidget(sizeSwipes: Int) {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 1.5)
        pause(1)
        if springboard.buttons["Edit"].waitForExistence(timeout: 2) {
            springboard.buttons["Edit"].tap()
            pause(1)
            let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
            if add.waitForExistence(timeout: 2) { add.tap() }
        } else if springboard.buttons["Add Widget"].exists {
            springboard.buttons["Add Widget"].tap()
        }
        pause(2)
        shot("gallery-\(sizeSwipes)")
        let search = springboard.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap()
            search.typeText("Plain")
            pause(2)
        }
        // The gallery's result, not the Home Screen's Plain icon or widget under the sheet.
        let results = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == 'Plain'"))
        if results.firstMatch.waitForExistence(timeout: 3) { results.allElementsBoundByIndex.last?.tap() }
        pause(2)
        for _ in 0 ..< sizeSwipes {
            springboard.swipeLeft()
            pause(1)
        }
        shot("picker-\(sizeSwipes)")
        let addWidget = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
        if addWidget.waitForExistence(timeout: 3) { addWidget.tap() }
        pause(2)
        // Leaves edit mode.
        XCUIDevice.shared.press(.home)
        pause(1)
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
