#if canImport(UIKit)
import BrowserCore
import Foundation
import Testing
import UIKit
import WebKit
@testable import WebEngine

/// Desktop or mobile across the fold, on a real web view: the pane's size changes the way a fold
/// does, then the shell's `panesWillChange()` / `panesDidChange()`.
@Suite(.serialized) @MainActor
struct ContentModeTests {
    static let inner = CGSize(width: 951, height: 669)
    static let outer = CGSize(width: 382, height: 580)

    private func fold(_ harness: Harness, to size: CGSize) {
        harness.pool.panesWillChange()
        harness.container.frame.size = size
        harness.container.layoutIfNeeded()
        harness.pool.panesDidChange()
    }

    /// Set in the page: gone after a reload.
    private func mark(_ harness: Harness, _ tab: Tab) async throws {
        _ = try await harness.evaluate("window.plainMark = 1; 1", in: tab)
    }

    private func isMarked(_ harness: Harness, _ tab: Tab) async throws -> Bool {
        try await harness.evaluate("window.plainMark === 1", in: tab) as? Bool ?? false
    }

    private func platform(_ harness: Harness, _ tab: Tab) async throws -> String {
        try await harness.evaluate("navigator.platform", in: tab) as? String ?? ""
    }

    /// The paragraph at the top of the visible page.
    private func topParagraph(_ harness: Harness, _ tab: Tab) async throws -> String {
        try await harness.evaluate("""
            (() => { const el = document.elementFromPoint(innerWidth / 2, 2);
              return (el && el.textContent || '').slice(0, 9); })()
            """, in: tab) as? String ?? ""
    }

    private func settle(_ tab: Tab, _ harness: Harness) async throws {
        try await Task.sleep(for: FixedChoices.contentModeSettleDelay + .milliseconds(150))
        try await waitUntil("switch done", timeout: .seconds(10)) {
            !tab.isLoading && harness.pool.slot(for: tab)?.contentMode.running == nil
        }
    }

    /// Waits for `mode`, saying why the page kept its mode if it never comes.
    private func waitForMode(_ mode: ContentMode, _ tab: Tab, _ harness: Harness) async throws {
        do {
            try await waitUntil("\(mode)", timeout: .seconds(10)) { tab.contentMode == mode }
        } catch {
            report("kept: \(String(describing: harness.pool.slot(for: tab)?.contentMode.lastKept))")
            throw error
        }
    }

    @Test func foldSwitchesToMobileAndBackKeepingTheParagraph() async throws {
        let harness = try await Harness(paneSize: Self.inner)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/long", in: tab)
        #expect(tab.contentMode == .desktop)
        #expect(try await platform(harness, tab) == "MacIntel")
        _ = try await harness.evaluate("document.querySelectorAll('p')[59].scrollIntoView(); 1", in: tab)
        try await Task.sleep(for: .milliseconds(100))
        let before = try await topParagraph(harness, tab)
        #expect(before.hasPrefix("Para 60"))
        try await mark(harness, tab)

        fold(harness, to: Self.outer)
        // Nothing happens before the fold has settled.
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await isMarked(harness, tab))
        try await waitForMode(.mobile, tab, harness)
        // The page's picture covers the reload.
        let covered = harness.container.subviews.count > 1
        try await settle(tab, harness)
        #expect(covered)
        #expect(harness.container.subviews.count == 1, "the picture is gone")
        #expect(try await platform(harness, tab) != "MacIntel")
        #expect(!(try await isMarked(harness, tab)))
        let afterFold = try await topParagraph(harness, tab)
        report("top paragraph: before \(before), after fold \(afterFold)")
        #expect(afterFold.hasPrefix("Para 60") || afterFold.hasPrefix("Para 59") || afterFold.hasPrefix("Para 61"))
        #expect(tab.canGoBack == false, "a switch adds no history")

