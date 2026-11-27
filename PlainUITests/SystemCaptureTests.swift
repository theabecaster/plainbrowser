import XCTest

/// Screenshots of Plain outside Plain, for design review: the search widget on the Home Screen
/// and Plain's actions in Spotlight. Drives SpringBoard and Spotlight,
/// so it is best effort and skips itself unless `PLAIN_CAPTURE=1` reaches the runner (like
/// CaptureTests). Export the attachments with `xcrun xcresulttool export attachments`.
///
/// Simulator only: it adds widgets to the Home Screen, which on the owner's phone is theirs, and
/// the widget extension is a process the system starts, without the app's isolation arguments, so
/// it reads the installed app's real App Group (on a simulator, a throwaway one). The
/// app runs isolated, so its favorites stay in the run's own folder: the widget on the Home Screen
/// shows its empty face and Spotlight has no favorites from a test (TestIsolation). The faces
/// with favorites are rendered by SystemIntegrationTests (WidgetTests) instead.
@MainActor
final class SystemCaptureTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        #if !targetEnvironment(simulator)
        throw XCTSkip("never on a device: it changes the owner's Home Screen")
        #endif
        continueAfterFailure = true
    }

    /// Plain runs once, so iOS knows its widgets and shortcuts.
    private func launchPlain() {
        let app = XCUIApplication.introSeen()
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        pause(2)
        XCUIDevice.shared.press(.home)
        pause(1.5)
    }

    func testCaptureHomeScreenWidgets() {
        launchPlain()
        addWidget(sizeSwipes: 1)
        addWidget(sizeSwipes: 0)
        pause(2)
        shot("widgets-home")
    }

    func testCaptureSpotlight() {
        launchPlain()
        // The Home Screen's Search pill, or a swipe down where there is none.
        let pill = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == 'Search'")).firstMatch
        if pill.waitForExistence(timeout: 2) { pill.tap() } else { springboard.swipeDown(velocity: .slow) }
        pause(1.5)
        // Spotlight is its own process, with the keyboard up on its field.
        let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
        spotlight.typeText("Plain")
        pause(3)
        shot("spotlight-plain")
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
