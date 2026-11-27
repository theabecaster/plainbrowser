import XCTest

/// Walks every page and state of the app for the clarity audit (docs/research/clarity-audit.md)
/// and keeps a screenshot of each. Not a test of behavior: it never fails on a missing control
/// (a state that cannot be reached is skipped and the walk goes on), and it skips itself unless
/// `PLAIN_CLARITY=1` reaches the runner (`TEST_RUNNER_PLAIN_CLARITY=1`).
///
/// Shots are attachments by default. With `PLAIN_CLARITY_DIR` set (a folder on the Mac that runs
/// the simulator) each shot is a request file there, `req/<name>.shot`, which a loop on the Mac
/// answers with `simctl io screenshot` and removes: the way to capture the Duo's inner screen,
/// which XCUITest's own screenshot never shows. `req/resize.cmd` asks the loop to move the app
/// into the resizable window that stands in for the inner screen (`PLAIN_CLARITY_INNER=1`).
/// `PLAIN_CLARITY_ARGS` adds launch arguments (space separated) to every launch.
@MainActor
final class ClarityCaptureTests: XCTestCase {
    private var server: TestServer!
    private let environment = ProcessInfo.processInfo.environment
    private var inner: Bool { environment["PLAIN_CLARITY_INNER"] == "1" }

    override func setUp() async throws {
        try XCTSkipUnless(environment["PLAIN_CLARITY"] == "1", "the clarity walk runs on request only")
        continueAfterFailure = true
        server = try TestServer()
        try server.start()
    }

    override func tearDown() async throws {
        server?.stop()
    }

    // MARK: Intro

    func test01Intro() {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainShowIntro"] + extraArguments
        app.launch()
        resizeIfInner()
        pause(0.4)
        shot("intro-00-splash")
        for step in 1...9 {
            pause(1.6)
            guard app.otherElements["intro"].exists || app.buttons["introSkip"].exists else { break }
            shot("intro-0\(step)")
            let next = ["introNext", "introLetsGo", "introNotNow"].map { app.buttons[$0] }.first { $0.exists && $0.isHittable }
            guard let next else { break }
            next.tap()
        }
        pause(1.5)
        shot("intro-end-search")
    }

    // MARK: Start screen

    func test02Start() {
        var app = launch()
        pause(1)
        shot("start-01-first-run-focus")
        closeField(app)
        shot("start-02-empty")
        openSheet(app)
        shot("start-03-sheet")
        dismissSheet(app)
        if tap(app.buttons["more"], or: nil) { dismissSheet(app) }
        app.terminate()

        app = launch(["-PlainSeedFavorites", "-PlainSeedHistory", "-PlainSeedArchive"])
        pause(1)
        shot("start-04-focus-seeded")
        closeField(app)
        shot("start-05-seeded")
        // A private empty tab, focused and at rest.
        if tapFirst(app, ["more.newPrivateTab", "menu.newPrivateTab"]) || tapLabel(app, "Private Tab") {
            pause(1.2)
            shot("start-06-private-focus")
            closeField(app)
            shot("start-07-private")
            openSheet(app)
            shot("start-08-private-sheet")
            dismissSheet(app)
        }
        app.terminate()

        app = launch(["-PlainPreviewEmptyTabCard"])
        closeField(app)
        shot("start-09-default-browser-card")
    }

    // MARK: A page and its states