        fold(harness, to: Self.inner)
        try await waitForMode(.desktop, tab, harness)
        try await settle(tab, harness)
        #expect(try await platform(harness, tab) == "MacIntel")
        let afterUnfold = try await topParagraph(harness, tab)
        report("top paragraph after unfold \(afterUnfold)")
        #expect(afterUnfold.hasPrefix("Para 60") || afterUnfold.hasPrefix("Para 59") || afterUnfold.hasPrefix("Para 61"))
    }

    @Test func theProbeAnswers() async throws {
        let harness = try await Harness(paneSize: Self.inner)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/long", in: tab)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        do {
            let answer = try await webView.callAsyncJavaScript(
                ContentModeScripts.probe, arguments: ["topInset": 0.0], in: nil, contentWorld: UserScripts.world
            )
            report("probe: \(String(describing: answer))")
            let probe = try #require((answer as? [String: Any]).map(ContentModeProbe.init))
            #expect(probe.isDesktop == true)
            #expect(!probe.hasTypedInput)
            #expect(!probe.isEditing)
        } catch {
            report("probe error: \(error)")
            throw error
        }
    }

    @Test func typedTextKeepsTheModeUntilTheNextNavigation() async throws {
        let harness = try await Harness(paneSize: Self.inner)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/long", in: tab)
        _ = try await harness.evaluate("document.getElementById('field').value = 'typed'; 1", in: tab)
        try await mark(harness, tab)
        fold(harness, to: Self.outer)
        try await Task.sleep(for: FixedChoices.contentModeSettleDelay + .milliseconds(600))
        #expect(try await isMarked(harness, tab), "no reload")
        #expect(tab.contentMode == .desktop)
        #expect(try await harness.evaluate("document.getElementById('field').value", in: tab) as? String == "typed")
        // The next page gets the pane's mode.
        try await harness.load("/a", in: tab)
        #expect(tab.contentMode == .mobile)
    }

    @Test func aChangedChoiceAndAFocusedFieldKeepTheMode() async throws {
        let harness = try await Harness(paneSize: Self.inner)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/long", in: tab)
        _ = try await harness.evaluate("document.getElementById('pick').selectedIndex = 1; 1", in: tab)
        try await mark(harness, tab)
        fold(harness, to: Self.outer)
        try await Task.sleep(for: FixedChoices.contentModeSettleDelay + .milliseconds(600))
        #expect(try await isMarked(harness, tab))

        try await harness.load("/long", in: tab)
        #expect(tab.contentMode == .mobile)
        _ = try await harness.evaluate("document.getElementById('field').focus(); 1", in: tab)
        try await mark(harness, tab)
        fold(harness, to: Self.inner)
        try await Task.sleep(for: FixedChoices.contentModeSettleDelay + .milliseconds(600))
        #expect(try await isMarked(harness, tab))
        #expect(tab.contentMode == .mobile)
    }

    @Test func aFoldThenAQuickUnfoldDoesNothing() async throws {
        let harness = try await Harness(paneSize: Self.inner)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/long", in: tab)
        try await mark(harness, tab)
        fold(harness, to: Self.outer)
        try await Task.sleep(for: .milliseconds(150))
        fold(harness, to: Self.inner)
        try await Task.sleep(for: FixedChoices.contentModeSettleDelay + .milliseconds(600))
        #expect(try await isMarked(harness, tab))
        #expect(tab.contentMode == .desktop)
    }

    @Test func aSiteChoiceWinsOverTheFold() async throws {
        let harness = try await Harness(paneSize: Self.inner)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/long", in: tab)
        tab.setContentModeOverride(.mobile)
        try await waitUntil("mobile by choice") { tab.contentMode == .mobile && !tab.isLoading }
        try await mark(harness, tab)
        fold(harness, to: Self.outer)
        try await Task.sleep(for: FixedChoices.contentModeSettleDelay + .milliseconds(400))
        fold(harness, to: Self.inner)
        try await Task.sleep(for: FixedChoices.contentModeSettleDelay + .milliseconds(600))
        #expect(try await isMarked(harness, tab), "the choice holds open and closed")
        #expect(tab.contentMode == .mobile)
    }

    @Test func aBackgroundTabSwitchesWhenItComesOnScreen() async throws {
        let harness = try await Harness(paneSize: Self.inner)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/long", in: tab)
        #expect(tab.contentMode == .desktop)
        harness.pool.detach(tab)
        fold(harness, to: Self.outer)
        try await Task.sleep(for: FixedChoices.contentModeSettleDelay + .milliseconds(300))
        #expect(tab.contentMode == .desktop, "a hidden tab waits")
        harness.pool.attach(tab, to: harness.container)
        try await waitForMode(.mobile, tab, harness)
        try await settle(tab, harness)
        #expect(try await platform(harness, tab) != "MacIntel")
    }

    @Test func aPageFromTheBackForwardCacheIsCheckedToo() async throws {
        let harness = try await Harness(paneSize: Self.inner)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/long", in: tab)
        _ = try await harness.evaluate("document.getElementById('field').value = 'keep me'; 1", in: tab)
        fold(harness, to: Self.outer)
        try await Task.sleep(for: FixedChoices.contentModeSettleDelay + .milliseconds(300))
        #expect(tab.contentMode == .desktop)
        try await harness.load("/a", in: tab)
        #expect(tab.contentMode == .mobile)
        tab.goBack()
        try await waitUntil("back") { tab.title == "Long" && !tab.isLoading }
        try await Task.sleep(for: FixedChoices.contentModeAttachDelay + .milliseconds(500))
        let platformNow = try await platform(harness, tab)
        report("back to the long page: platform \(platformNow), tab mode \(tab.contentMode), kept \(String(describing: harness.pool.slot(for: tab)?.contentMode.lastKept))")
        // Whatever WebKit served (its cache or a fresh load), the tab says which mode shows.
        #expect((platformNow == "MacIntel") == (tab.contentMode == .desktop))
    }
}
#endif
