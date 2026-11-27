import XCTest

/// Screenshots of Plain outside Plain, for design review: the search widget on the Home Screen,
/// Plain's App Shortcuts in Spotlight and in the Shortcuts app. Drives SpringBoard and Shortcuts,
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

    func testCaptureSpotlightAndShortcuts() {
        launchPlainWithFavorites()
        // Spotlight: swipe down on the Home Screen, then search for Plain.
        springboard.swipeDown(velocity: .slow)
        pause(1)
        springboard.typeText("Plain")
        pause(3)
        shot("spotlight-plain")
        springboard.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue
            + XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "Wikipedia")
        pause(3)
        shot("spotlight-favorite")
        XCUIDevice.shared.press(.home)

        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()
        pause(3)
        for label in ["Continue", "Not Now", "OK"] where shortcuts.buttons[label].exists {
            shortcuts.buttons[label].tap()
            pause(1)
        }
        shot("shortcuts-home")
        let plain = shortcuts.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Plain'")).firstMatch
        if plain.waitForExistence(timeout: 5) {
            plain.tap()
            pause(2)
            shot("shortcuts-plain")
        }
    }

    /// Edit mode, the widget gallery, Plain's search widget at the size `sizeSwipes` pages in
    /// (0 small, 1 medium), Add Widget, Done.
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
        let plain = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == 'Plain'")).element(boundBy: 0)
        if plain.waitForExistence(timeout: 3) { plain.tap() }
        pause(2)
        for _ in 0 ..< sizeSwipes {
            springboard.swipeLeft()
            pause(1)
        }
        shot("picker-\(sizeSwipes)")
        let addWidget = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
        if addWidget.waitForExistence(timeout: 3) { addWidget.tap() }
        pause(2)
        if springboard.buttons["Done"].waitForExistence(timeout: 2) { springboard.buttons["Done"].tap() }
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
