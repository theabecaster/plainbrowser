import XCTest

/// What iOS really draws for each App Icon choice, beside what Plain shows of it: for every
/// choice, in the simulator's light and dark appearance, the Home Screen icon after Settings >
/// App Icon changed it, the launch splash on the next cold launch, Settings > App Icon after that
/// relaunch, and the intro's mark and icon step. For design review of the icons
/// (docs/decisions.md, "App icons: the Home Screen shows the picker's art").
///
/// Screenshots only, on request (`PLAIN_CAPTURE=1`, like CaptureTests) and on a simulator only:
/// it changes the real Home Screen icon (`-PlainRealAppIcon`, a Debug simulator hook in
/// `AppIcons`). Export the attachments with `xcrun xcresulttool export attachments`.
@MainActor
final class IconCaptureTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let choices = ["Dawn", "Night", "Coral", "Paper"]

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        #if !targetEnvironment(simulator)
        throw XCTSkip("never on a device: it changes the owner's Home Screen icon")
        #elseif !DEBUG
        throw XCTSkip("the real-icon hook is Debug only")
        #else
        // A new simulator's Home Screen icons are on Automatic, so they follow the appearance set
        // here; a simulator set to Tinted or Clear would not show the dark rendition.
        continueAfterFailure = true
        #endif
    }

    func testCaptureIconsLight() { capture(.light, tag: "light") }

    func testCaptureIconsDark() { capture(.dark, tag: "dark") }

    private func capture(_ appearance: XCUIDevice.Appearance, tag: String) {
        XCUIDevice.shared.appearance = appearance
        defer { XCUIDevice.shared.appearance = .light }
        pause(1)
        for choice in choices {
            // 1. Settings > App Icon picks it, as a person would.
            let app = launch([])
            pick(choice, in: app)
            shot("\(choice)-\(tag)-1-settings", app.screenshot())
            app.terminate()

            // 2. The Home Screen's icon.
            XCUIDevice.shared.press(.home)
            pause(1.5)
            homeIcon(choice, tag: tag)

            // 3. The next cold launch: the splash, held so it can be seen.
            let again = launch(["-PlainSplash", "-PlainSplashHold", "3"], waitForSearch: false)
            pause(1.2)
            shot("\(choice)-\(tag)-3-splash", again.screenshot())
            again.terminate()

            // 4. Settings > App Icon after the relaunch: the same choice is checked.
            let third = launch([])
            openAppIcon(third)
            let row = third.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(choice):")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            XCTAssertTrue(row.isSelected, "\(choice) is checked after a relaunch (\(tag))")
            shot("\(choice)-\(tag)-4-settings-relaunch", third.screenshot())
            third.terminate()

            // 5. The intro: its mark (the promise step), the icon step and the mark on the last step.
            let intro = launch(["-PlainShowIntro", "-PlainForceDefaultBrowserPrompts"], waitForSearch: false)
            let next = intro.buttons["introNext"]
            XCTAssertTrue(next.waitForExistence(timeout: 6))
            pause(1.8)
            shot("\(choice)-\(tag)-5-intro-promise", intro.screenshot())
            next.tap()
            pause(1.5)
            next.tap()
            pause(1.8)
            shot("\(choice)-\(tag)-6-intro-icon", intro.screenshot())
            for _ in 0..<5 where !intro.buttons["introNotNow"].exists {
                next.tap()
                pause(1.6)
            }
            pause(0.8)
            shot("\(choice)-\(tag)-7-intro-default", intro.screenshot())
            intro.terminate()
        }
        // Leave the default icon.
        let app = launch([])
        pick("Dawn", in: app)
        app.terminate()
    }

    // MARK: Steps

    private func launch(_ arguments: [String], waitForSearch: Bool = true) -> XCUIApplication {
        let app = XCUIApplication.introSeen()
        app.launchArguments += [IconCaptureTests.realIcon] + arguments
        app.launch()
        if waitForSearch { XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 8)) }
        return app
    }

    /// `AppIcons.realIconArgument`.
    private static let realIcon = "-PlainRealAppIcon"

    private func openAppIcon(_ app: XCUIApplication) {
        let field = app.textFields["searchField"]
        if field.exists && field.hasKeyboardFocus {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
        }
        XCTAssertTrue(app.buttons["more"].waitForExistence(timeout: 3))
        app.buttons["more"].tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "App Icon")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        pause(1.2)
    }

    private func pick(_ choice: String, in app: XCUIApplication) {
        openAppIcon(app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(choice):")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "\(choice) is a choice")
        guard !row.isSelected else { return }
        row.tap()
        // The system's "You have changed the icon" alert.
        for source in [app, springboard] {
            let ok = source.alerts.firstMatch.buttons.firstMatch
            if ok.waitForExistence(timeout: 3) {
                ok.tap()
                break
            }
        }
        pause(1)
    }

    /// Finds Plain on the Home Screen's pages and keeps the icon and the whole page.
    private func homeIcon(_ choice: String, tag: String) {
        let icon = springboard.icons["Plain"]
        var swipes = 0
        while !(icon.exists && icon.isHittable) && swipes < 4 {
            springboard.swipeLeft()
            pause(0.8)
            swipes += 1
        }
        guard icon.exists else {
            XCTFail("Plain is not on the Home Screen")
            return
        }
        pause(0.8)
        shot("\(choice)-\(tag)-2-home", springboard.screenshot())
        shot("\(choice)-\(tag)-2-home-icon", icon.screenshot())
        for _ in 0..<swipes { springboard.swipeRight() }
    }

    private func shot(_ name: String, _ screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
