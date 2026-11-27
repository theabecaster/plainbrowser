import XCTest

/// Profiles end to end (docs/decisions.md, "Profiles, no tab groups"): New Profile from the
/// gallery, a profile's own logins (a cookie set in Personal is not in Work), switching lists
/// from the switcher, rename, delete after one confirmation, and a profile back after a relaunch.
/// Every launch is isolated: the profiles' website data stores are throwaway ones the test run
/// records and removes.
@MainActor
final class ProfilesTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ arguments: [String] = ["-PlainInMemoryStore"]) throws -> XCUIApplication {
        continueAfterFailure = false
        if server == nil {
            server = try TestServer()
            try server.start()
            addTeardownBlock { [server] in server?.stop() }
        }
        let app = XCUIApplication.isolated()
        app.launchArguments += arguments
        app.launch()
        XCTAssertTrue(app.waitForFirstScreen())
        XCTAssertTrue(app.waitForStoreReady())
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

    private func waitForPage(_ app: XCUIApplication, _ heading: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show",
            file: file, line: line
        )
    }

    private func openGallery(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["tabs"].tap()
        let gallery = app.scrollViews["tabGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        return gallery
    }

    private func pick(_ app: XCUIApplication, _ item: String, file: StaticString = #filePath, line: UInt = #line) {
        let action = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3), "\"\(item)\" is not in the menu", file: file, line: line)
        action.tap()
    }

    /// Types `name` into the profile name alert and confirms with `button`.
    private func name(_ app: XCUIApplication, _ name: String, confirm button: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertFalse(alert.buttons[button].isEnabled && (field.value as? String ?? "").isEmpty, "\(button) waits for a name")
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            let clear = field.buttons["Clear text"]
            if clear.exists {
                clear.tap()
            } else {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
        }
        field.typeText(name)
        // On the Duo's outer screen the keyboard can cover the buttons: Return is the preferred action.
        if alert.buttons[button].isHittable { alert.buttons[button].tap() } else { field.typeText("\n") }
    }

    private func profileButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["galleryProfile"]
    }

    func testAProfileKeepsItsOwnLoginsAndGoesAfterOneConfirmation() throws {
        let app = try launch()
        go(app, to: "/cookie?set")
        waitForPage(app, "Signed In")

        // One profile: New Profile is in the gallery's More menu; no switcher yet.
        let gallery = openGallery(app)
        XCTAssertFalse(profileButton(app).exists, "no switcher with Personal alone")
        app.buttons["galleryMenu"].tap()
        pick(app, "New Profile")
        name(app, "Work", confirm: "Create")

        // The new profile's empty list, under the switcher; its New Tab opens a Work tab.
        XCTAssertTrue(profileButton(app).waitForExistence(timeout: 3))
        XCTAssertEqual(profileButton(app).label, "Profile: Work")
        XCTAssertTrue(app.staticTexts["Tabs in Work show up here, with Work's own logins and history."].waitForExistence(timeout: 2))
        app.buttons["emptyNewTab"].tap()
        go(app, to: "/cookie")
        waitForPage(app, "Signed Out")

        // The switcher shows Personal's list; its card opens Personal's page, still signed in.
        _ = openGallery(app)
        XCTAssertEqual(profileButton(app).label, "Profile: Work")
        profileButton(app).tap()
        pick(app, "Personal")
        XCTAssertTrue(profileButton(app).waitForExistence(timeout: 2))
        XCTAssertEqual(profileButton(app).label, "Profile: Personal")
        let personalCard = gallery.descendants(matching: .any).matching(identifier: "tabCard").firstMatch
        XCTAssertTrue(personalCard.waitForExistence(timeout: 2))
        personalCard.tap()
        waitForPage(app, "Signed In")

        // Rename Work, then delete it: one confirmation that says what goes.
        _ = openGallery(app)
        profileButton(app).tap()
        pick(app, "Work")
        profileButton(app).tap()
        pick(app, "Rename Profile")
        name(app, "Office", confirm: "Rename")
        XCTAssertTrue(app.buttons["Profile: Office"].waitForExistence(timeout: 2))
        profileButton(app).tap()
        pick(app, "Delete Profile")
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(confirm.label.contains("Office"))
        let message = confirm.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "can't be undone")).firstMatch
        XCTAssertTrue(message.exists, "the confirmation says it can't be undone")
        XCTAssertTrue(message.label.contains("open tab"), "and that the open tab goes")
        confirm.buttons["Delete Profile"].tap()

        // Back to Personal alone: no switcher, Personal's card, the cookie still there.
        XCTAssertTrue(profileButton(app).waitForNonExistence(timeout: 3))
        personalCard.tap()
        waitForPage(app, "Signed In")
    }

    /// Screenshots of every profile state for design review; runs only with `PLAIN_CAPTURE=1`
    /// (see CaptureTests).
    func testCaptureProfiles() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        let app = try launch()
        go(app, to: "/a")
        waitForPage(app, "Page A")
        go(app, to: "/c")
        waitForPage(app, "Page C")
        _ = openGallery(app)
        pause(1.5)
        app.buttons["galleryMenu"].tap()
        pause(1)
        shot("p1-more-menu")
        pick(app, "New Profile")
        pause(1)
        shot("p2-new-profile")
        name(app, "Work", confirm: "Create")
        pause(1.5)
        shot("p3-empty-work")
        app.buttons["emptyNewTab"].tap()
        pause(1.5)
        shot("p4-work-start")
        go(app, to: "/cookie")
        waitForPage(app, "Signed Out")
        _ = openGallery(app)
        pause(1.5)
        shot("p5-work-gallery")
        profileButton(app).tap()
        pause(1)
        shot("p6-switcher-menu")
        pick(app, "Personal")
        pause(1.5)
        shot("p7-personal-list")
        profileButton(app).tap()
        pick(app, "Work")
        pause(1)
        profileButton(app).tap()
        pick(app, "Delete Profile")
        pause(1)
        shot("p8-delete-confirm")
        app.alerts.firstMatch.buttons["Delete Profile"].tap()
        pause(1.5)
        shot("p9-after-delete")
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        // The Duo's inner screen when it is open (the outer one is dark then): the largest screen.
        let shots = XCUIScreen.screens.map { $0.screenshot() }
        let screenshot = shots.max { $0.image.size.width * $0.image.size.height < $1.image.size.width * $1.image.size.height }
        let attachment = XCTAttachment(screenshot: screenshot ?? XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheWindowsProfileComesBackAfterARelaunch() throws {
        var app = try launch(["-PlainTestStore", "-PlainResetStore"])
        go(app, to: "/a")
        waitForPage(app, "Page A")
        _ = openGallery(app)
        app.buttons["galleryMenu"].tap()
        pick(app, "New Profile")
        name(app, "Work", confirm: "Create")
        XCTAssertTrue(app.buttons["emptyNewTab"].waitForExistence(timeout: 3))
        app.buttons["emptyNewTab"].tap()
        go(app, to: "/cookie?set")
        waitForPage(app, "Signed In")
        XCUIApplication.leaveForAnotherApp()
        app.terminate()

        app = try launch(["-PlainTestStore"])
        // The Work tab is back, signed in: its own store kept its cookie.
        waitForPage(app, "Signed In")
        _ = openGallery(app)
        XCTAssertEqual(profileButton(app).label, "Profile: Work")
        profileButton(app).tap()
        pick(app, "Personal")
        XCTAssertTrue(app.scrollViews["tabGallery"].descendants(matching: .any).matching(identifier: "tabCard").firstMatch
            .waitForExistence(timeout: 2))
    }
}
