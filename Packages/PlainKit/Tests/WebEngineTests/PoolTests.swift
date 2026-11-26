#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import WebKit
@testable import WebEngine

@Suite(.serialized) @MainActor
struct PoolTests {
    @Test func tabFollowsNavigation() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        var progress: [Double] = []
        tab.onProgress = { progress.append($0) }
        harness.pool.attach(tab, to: harness.container)
        #expect(tab.tier == .live)

        try await harness.load("/a", in: tab)
        try await waitUntil("title A") { tab.title == "A" }
        #expect(tab.canGoBack == false)
        #expect(tab.security == .notSecure)
        #expect(progress.last == 1)

        try await harness.load("/b", in: tab)
        try await waitUntil("title B") { tab.title == "B" }
        #expect(tab.canGoBack)
        tab.goBack()
        try await waitUntil("back to A") { tab.title == "A" && tab.canGoForward }
    }

    @Test func warmWebViewGoesToFirstTabWithoutABlankBackItem() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        harness.pool.warmUp()
        try await Task.sleep(for: .milliseconds(300))
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        report("warm view back list after first load: \(webView.backForwardList.backList.map { $0.url.absoluteString })")
        #expect(tab.canGoBack == false)
    }

    @Test func everyWebViewHasItsOwnControllerAndSafariUserAgent() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let first = harness.pool.makeTab()
        let second = harness.pool.makeTab()
        harness.pool.attach(first, to: harness.container)
        try await harness.load("/ua", in: first)
        try await harness.load("/ua", in: second)
        let a = try #require(harness.pool.existingWebView(for: first))
        let b = try #require(harness.pool.existingWebView(for: second))
        #expect(a.configuration.userContentController !== b.configuration.userContentController)
        #expect(a.configuration.websiteDataStore === b.configuration.websiteDataStore)
        let agent = try #require(try await harness.evaluate("navigator.userAgent", in: first) as? String)
        report("mobile user agent: \(agent)")
        #expect(agent.contains("Safari/604.1"))
        #expect(agent.contains("iPhone"))
    }

    @Test func desktopModeComesFromThePaneSizeAtNavigationStart() async throws {
        let harness = try await Harness(paneSize: CGSize(width: 951, height: 669))
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/ua", in: tab)
        #expect(tab.contentMode == .desktop)
        let agent = try #require(try await harness.evaluate("navigator.userAgent", in: tab) as? String)
        report("desktop user agent: \(agent)")
        #expect(agent.contains("Macintosh"))
        #expect(!agent.contains("Mobile"))

        // Resizing never switches; the next navigation decides again.
        harness.container.frame.size = CGSize(width: 382, height: 580)
        #expect(tab.contentMode == .desktop)
        try await harness.load("/a", in: tab)
        #expect(tab.contentMode == .mobile)

        // The page menu's override is remembered per site.
        tab.setContentModeOverride(.desktop)
        try await waitUntil("desktop reload") { tab.contentMode == .desktop && !tab.isLoading }
    }

    @Test func preconnectHintIsAddedOnTouch() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/links", in: tab)
        _ = try await harness.evaluate("""
            document.getElementById('far').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); 0
            """, in: tab)
        let hint = try await harness.evaluate(
            "document.querySelector('link[rel=preconnect]')?.href ?? ''", in: tab
        ) as? String
        #expect(hint == "https://example.org/")
    }

    @Test func customSchemeAsksTheShell() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/links", in: tab)
        _ = try await harness.evaluate("document.getElementById('mail').click(); 0", in: tab)
        try await waitUntil("external prompt") { !harness.host.externalURLs.isEmpty }
        #expect(harness.host.externalURLs.first?.scheme == "mailto")
        #expect(tab.url == harness.server.url("/links"))
    }

    @Test func javaScriptDialogsReachTheShellOnlyForTheVisibleTab() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        let confirmed = try await harness.evaluate("confirm('sure?')", in: tab) as? Bool
        #expect(confirmed == true)
        let typed = try await harness.evaluate("prompt('name?', 'x')", in: tab) as? String
        #expect(typed == "typed")
        #expect(harness.host.alerts == ["sure?", "name?"])

        // An alert loop is cut off after the limit.
        _ = try await harness.evaluate("for (let i = 0; i < 10; i++) alert('spam ' + i); 0", in: tab)
        #expect(harness.host.alerts.count == EngineChoices.dialogLimit)

        // A hidden tab's dialog gets the dismissed answer without reaching the shell.
        let hidden = harness.pool.makeTab()
        try await harness.load("/a", in: hidden)
        let answer = try await harness.evaluate("confirm('hidden?')", in: hidden) as? Bool
        #expect(answer == false)
        #expect(!harness.host.alerts.contains("hidden?"))
    }
}
#endif