    func test03Page() {
        let app = launch()
        go(app, "/a", "Page A")
        pause(1.5)
        shot("page-01-loaded")
        if app.buttons["tabs"].exists {
            app.buttons["tabs"].press(forDuration: 1)
            pause(0.8)
            shot("page-02-tabs-menu-one-tab")
            dismissMenu(app)
        }
        // Loading, and its sheet (Stop).
        type(app, "/slow")
        pause(1.2)
        shot("page-03-loading")
        openSheet(app)
        shot("page-04-loading-sheet")
        dismissSheet(app)
        pause(7)

        // A long page: the bar collapsing to the pill, then hidden.
        go(app, "/long", "Long Read")
        pause(1)
        shot("page-05-long")
        let web = app.webViews.firstMatch
        drag(web, from: 0.6, to: 0.48)
        pause(1)
        shot("page-06-collapsed-pill")
        web.swipeUp(velocity: .fast)
        pause(1.5)
        shot("page-07-chrome-hidden")
        web.swipeDown(velocity: .slow)
        pause(1.2)
        shot("page-08-revealed")

        // Find on Page.
        openSheet(app)
        if tap(app.buttons["menu.find"], or: nil) {
            pause(1.2)
            shot("page-09-find-open")
            app.typeText("Paragraph 4")
            pause(1.2)
            shot("page-10-find-typed")
            if !tapLabel(app, "Done") { tapLabel(app, "Close") }
            if app.buttons["sidePane.close"].exists { app.buttons["sidePane.close"].tap() }
            pause(1)
        } else {
            dismissSheet(app)
        }

        // Zoom.
        openSheet(app)
        if app.buttons["menu.zoomIn"].waitForExistence(timeout: 2) {
            app.buttons["menu.zoomIn"].tap()
            app.buttons["menu.zoomIn"].tap()
            pause(0.8)
            shot("page-11-sheet-zoomed")
            dismissSheet(app)
            shot("page-12-zoomed")
        } else {
            dismissSheet(app)
        }

        // Errors: a refused port, an unknown host, then the site going away under a page.
        type(app, "127.0.0.1:9/nothing", local: false)
        _ = app.otherElements["pageState"].waitForExistence(timeout: 20)
        pause(1)
        shot("page-13-error-refused")
        openSheet(app)
        shot("page-14-error-sheet")
        dismissSheet(app)
        type(app, "no-such-host.invalid", local: false)
        _ = app.otherElements["pageState"].waitForExistence(timeout: 20)
        pause(1.5)
        shot("page-15-error-no-host")
        go(app, "/b", "Page B")
        server.stop()
        openSheet(app)
        if tap(app.buttons["menu.reload"], or: nil) {
            _ = app.otherElements["pageState"].waitForExistence(timeout: 20)
            pause(1.5)
            shot("page-16-error-site-gone")
        } else {
            dismissSheet(app)
        }
    }

    // MARK: Page sheet, reader, translate, share

    func test04PageSheet() {
        var app = launch(["-PlainTestSummaries", "-PlainTestTranslator"])
        go(app, "/article", "The Quiet Page")
        pause(2)
        shot("sheet-01-article")
        openSheet(app)
        shot("sheet-02-article-sheet")
        if tap(app.buttons["menu.favorite"], or: nil) { pause(0.8) }
        if !app.buttons["menu.settings"].exists { openSheet(app) }
        if tap(app.buttons["menu.readLater"], or: nil) { pause(0.8) }
        if !app.buttons["menu.settings"].exists { openSheet(app) }
        shot("sheet-03-favorited-saved")
        if tap(app.buttons["menu.copyLink"], or: nil) {
            pause(0.4)
            shot("sheet-04-copied")
        }
        if !app.buttons["menu.settings"].exists { openSheet(app) }
        if tap(app.buttons["menu.siteSettings"], or: nil) {
            pause(1)
            shot("sheet-05-site-settings")
            dismissMenu(app)
        }
        if !app.buttons["menu.settings"].exists { openSheet(app) }
        if tap(app.buttons["pageSheet.address"], or: nil) {
            pause(1.2)
            shot("sheet-06-edit-address")
            closeField(app)
        }
        dismissSheet(app)

        // Reader, and the sheet over it.
        openSheet(app)
        if tap(app.buttons["menu.reader"], or: nil) {
            _ = app.webViews["readerView"].waitForExistence(timeout: 5)
            pause(1.5)
            shot("sheet-07-reader")
            openSheet(app)
            shot("sheet-08-reader-sheet")
            dismissSheet(app)
            if app.buttons["back"].exists, app.buttons["back"].isHittable { app.buttons["back"].tap() }
            pause(1)
        } else {
            dismissSheet(app)
        }

        // Share.
        openSheet(app)
        if tap(app.buttons["menu.share"], or: nil) {
            pause(2.5)
            shot("sheet-09-share")
            app.swipeUp()
            pause(1)
            shot("sheet-10-share-actions")
            if !tapLabel(app, "Close") { app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast) }
            pause(1)
        }
        app.terminate()

