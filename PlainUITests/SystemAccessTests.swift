import XCTest

/// Features switched off for Plain (docs/research/permissions-states.md): a site's request says
/// why in one toast, once per site; Save Image says why; the error page says cellular data is off
/// for Plain; Site Settings shows "Off in Settings"; a summary on its way ends in one line when the
/// model goes away. What iOS reports comes from the simulator's own privacy settings where it can
/// (`xcrun simctl privacy <udid> revoke …`), and otherwise from Debug's `-PlainSystemAccess`
/// (the simulator has no camera and no cellular). Local pages can't reach WebKit's own prompts
/// (they need a secure page), so the remembered answers Site Settings lists are seeded.
@MainActor
final class SystemAccessTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication.isolated()
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        return app
    }

    private func go(_ app: XCUIApplication, to path: String, heading: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show")
    }

    private var site: String { "http://localhost:\(server.port)" }

    /// The site asks for the location while it is off for Plain: one toast with Settings, and not
    /// again on the site's next page.
    func testLocationOffSaysSoOncePerSite() throws {
        let app = try launch(["-PlainSystemAccess", "location=denied"])
        go(app, to: "/location", heading: "Location denied")
        let toast = app.staticTexts["Location is off for Plain"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["toastButton"].label, "Settings")
        shot("l1-location-off")
        XCTAssertTrue(toast.waitForNonExistence(timeout: 8))

        go(app, to: "/location", heading: "Location denied")
        XCTAssertFalse(toast.waitForExistence(timeout: 2), "no nag on the next page")
    }

    /// Camera and microphone both off: one line names both.
    func testCameraAndMicrophoneOff() throws {
        let app = try launch(["-PlainSystemAccess", "camera=denied,microphone=denied"])
        go(app, to: "/camera", heading: "Camera denied")
        XCTAssertTrue(app.staticTexts["Camera and microphone are off for Plain"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["toastButton"].exists)
        shot("c1-camera-off")
    }

    /// Screen Time: the line explains, and has no button (Plain's page in Settings can't change it).
    func testScreenTimeRestrictionHasNoButton() throws {
        let app = try launch(["-PlainSystemAccess", "camera=restricted,microphone=restricted"])
        go(app, to: "/camera", heading: "Camera denied")
        XCTAssertTrue(app.staticTexts["Camera and microphone aren't allowed on this iPhone"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["toastButton"].isHittable)
        shot("c2-camera-restricted")
    }

    /// Everything on (or never asked): the page's own answer, nothing of Plain's.
    func testNothingWhileNotSwitchedOff() throws {
        let app = try launch(["-PlainSystemAccess", "camera=allowed,microphone=allowed,location=allowed"])
        go(app, to: "/camera", heading: "Camera denied")
        go(app, to: "/location", heading: "Location denied")
        XCTAssertFalse(app.otherElements["toast"].waitForExistence(timeout: 2))
    }

    /// Cellular data off for Plain with no Wi-Fi: the error page says so, with Open Settings and
    /// Try Again. (`-PlainSystemAccess cellular=denied` counts any connection failure as the
    /// network's, as the phone reports it offline.)
    func testCellularOffErrorPage() throws {
        let app = try launch(["-PlainSystemAccess", "cellular=denied"])
        let field = app.textFields["searchField"]
        field.typeText("localhost:1/nothing\n")
        XCTAssertTrue(app.staticTexts["Cellular data is off for Plain."].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["pageState.button"].label, "Open Settings")
        XCTAssertEqual(app.buttons["pageState.secondary"].label, "Try Again")
        shot("n1-cellular-off")
    }

    /// Site Settings lists what the site asked for, with what iOS allows: the camera it was
    /// allowed is "Off in Settings" while the camera is off for Plain; the location it was refused
    /// is "Not Allowed".
    func testSiteSettingsShowOffInSettings() throws {
        // The server's port is known only once it runs: start it before the seed argument.
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        let app = try launch([
            "-PlainSystemAccess", "camera=denied",
            "-PlainSeedSitePermissions", site, "camera=true,location=false",
        ])
        go(app, to: "/a", heading: "Page A")
        Thread.sleep(forTimeInterval: 1)
        app.buttons["more"].tap()
        let siteSettings = app.buttons["menu.siteSettings"]
        XCTAssertTrue(siteSettings.waitForExistence(timeout: 3))
        siteSettings.tap()
        let camera = app.buttons["menu.permission.camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 3))
        XCTAssertTrue(camera.label.contains("Off in Settings") || (camera.value as? String)?.contains("Off in Settings") == true, camera.label)
        let location = app.buttons["menu.permission.location"]
        XCTAssertTrue(location.label.contains("Not Allowed") || (location.value as? String)?.contains("Not Allowed") == true, location.label)
        XCTAssertFalse(app.buttons["menu.permission.microphone"].exists, "a permission the site never asked for has no row")
        shot("s1-site-settings")
    }

    /// Save Image while Photos is off for Plain. Needs the simulator's Photos switch off
    /// (`xcrun simctl privacy <udid> revoke photos-add <bundle id>`): the runner says so with
    /// `TEST_RUNNER_PLAIN_PHOTOS_DENIED=1`.
    func testSaveImageWithPhotosOff() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_PHOTOS_DENIED"] == "1", "needs Photos revoked")
        let app = try launch()
        go(app, to: "/photo", heading: "Photo")
        Thread.sleep(forTimeInterval: 1)
        app.webViews.images.firstMatch.press(forDuration: 1.2)
        let save = app.buttons["Save Image"]
        XCTAssertTrue(save.waitForExistence(timeout: 4))
        save.tap()
        XCTAssertTrue(app.staticTexts["Saving to Photos is off for Plain"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.buttons["toastButton"].label, "Settings")
        shot("p1-photos-off")
    }

    /// The model goes away while Plain is in the background with a summary on its way: on the way
    /// back the summary ends in one line, and Browse for Me is gone from the search field.
    func testSummaryEndsWhenTheModelGoesAway() throws {
        let app = try launch(["-PlainTestSummaries", "-PlainAIGoesAwayInBackground"])
        let field = app.textFields["searchField"]
        field.typeText("trail running shoes")
        let row = app.buttons["browseForMe"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.otherElements["summaryScreen"].firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        app.activate()
        let failure = app.staticTexts["summaryFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertEqual(failure.label, "Apple Intelligence isn't available right now.")
        XCTAssertFalse(app.buttons["summaryTryAgain"].exists)
        shot("a1-summary-ended")
        app.buttons["Done"].tap()
        app.buttons["addressPill"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText("trail running shoes")
        XCTAssertFalse(row.waitForExistence(timeout: 2), "the entry is gone while the model can't run")
        shot("a2-row-gone")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
