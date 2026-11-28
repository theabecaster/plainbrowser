import XCTest

/// Reload in the resting pill (docs/decisions.md, "Reload in the pill"): a tap reloads, Stop (×)
/// takes its place while the page loads, and the long press offers Reload Without Cache, which asks
/// the site for everything again. It shows only where pull to refresh works (state rules §3).
/// Pages come from the local TestServer (`/fresh` counts its loads and says the request's cache
/// headers).
@MainActor
final class PillReloadTests: XCTestCase {
    private var server: TestServer!

    private func launch(_ arguments: [String] = []) throws -> XCUIApplication {
        continueAfterFailure = false
        server = try TestServer()
        try server.start()
        addTeardownBlock { [server] in server?.stop() }
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainInMemoryStore"] + arguments
        app.launch()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        return app
    }

    private func go(_ app: XCUIApplication, to address: String) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 2))
        }
        field.typeText(address + "\n")
    }

    private func waitForPage(_ app: XCUIApplication, _ heading: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.webViews.staticTexts[heading].waitForExistence(timeout: 10), "page \"\(heading)\" did not show",
            file: file, line: line
        )
    }

    /// The page's cache line ("Cache max-age=0", "Cache no-cache no-cache", "Cache none").
    private func cacheLine(_ app: XCUIApplication) -> String {
        let line = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cache '")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        return line.label
    }

    /// How often `/fresh`'s picture was fetched before the page on screen ("Picture N").
    private func pictureCount(_ app: XCUIApplication) -> Int {
        let line = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Picture '")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        return Int(line.label.dropFirst("Picture ".count)) ?? -1
    }

    /// Closes the search field: the sheet's handle, or Cancel under a top bar.
    private func closeSearch(_ app: XCUIApplication) {
        let grabber = app.buttons["search.close"]
        let cancel = app.buttons["search.cancel"]
        if grabber.exists, grabber.isHittable {
            grabber.tap()
        } else if cancel.exists, cancel.isHittable {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        }
        XCTAssertTrue(app.buttons["addressPill"].waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.6)
    }

    func testTheGlyphReloadsAndItsLongPressReloadsWithoutCache() throws {
        let app = try launch()
        XCTAssertFalse(app.buttons["pill.reload"].exists, "nothing to reload on the start screen")
        go(app, to: server.address("/fresh"))
        waitForPage(app, "Fresh 1")

        let reload = app.buttons["pill.reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 3), "a loaded page has Reload in the pill")
        XCTAssertEqual(reload.label, "Reload")
        XCTAssertFalse(app.buttons["pill.stop"].exists)
        reload.tap()
        waitForPage(app, "Fresh 2")
        XCTAssertFalse(cacheLine(app).contains("no-cache"), "a plain reload revalidates: \(cacheLine(app))")
        let field = app.textFields["searchField"]
        XCTAssertFalse(field.exists && field.hasKeyboardFocus, "the glyph's tap is not the pill's search")

        // The long press: one choice, Reload Without Cache, and not the page sheet.
        XCTAssertTrue(reload.waitForExistence(timeout: 3))
        reload.press(forDuration: 1.0)
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reload Without Cache'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "the long press offers Reload Without Cache")
        XCTAssertFalse(app.buttons["menu.copyLink"].exists, "the hold on the glyph is not the pill's page sheet")
        item.tap()
        waitForPage(app, "Fresh 3")
        XCTAssertTrue(cacheLine(app).contains("no-cache"), "a reload from the origin asks with no-cache: \(cacheLine(app))")
        // Its picture (cacheable for an hour) was fetched again: the next load counts it.
        let picturesBefore = pictureCount(app)
        reload.tap()
        waitForPage(app, "Fresh 4")
        XCTAssertGreaterThan(pictureCount(app), picturesBefore, "Reload Without Cache fetches the page's files again")

        // The rest of the pill is unchanged: its long press is still the page sheet.
        app.buttons["addressPill"].press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["menu.copyLink"].waitForExistence(timeout: 3), "the pill's long press is the page sheet")
    }

    func testStopTakesReloadsPlaceWhileThePageLoads() throws {
        let app = try launch()
        go(app, to: server.address("/a"))
        waitForPage(app, "Page A")
        XCTAssertTrue(app.buttons["pill.reload"].waitForExistence(timeout: 3))

        // A search from a page opens a new tab, which loads the slow page.
        go(app, to: server.address("/slow"))
        let stop = app.buttons["pill.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 4), "Stop shows while the page loads")
        XCTAssertEqual(stop.label, "Stop")
        XCTAssertFalse(app.buttons["pill.reload"].exists, "Reload and Stop share one place")
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 4), "a stopped load no longer shows Stop")
        XCTAssertFalse(app.webViews.staticTexts["Slow Page"].exists, "stopped before the page answered")
    }

    func testNoGlyphWhereItsPageButtonOrTheReaderOwnsIt() throws {
        let app = try launch()
        // An error page: Try Again is the one way to load it again.
        let closed = try TestServer()
        try closed.start()
        let port = closed.port
        closed.stop()
        go(app, to: "http://127.0.0.1:\(port)/nothing")
        XCTAssertTrue(app.staticTexts["The site refused the connection."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["pill.reload"].exists, "Try Again owns an error page")
        XCTAssertFalse(app.buttons["pill.stop"].exists)

        // The reader: the article is what the page has.
        go(app, to: server.address("/article"))
        waitForPage(app, "The Quiet Page")
        XCTAssertTrue(app.buttons["pill.reload"].waitForExistence(timeout: 3))
        var opened = false
        for _ in 0..<2 where !opened {
            app.buttons["more"].tap()
            let show = app.buttons["menu.reader"]
            if show.waitForExistence(timeout: 3) {
                show.tap()
                opened = true
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        XCTAssertTrue(app.webViews["readerView"].waitForExistence(timeout: 5), "the reader did not open")
        XCTAssertTrue(app.buttons["pill.reload"].waitForNonExistence(timeout: 3), "no reload in the reader")

        // The open field: the pill is the field, nothing else.
        app.buttons["back"].tap()
        XCTAssertTrue(app.buttons["pill.reload"].waitForExistence(timeout: 5), "back on the page, Reload is back")
        app.buttons["addressPill"].tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["pill.reload"].isHittable, "editing hides it")
        closeSearch(app)
        XCTAssertTrue(app.buttons["pill.reload"].waitForExistence(timeout: 3))
    }

    /// Reading, the collapsed pill is the host alone: no Reload, and a tap brings the bar back.
    func testTheCollapsedPillHasNoReload() throws {
        let app = try launch()
        go(app, to: server.address("/long"))
        waitForPage(app, "Long Read")
        let reload = app.buttons["pill.reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 3))
        let place = reload.frame
        app.webViews.firstMatch.swipeUp(velocity: .slow)
        XCTAssertTrue(reload.waitForNonExistence(timeout: 3), "the collapsed pill has no Reload")
        // A tap on the collapsed pill brings the whole bar back, Reload with it.
        app.buttons["addressPill"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(reload.waitForExistence(timeout: 3), "the bar came back with Reload")
        XCTAssertEqual(reload.frame.midX, place.midX, accuracy: 1, "in the same place")
        let field = app.textFields["searchField"]
        XCTAssertFalse(field.exists && field.hasKeyboardFocus, "the tap only brought the bar back")
    }

    /// With Page Appearance at the leading end, VoiceOver reads left to right: the glyph, the
    /// address, then Reload; both glyphs show, the host between them.
    func testVoiceOverReadsPageAppearanceThenAddressThenReload() throws {
        let app = try launch()
        closeSearch(app)
        // Plain dark, then a light-only page offers dark pages; taking it shows the glyph.
        app.buttons["more"].tap()
        let settings = app.buttons["menu.settings"]
        if !settings.waitForExistence(timeout: 2) { app.buttons["more"].tap() }
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let row = app.buttons["settings.appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: row)], timeout: 5), .completed)
        row.tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 2))
        app.buttons["Dark"].tap()
        app.buttons["Done"].tap()
        go(app, to: server.address("/light-site"))
        let suggestion = app.buttons["darkPagesSuggestion.turnOn"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 12), "a light page in dark colors suggests dark pages")
        suggestion.tap()
        let appearance = app.buttons["pill.pageAppearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        let reload = app.buttons["pill.reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 3), "both glyphs show")
        let address = app.buttons["addressPill"]
        XCTAssertTrue(address.exists)
        XCTAssertLessThan(appearance.frame.maxX, reload.frame.minX)

        let group = app.descendants(matching: .any)["addressPillGroup"]
        XCTAssertTrue(group.waitForExistence(timeout: 3), app.debugDescription)
        let order = group.children(matching: .any).allElementsBoundByIndex.map(\.identifier)
            .filter { ["pill.pageAppearance", "addressPill", "pill.reload"].contains($0) }
        XCTAssertEqual(order, ["pill.pageAppearance", "addressPill", "pill.reload"], "VoiceOver's order: \(order)")
    }

    func testPrivateTabsKeepIt() throws {
        let app = try launch()
        closeSearch(app)
        let more = app.buttons["more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        let privateTab = app.buttons["more.newPrivateTab"]
        XCTAssertTrue(privateTab.waitForExistence(timeout: 3))
        privateTab.tap()
        go(app, to: server.address("/fresh"))
        waitForPage(app, "Fresh 1")
        let reload = app.buttons["pill.reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 3), "private pages reload the same way")
        reload.tap()
        waitForPage(app, "Fresh 2")
    }
}

/// Screenshots of the pill's Reload for design review: the start screen, a loaded page, loading
/// (Stop and the progress), the long press's menu, the collapsed bar, an error page, the reader
/// and the page sheet under More. Not a test of behavior: it skips itself unless `PLAIN_CAPTURE=1`
/// reaches the runner (`TEST_RUNNER_PLAIN_CAPTURE=1`); `PLAIN_CAPTURE_TAG` names the shots.
@MainActor
final class PillReloadCaptureTests: XCTestCase {
    private var tag = ""

    func testCapturePillReload() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLAIN_CAPTURE"] == "1", "capture runs on request only")
        continueAfterFailure = true
        tag = environment["PLAIN_CAPTURE_TAG"] ?? "reload"
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        app.launch()
        if environment["PLAIN_MATRIX_ORIENTATION"] == "landscape" { XCUIDevice.shared.orientation = .landscapeLeft }
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        pause(1)
        closeSearch(app)
        shot("1-start")

        open(app, server.address("/long"))
        _ = app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 15)
        pause(1.5)
        shot("2-loaded")

        // The long press's menu.
        let reload = app.buttons["pill.reload"]
        if reload.waitForExistence(timeout: 3) {
            reload.press(forDuration: 1.0)
            pause(0.8)
            shot("3-hold-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            pause(0.8)
        }

        // Reading: the bar collapses to the host alone.
        app.webViews.firstMatch.swipeUp(velocity: .slow)
        pause(1.5)
        shot("4-collapsed")
        app.webViews.firstMatch.swipeDown(velocity: .slow)
        pause(1.2)

        // More's page sheet: the ellipsis and Settings.
        let more = app.buttons["more"]
        if more.waitForExistence(timeout: 2), more.isHittable {
            more.tap()
            pause(1.2)
            shot("5-more-sheet")
            dismissSheet(app)
        }

        // Loading: Stop in Reload's place, the progress along the bottom.
        open(app, server.address("/slow"))
        pause(1.5)
        shot("6-loading")
        if app.buttons["pill.stop"].exists { app.buttons["pill.stop"].tap() }
        pause(1)

        // An error page: Try Again, no glyph.
        let closed = try TestServer()
        try closed.start()
        let port = closed.port
        closed.stop()
        open(app, "http://127.0.0.1:\(port)/nothing")
        _ = app.staticTexts["The site refused the connection."].waitForExistence(timeout: 8)
        pause(1)
        shot("7-error")

        // The reader: no glyph.
        open(app, server.address("/article"))
        _ = app.webViews.staticTexts["The Quiet Page"].waitForExistence(timeout: 10)
        pause(1.5)
        for _ in 0..<2 {
            guard more.waitForExistence(timeout: 2) else { break }
            more.tap()
            let show = app.buttons["menu.reader"]
            if show.waitForExistence(timeout: 3) {
                show.tap()
                break
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            pause(1)
        }
        _ = app.webViews["readerView"].waitForExistence(timeout: 5)
        pause(1.5)
        shot("8-reader")
        app.buttons["back"].tap()
        pause(1)

        // Plain dark, a light-only page offers dark pages: taken, Page Appearance shows at the
        // leading end beside Reload.
        if more.waitForExistence(timeout: 2) {
            more.tap()
            let settings = app.buttons["menu.settings"]
            if !settings.waitForExistence(timeout: 2) { more.tap() }
            if settings.waitForExistence(timeout: 3) {
                settings.tap()
                let row = app.buttons["settings.appearance"]
                if row.waitForExistence(timeout: 3) {
                    pause(2)
                    row.tap()
                    if app.buttons["Dark"].waitForExistence(timeout: 2) { app.buttons["Dark"].tap() }
                }
                if app.buttons["Done"].waitForExistence(timeout: 2) { app.buttons["Done"].tap() }
                pause(1)
            }
        }
        open(app, server.address("/light-site"))
        _ = app.webViews.staticTexts["Light Only"].waitForExistence(timeout: 15)
        let suggestion = app.buttons["darkPagesSuggestion.turnOn"]
        if suggestion.waitForExistence(timeout: 12) {
            suggestion.tap()
            _ = app.buttons["pill.pageAppearance"].waitForExistence(timeout: 5)
        }
        pause(1.5)
        shot("10-two-glyphs")

        // A long host (nip.io answers with the address in its name, here the Mac's loopback; it
        // needs the network): how it centres and truncates between the glyphs.
        open(app, "http://www.a-rather-long-host-name-for-plain.127.0.0.1.nip.io:\(server.port)/light-site")
        _ = app.webViews.staticTexts["Light Only"].waitForExistence(timeout: 15)
        pause(2)
        shot("11-long-host")

        // Private.
        if more.waitForExistence(timeout: 2) {
            more.tap()
            let privateTab = app.buttons["more.newPrivateTab"]
            if privateTab.waitForExistence(timeout: 3) {
                privateTab.tap()
                open(app, server.address("/a"))
                _ = app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10)
                pause(1.5)
                shot("9-private")
            }
        }
    }

    private func open(_ app: XCUIApplication, _ address: String) {
        let field = app.textFields["searchField"]
        // A collapsed bar takes the first tap to come back; the next opens the field.
        for _ in 0..<3 where !(field.exists && field.hasKeyboardFocus) {
            app.buttons["addressPill"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = field.waitForExistence(timeout: 2)
            pause(0.6)
        }
        if !field.exists {
            shot("debug-no-field")
            print("HIERARCHY\n" + app.debugDescription)
        }
        field.typeText(address + "\n")
    }

    private func closeSearch(_ app: XCUIApplication) {
        let grabber = app.buttons["search.close"]
        let cancel = app.buttons["search.cancel"]
        if grabber.exists, grabber.isHittable {
            grabber.tap()
        } else if cancel.exists, cancel.isHittable {
            cancel.tap()
        }
        pause(1)
    }

    /// Closes the page sheet (or popover) with taps above it until it is gone.
    private func dismissSheet(_ app: XCUIApplication) {
        for _ in 0..<3 where app.buttons["menu.settings"].exists {
            // The dimmed page above the sheet, clear of the status bar (whose tap scrolls the page).
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            _ = app.buttons["menu.settings"].waitForNonExistence(timeout: 2)
        }
        pause(0.6)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        for screen in XCUIScreen.screens {
            let image = screen.screenshot()
            let size = image.image.size
            let suffix = XCUIScreen.screens.count > 1 ? "-\(Int(size.width))x\(Int(size.height))" : ""
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = "\(tag)-\(name)\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