        // A foreign page: the one-time hint, Translate, the translated page, Show Original.
        app = launch(["-PlainTestTranslator"])
        go(app, "/french", nil)
        pause(2.5)
        shot("sheet-11-foreign-hint")
        pause(4)
        openSheet(app)
        shot("sheet-12-foreign-sheet")
        if tap(app.buttons["menu.translate"], or: nil) {
            _ = app.webViews.staticTexts["The Saturday market"].waitForExistence(timeout: 10)
            pause(1)
            shot("sheet-13-translated")
            openSheet(app)
            shot("sheet-14-translated-sheet")
        }
        dismissSheet(app)
    }

    // MARK: Address bar

    func test05Address() {
        let app = launch(["-PlainSeedFavorites", "-PlainSeedHistory", "-PlainTestSummaries"])
        go(app, "/a", "Page A")
        go(app, "/long", "Long Read")
        pause(1)
        tap(app.buttons["addressPill"], or: nil)
        pause(1.2)
        shot("address-01-focus-on-page")
        let field = app.textFields["searchField"]
        field.typeText("pla")
        pause(1.5)
        shot("address-02-typing")
        field.typeText("in browser tips")
        pause(1.5)
        shot("address-03-query-browse-for-me")
        clear(field)
        field.typeText("example.com")
        pause(1.2)
        shot("address-04-typing-address")
        clear(field)
        closeField(app)

        // The page's own address, with Copy in the field; then the copied link offered elsewhere.
        tap(app.buttons["addressPill"], or: nil)
        if tap(app.buttons["focus.currentPage"], or: nil) {
            pause(1)
            shot("address-05-edit-own-address")
            if tap(app.buttons["field.copy"], or: nil) { pause(0.6); shot("address-06-copied") }
        }
        closeField(app)
        go(app, "/b", "Page B")
        tap(app.buttons["addressPill"], or: nil)
        pause(1.2)
        shot("address-07-copied-link-offered")
        closeField(app)

        // The results page of the search engine shows the query in the pill.
        shot("address-08-resting")
    }

    // MARK: Tabs, gallery, private

    func test06Tabs() {
        let app = launch(["-PlainSeedArchive"])
        go(app, "/a", "Page A")
        guard app.buttons["tabs"].waitForExistence(timeout: 3) else { return }
        tap(app.buttons["tabs"], or: nil)
        pause(1.5)
        shot("tabs-01-gallery-one")
        tapFirst(app, ["galleryDone"])
        pause(1)
        for (path, heading) in [("/article", "The Quiet Page"), ("/long", "Long Read"), ("/c", "Page C")] {
            newTab(app)
            go(app, path, heading)
        }
        pause(1)
        shot("tabs-02-page-several")
        app.buttons["tabs"].press(forDuration: 1)
        pause(0.8)
        shot("tabs-03-tabs-menu")
        dismissMenu(app)
        // The bar swipe: to the neighbour, and past the last tab.
        let pill = app.buttons["addressPill"]
        if !inner {
            pill.swipeRight(velocity: .fast)
            pause(1.2)
            shot("tabs-04-after-bar-swipe")
            pill.swipeLeft(velocity: .fast)
            pause(1.2)
        }
        tap(app.buttons["tabs"], or: nil)
        pause(1.5)
        shot("tabs-05-gallery")
        if tap(app.buttons["galleryMenu"], or: nil) {
            pause(0.8)
            shot("tabs-06-gallery-menu")
            if tapLabel(app, "Archived Tabs") {
                pause(1.5)
                shot("tabs-06b-archive")
                done(app)
            } else {
                dismissMenu(app)
            }
        }
        let cards = app.scrollViews["tabGallery"].descendants(matching: .any).matching(identifier: "tabCard")
        if cards.firstMatch.exists {
            cards.firstMatch.press(forDuration: 1)
            pause(1)
            shot("tabs-07-card-menu")
            dismissMenu(app)
            pause(0.8)
            let card = cards.firstMatch
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -1.2)), withVelocity: .fast, thenHoldForDuration: 0)
            pause(0.9)
            shot("tabs-08-closed-toast")
        }
        if tap(app.buttons["galleryMenu"], or: nil) {
            if tapLabel(app, "Close All") {
                pause(1)
                shot("tabs-09-close-all-confirm")
                // A popover on a phone has no Cancel: a tap outside closes it.
                if !tapLabel(app, "Cancel") { dismissMenu(app) }
                pause(0.6)
            } else {
                dismissMenu(app)
            }
        }
        // Private.
        if tap(app.buttons["galleryPrivate"], or: nil) {
            pause(1.2)
            shot("tabs-10-private-empty")
            if tap(app.buttons["emptyNewTab"], or: nil) {
                pause(1)
                type(app, "/b")
                _ = app.webViews.staticTexts["Page B"].waitForExistence(timeout: 10)
                pause(1.5)
                shot("tabs-11-private-page")
                openSheet(app)
                shot("tabs-12-private-sheet")
                dismissSheet(app)
                tap(app.buttons["addressPill"], or: nil)
                pause(1.2)
                shot("tabs-13-private-focus")
                closeField(app)
                tap(app.buttons["tabs"], or: nil)
                pause(1.5)
                shot("tabs-14-private-gallery")
                tapFirst(app, ["galleryPrivate"])
                pause(1.2)
                shot("tabs-15-regular-list-from-private")
            }
        }
    }

    // MARK: Profiles

    func test07Profiles() {
        let app = launch()
        go(app, "/a", "Page A")
        guard app.buttons["tabs"].waitForExistence(timeout: 3) else { return }
        tap(app.buttons["tabs"], or: nil)
        pause(1.2)
        guard tap(app.buttons["galleryMenu"], or: nil) else { return }
        pause(0.8)
        shot("profiles-01-gallery-menu")
        guard tapLabel(app, "New Profile") else { return }
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        pause(0.8)
        shot("profiles-02-new-alert")
        alert.textFields.firstMatch.typeText("Work\n")
        pause(1.5)
        shot("profiles-03-empty-profile")
        if tap(app.buttons["galleryProfile"], or: nil) {
            pause(0.8)
            shot("profiles-04-switcher-menu")
            if tapLabel(app, "Rename Profile") {
                pause(1)
                shot("profiles-05-rename-alert")
                tapLabel(app, "Cancel")
                pause(0.6)
            } else {
                dismissMenu(app)
            }
        }
        if tap(app.buttons["emptyNewTab"], or: nil) {
            pause(1.2)
            shot("profiles-06-work-new-tab-focus")
            closeField(app)
            shot("profiles-07-work-start")
            go(app, "/b", "Page B")
            pause(1)
            shot("profiles-08-work-page")
            tap(app.buttons["tabs"], or: nil)
            pause(1.5)
            shot("profiles-09-work-gallery")
            if tap(app.buttons["galleryProfile"], or: nil) {
                if tapLabel(app, "Delete Profile") {
                    pause(1)
                    shot("profiles-10-delete-confirm")
                    tapLabel(app, "Cancel")
                } else {
                    dismissMenu(app)
                }
            }
        }
    }

    // MARK: Sheets

    func test08SheetsEmpty() {
        let app = launch()
        closeField(app)
        for (item, name) in [("menu.history", "history"), ("menu.readingList", "reading-list"), ("menu.editFavorites", "favorites")] {
            openSheet(app)
            if tap(app.buttons[item], or: nil) {
                pause(1.5)
                shot("sheets-empty-\(name)")
                if app.buttons["sidePane.close"].exists { app.buttons["sidePane.close"].tap() } else { done(app) }
                pause(1)
            } else {
                dismissSheet(app)
            }
        }
        openSheet(app)
        guard tap(app.buttons["menu.settings"], or: nil) else { return }
        pause(1.5)
        shot("settings-01-root")
        app.swipeUp()
        pause(0.8)
        shot("settings-02-root-scrolled")
        app.swipeDown()
        for (index, row) in ["Search Engine", "Tab Layout", "Archive Tabs", "Appearance", "App Icon", "About"].enumerated() {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", row)).firstMatch
            guard button.exists, button.isHittable, button.isEnabled else { continue }
            button.tap()
            pause(1.2)
            shot("settings-1\(index)-\(row.lowercased().replacingOccurrences(of: " ", with: "-"))")
            let back = app.otherElements["settingsSheet"].buttons["BackButton"]
            // A pushed screen goes back; a picker's menu closes with a tap on the sheet's paper.
            if back.exists { back.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap() }
            pause(0.9)
        }
        if tapLabel(app, "Clear History and Data") {
            pause(1)
            shot("settings-20-clear-confirm")
            tapLabel(app, "Cancel")
            pause(0.6)
        }
        done(app)
    }

    func test09SheetsFull() {
        let app = launch(["-PlainSeedFavorites", "-PlainSeedHistory", "-PlainSeedArchive"])
        go(app, "/article", "The Quiet Page")
        pause(1.5)
        openSheet(app)
        tap(app.buttons["menu.readLater"], or: nil)
        dismissSheet(app)
        go(app, "/files", nil)
        if app.webViews.links["Download notes"].waitForExistence(timeout: 10) {
            app.webViews.links["Download notes"].tap()
            pause(1.5)
            shot("sheets-01-download-toast")
            pause(4)
            openSheet(app)
            shot("sheets-02-sheet-with-downloads")
            if tap(app.buttons["menu.downloads"], or: nil) {
                pause(1.5)
                shot("sheets-03-downloads")
                let row = app.otherElements["downloadsSheet"].buttons.firstMatch
                if row.exists { row.press(forDuration: 1); pause(0.8); shot("sheets-04-download-menu"); dismissMenu(app) }
                done(app)
            } else {
                dismissSheet(app)
            }
        }
        for (item, name) in [("menu.history", "history"), ("menu.readingList", "reading-list"), ("menu.editFavorites", "favorites"), ("more.archivedTabs", "archive")] {
            openSheet(app)
            if tap(app.buttons[item], or: nil) {
                pause(1.5)
                shot("sheets-1-\(name)")
                let row = app.cells.firstMatch
                if row.exists, row.isHittable {
                    row.swipeLeft(velocity: .slow)
                    pause(0.8)
                    shot("sheets-2-\(name)-swipe")
                    row.swipeRight(velocity: .slow)
                    pause(0.6)
                }
                if name == "history" {
                    let search = app.searchFields.firstMatch
                    if search.exists || tapLabel(app, "Search") {
                        if search.waitForExistence(timeout: 2) {
                            search.tap()
                            search.typeText("zzzz")
                            pause(1.2)
                            shot("sheets-3-history-no-results")
                            if !tapLabel(app, "Cancel") { tapLabel(app, "Close") }
                            pause(0.8)
                        }
                    }
                    if tapLabel(app, "Clear") { pause(1); shot("sheets-4-history-clear"); if !tapLabel(app, "Cancel") { dismissMenu(app) } }
                }
                if app.buttons["sidePane.close"].exists { app.buttons["sidePane.close"].tap() } else { done(app) }
                pause(1)
            } else {
                dismissSheet(app)
            }
        }
    }

    // MARK: Summaries

    func test10Summaries() {
        var app = launch(["-PlainTestSummaries"])
        let field = app.textFields["searchField"]
        field.typeText("trail running shoes")
        if app.buttons["browseForMe"].waitForExistence(timeout: 3) {
            pause(0.6)
            shot("summary-01-row")
            app.buttons["browseForMe"].tap()
            pause(0.5)
            shot("summary-02-searching")
            _ = app.staticTexts["field-notes.example"].waitForExistence(timeout: 4)
            pause(0.5)
            shot("summary-03-reading")
            _ = app.staticTexts["The short answer"].waitForExistence(timeout: 15)
            shot("summary-04-writing")
            _ = app.buttons["summarySource.1"].waitForExistence(timeout: 20)
            pause(0.6)
            shot("summary-05-done")
            app.swipeUp()
            pause(0.8)
            shot("summary-06-sources")
            if app.buttons["summarySource.1"].exists {
                app.buttons["summarySource.1"].press(forDuration: 1)
                pause(0.8)
                shot("summary-07-source-menu")
                dismissMenu(app)
            }
            done(app)
            pause(1)
        }
        if field.exists, field.hasKeyboardFocus { clear(field) }
        go(app, "/article", "The Quiet Page")
        pause(1.5)
        openSheet(app)
        if tap(app.buttons["menu.summarize"], or: nil) {
            pause(0.5)
            shot("summary-08-page-start")
            _ = app.staticTexts["The short answer"].waitForExistence(timeout: 15)
            pause(2.5)
            shot("summary-09-page-done")
            done(app)
        } else {
            dismissSheet(app)
        }
        app.terminate()

        app = launch(["-PlainAIUnavailable"])
        app.textFields["searchField"].typeText("trail running shoes")
        pause(1.5)
        shot("summary-10-unavailable-typing")
        clear(app.textFields["searchField"])
        go(app, "/article", "The Quiet Page")
        pause(1.5)
        openSheet(app)
        shot("summary-11-unavailable-sheet")
        dismissSheet(app)
    }

    // MARK: Launch

    func test11Launch() {
        var app = launch(["-PlainTestStore", "-PlainResetStore"])
        go(app, "/a", "Page A")
        newTab(app)
        go(app, "/launch", "Launch Page")
        pause(1)
        XCUIApplication.leaveForAnotherApp()
        pause(1.5)
        app.terminate()

        app = launch(["-PlainTestStore"], wait: false)
        shot("launch-01-last-tab-first-screen")
        pause(3)
        shot("launch-02-last-tab-settled")
        XCUIApplication.leaveForAnotherApp()
        pause(1.5)
        app.terminate()

        app = launch(["-PlainTestStore", "-PlainAwayOffset", "18000"], wait: false)
        pause(0.6)
        shot("launch-03-after-4h-search-over-tab")
        pause(1.5)
        if app.otherElements["searchSheet"].exists { app.otherElements["searchSheet"].swipeDown() }
        pause(1.5)
        shot("launch-04-after-4h-back-on-tab")
        // No tabs left: close both, relaunch.
        for _ in 0..<2 where app.buttons["tabs"].exists {
            app.buttons["tabs"].press(forDuration: 1)
            if !tap(app.buttons["menu.closeTab"], or: nil) { dismissMenu(app) }
            pause(1.2)
        }
        shot("launch-05-all-closed")
        XCUIApplication.leaveForAnotherApp()
        pause(1.5)
        app.terminate()
        app = launch(["-PlainTestStore"], wait: false)
        pause(1.5)
        shot("launch-06-no-tabs")
    }

    // MARK: Links, prompts, dark pages, forms

    func test12Misc() {
        var app = launch()
        go(app, "/a", "Page A")
        let link = app.webViews.links["Go to B"]
        if link.waitForExistence(timeout: 5) {
            link.press(forDuration: 1.2)
            pause(1.5)
            shot("misc-01-link-menu")
            if tapLabel(app, "Open in Background") {
                pause(1)
                shot("misc-02-opened-in-background-toast")
            } else {
                dismissMenu(app)
            }
        }
        pause(3)
        go(app, "/consent", nil)
        pause(3)
        shot("misc-03-cookie-banner-answered")
        go(app, "/login", nil)
        pause(1)
        let input = app.webViews.textFields.firstMatch
        if input.waitForExistence(timeout: 5) {
            input.tap()
            pause(1.5)
            shot("misc-04-form-keyboard")
            tapLabel(app, "Done")
        }
        go(app, "/passkey", nil)
        if app.webViews.buttons["Sign In with a Passkey"].waitForExistence(timeout: 5) {
            app.webViews.buttons["Sign In with a Passkey"].tap()
            pause(1.5)
            shot("misc-05-passkey-toast")
        }
        go(app, "/location", nil)
        pause(2.5)
        shot("misc-06-location-prompt")
        for label in ["Don’t Allow", "Don't Allow", "Deny"] where tapLabel(app, label) { break }
        pause(1)
        shot("misc-07-location-denied")

        // Dark: the app dark, a light site darkened, the switch for the site, then off.
        openSheet(app)
        if tap(app.buttons["menu.settings"], or: nil) {
            pause(1)
            let appearance = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Appearance'")).firstMatch
            if appearance.exists {
                appearance.tap()
                pause(0.8)
                tapLabel(app, "Dark")
                pause(1)
                shot("misc-08-appearance-dark")
                let back = app.otherElements["settingsSheet"].buttons["BackButton"]
                if back.exists { back.tap() }
                pause(0.6)
            }
            done(app)
            pause(1)
            go(app, "/light-site", nil)
            pause(2.5)
            shot("misc-09-dark-pages-on")
            openSheet(app)
            shot("misc-10-dark-sheet")
            if tap(app.buttons["menu.siteSettings"], or: nil) {
                pause(1)
                shot("misc-11-dark-site-settings")
                if tapLabel(app, "Turn Off Dark Pages") || tap(app.buttons["menu.darkPages"], or: nil) {
                    pause(1.5)
                    shot("misc-12-dark-pages-off")
                } else {
                    dismissMenu(app)
                }
            } else if tap(app.buttons["menu.darkPages"], or: nil) {
                pause(1.5)
                shot("misc-12-dark-pages-off")
            } else {
                dismissSheet(app)
            }
        }
        app.terminate()

        app = launch(["-PlainPreviewPermissionPrompt"])
        go(app, "/b", nil)
        if app.alerts.firstMatch.waitForExistence(timeout: 8) {
            pause(0.8)
            shot("misc-13-camera-prompt")
            tapLabel(app, "Don’t Allow")
        }
    }

    // MARK: The Duo's inner screen

    func test13Inner() throws {
        try XCTSkipUnless(inner, "inner screen only")
        var app = launch(["-PlainTabLayout", "above"])
        go(app, "/article", "The Quiet Page")
        pause(1)
        shot("inner-01-one-tab")
        newTab(app)
        go(app, "/long", "Long Read")
        newTab(app)
        go(app, "/a", "Page A")
        pause(1)
        shot("inner-02-strip")
        tapFirst(app, ["stripTab"])
        pause(1)
        openSheet(app)
        shot("inner-03-sheet")
        if tap(app.buttons["menu.sidePane"], or: nil) {
            pause(1.5)
            shot("inner-04-side-pane")
            for (index, section) in ["Reader", "Find", "History"].enumerated() {
                if tapLabel(app, section) { pause(1.5); shot("inner-05-\(index)-pane-\(section.lowercased())") }
            }
            tapFirst(app, ["sidePane.close"])
            pause(1)
        } else {
            dismissSheet(app)
        }
        openSheet(app)
        if tap(app.buttons["menu.otherPane"], or: nil) {
            pause(2)
            shot("inner-06-split")
            openSheet(app)
            shot("inner-07-split-sheet")
            dismissSheet(app)
        } else {
            dismissSheet(app)
        }
        if app.buttons["tabs"].firstMatch.exists {
            app.buttons["tabs"].firstMatch.press(forDuration: 1)
            pause(0.8)
            shot("inner-08-tabs-menu")
            dismissMenu(app)
        }
        app.terminate()
        for layout in ["left", "right"] {
            app = launch(["-PlainTabLayout", layout])
            go(app, "/article", "The Quiet Page")
            newTab(app)
            go(app, "/long", "Long Read")
            pause(1)
            shot("inner-09-tabs-\(layout)")
            app.terminate()
        }
    }

    // MARK: Driving

    private var extraArguments: [String] {
        (environment["PLAIN_CLARITY_ARGS"] ?? "").split(separator: " ").map(String.init) + (inner ? ["-PlainIgnoreOcclusions"] : [])
    }

    private func launch(_ arguments: [String] = [], wait: Bool = true) -> XCUIApplication {
        let app = XCUIApplication.isolated()
        app.launchArguments += arguments + extraArguments
        app.launch()
        resizeIfInner()
        if wait {
            _ = app.waitForFirstScreen(timeout: 15)
            _ = app.waitForStoreReady(timeout: 15)
            // A fresh simulator's keyboard opens on its slide-to-type tip, over the keys.
            let tip = app.buttons["Continue"]
            if tip.waitForExistence(timeout: 1) { tip.tap() }
        }
        return app
    }

    private func resizeIfInner() {
        guard inner else { return }
        request("resize.cmd")
        pause(1)
    }

    private func type(_ app: XCUIApplication, _ path: String, local: Bool = true) {
        let field = app.textFields["searchField"]
        if !(field.exists && field.hasKeyboardFocus) {
            let pill = app.buttons["addressPill"].firstMatch
            guard pill.waitForExistence(timeout: 5) else { return }
            pill.tap()
            guard field.waitForExistence(timeout: 3) else { return }
        }
        field.typeText((local ? server.address(path) : path) + "\n")
    }

    private func go(_ app: XCUIApplication, _ path: String, _ heading: String?) {
        type(app, path)
        if let heading {
            _ = app.webViews.staticTexts[heading].waitForExistence(timeout: 20)
        } else {
            _ = app.webViews.firstMatch.waitForExistence(timeout: 10)
            pause(1.5)
        }
    }

    private func newTab(_ app: XCUIApplication) {
        let tabs = app.buttons["tabs"].firstMatch
        guard tabs.waitForExistence(timeout: 3) else { return }
        tabs.press(forDuration: 1)
        if !tap(app.buttons["menu.newTab"], or: nil) { dismissMenu(app) }
        pause(0.8)
    }

    /// The page sheet: More, or a long press on the pill where More is not in reach.
    private func openSheet(_ app: XCUIApplication) {
        let more = app.buttons["more"].firstMatch
        if more.waitForExistence(timeout: 2), more.isHittable {
            more.tap()
        } else if app.buttons["addressPill"].firstMatch.exists {
            app.buttons["addressPill"].firstMatch.press(forDuration: 0.9)
        }
        _ = app.buttons["menu.settings"].waitForExistence(timeout: 3)
        pause(0.8)
    }

    private func dismissSheet(_ app: XCUIApplication) {
        guard app.buttons["menu.settings"].exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: inner ? 0.2 : 0.5, dy: inner ? 0.8 : 0.07)).tap()
        _ = app.buttons["menu.settings"].waitForNonExistence(timeout: 3)
        pause(0.6)
    }

    private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
        pause(0.8)
    }

    private func closeField(_ app: XCUIApplication) {
        let field = app.textFields["searchField"]
        guard field.exists, field.hasKeyboardFocus else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        pause(1.2)
        if field.exists, field.hasKeyboardFocus {
            app.swipeDown(velocity: .fast)
            pause(1.2)
        }
    }

    private func done(_ app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        if done.exists, done.isHittable { done.tap() } else { app.swipeDown(velocity: .fast) }
        pause(1)
    }

    private func clear(_ field: XCUIElement) {
        guard field.exists, let text = field.value as? String, !text.isEmpty, text != field.placeholderValue else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    }

    private func drag(_ element: XCUIElement, from: CGFloat, to: CGFloat) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            .press(forDuration: 0.05, thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)), withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    @discardableResult
    private func tap(_ element: XCUIElement, or fallback: XCUIElement?) -> Bool {
        if element.waitForExistence(timeout: 1.5), element.isHittable, element.isEnabled {
            element.tap()
            return true
        }
        if let fallback, fallback.exists, fallback.isHittable {
            fallback.tap()
            return true
        }
        return false
    }

    @discardableResult
    private func tapFirst(_ app: XCUIApplication, _ identifiers: [String]) -> Bool {
        for identifier in identifiers {
            let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            if element.exists, element.isHittable {
                element.tap()
                return true
            }
        }
        return false
    }

    @discardableResult
    private func tapLabel(_ app: XCUIApplication, _ label: String) -> Bool {
        let element = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        guard element.waitForExistence(timeout: 1.5), element.isHittable else { return false }
        element.tap()
        return true
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        if environment["PLAIN_CLARITY_DIR"] != nil {
            request(name + ".shot")
        } else {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Leaves a request for the loop on the Mac and waits until it is answered (the file goes).
    private func request(_ name: String) {
        guard let folder = environment["PLAIN_CLARITY_DIR"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("req").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
        let deadline = Date().addingTimeInterval(15)
        while FileManager.default.fileExists(atPath: url.path), Date() < deadline { pause(0.1) }
        try? FileManager.default.removeItem(at: url)
    }
}
