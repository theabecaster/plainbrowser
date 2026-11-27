#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import WebKit
@testable import WebEngine

/// Appearance and dark pages: web views follow the app's colors, light-only pages are darkened
/// while it is dark, pages with a dark design are never touched, and the per-site switch sticks.
@Suite(.serialized) @MainActor
struct DarkPagesTests {
    /// Records the root's background and filter while the body starts parsing: before the page
    /// has painted, so whatever shows first.
    nonisolated static let early = """
        <script>window.__early = { bg: getComputedStyle(document.documentElement).backgroundColor,
          filter: getComputedStyle(document.documentElement).filter };</script>
        """

    nonisolated static let svg = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10' fill='%2300aa00'/></svg>"

    nonisolated static func page(head: String = "", style: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">\(head)
        <title>T</title><style>\(style)</style></head><body>\(early)\(body)</body></html>
        """
    }

    nonisolated static let lightBody = """
        <h1>Light only</h1><p>Text</p><img id=img src="\(svg)">
        <picture id=pic><img id=inner src="\(svg)"></picture>
        <div id=bg class=hero>hero</div><div id=inline style="background-image: url('\(svg)')">inline</div>
        <canvas id=cv width=10 height=10></canvas><svg id=icon width=10 height=10><rect width=10 height=10/></svg>
        <svg id=logo width=10 height=10><circle cx=5 cy=5 r=5 fill="#e33"/></svg>
        <svg id=gradlogo width=10 height=10><defs><linearGradient id=g1><stop offset=0 stop-color="#ff7a00"/>
        <stop offset=1 stop-color="#2060ff"/></linearGradient></defs><rect width=10 height=10 fill="url(#g1)"/></svg>
        """

    /// A large light-only page: 3,000 paragraphs, 4,000 style rules and 300 background pictures.
    nonisolated static let bigPage: String = {
        var rules = ""
        for i in 0..<4_000 { rules += ".c\(i){color:#\(String(format: "%03x", i % 4096));margin:\(i % 7)px}\n" }
        var body = ""
        for i in 0..<3_000 {
            body += "<p class=c\(i % 4_000)>Paragraph \(i) with <a href='#\(i)'>a link</a> and some text to wrap.</p>"
            if i % 10 == 0 { body += "<div class=hero style='height:20px'></div>" }
        }
        return page(style: "body{background:#fff;color:#222} .hero{background-image:url(\"\(svg)\")}\n" + rules, body: body)
    }()

    @Sendable nonisolated static func route(_ request: TestServer.Request) -> TestServer.Response {
        let base = "body{background:#fff;color:#111} .hero{background-image:url(\"\(svg)\");height:20px}"
        switch request.path {
        case "/light": return .html(page(style: base, body: lightBody))
        case "/unstyled": return .html(page(style: "", body: "<p>No colors at all</p>"))
        case "/dark-media":
            return .html(page(style: base + " @media (prefers-color-scheme: dark){body{background:#111;color:#eee}}", body: "<p>dark</p>"))
        case "/dark-meta":
            return .html(page(head: "<meta name=color-scheme content='light dark'>", style: base, body: "<p>meta</p>"))
        case "/dark-property": return .html(page(style: base + " :root{color-scheme:light dark}", body: "<p>prop</p>"))
        case "/only-light":
            return .html(page(head: "<meta name=color-scheme content='only light'>", style: base, body: "<p>only</p>"))
        case "/already-dark": return .html(page(style: "body{background:#121212;color:#eee}", body: "<p>dark</p>"))
        case "/dark-sheet":
            return .html(page(head: "<link rel=stylesheet href='/dark.css'>", style: base, body: "<p>sheet</p>"))
        case "/dark.css":
            return .data(Data("@media (prefers-color-scheme: dark){body{background:#000;color:#fff}}".utf8), type: "text/css")
        case "/big": return .html(bigPage)
        case "/late-dark":
            // Light while the head loads, dark once a sheet at the end of the body arrives.
            return .html(page(style: "", body: "<p>late</p><link rel=stylesheet href='/late.css'>"))
        case "/late.css":
            return .data(Data("body{background:#111;color:#eee}".utf8), type: "text/css")
        case "/oklch-dark": return .html(page(style: "body{background:oklch(0.2 0.02 260);color:#eee}", body: "<p>ok</p>"))
        case "/p3-dark": return .html(page(style: "body{background:color(display-p3 0.1 0.1 0.12);color:#eee}", body: "<p>p3</p>"))
        case "/adopted-dark":
            return .html(page(style: base, body: """
                <p>adopted</p><script>const s = new CSSStyleSheet();
                s.replaceSync('@media (prefers-color-scheme: dark){body{color:#eee}}');
                document.adoptedStyleSheets = [...document.adoptedStyleSheets, s];</script>
                """))
        case "/imported-dark":
            return .html(page(style: "@import url('/dark.css'); " + base, body: "<p>imported</p>"))
        default: return Pages.route(request)
        }
    }

    private func makeHarness(style: UIUserInterfaceStyle, darkPages: any SiteDarkPagesStore = InMemorySiteDarkPagesStore())
        async throws -> Harness
    {
        let harness = try await Harness(darkPages: darkPages, pageScripts: HandlerPageScripts(), route: Self.route)
        harness.window.overrideUserInterfaceStyle = style
        harness.pool.interfaceStyle = style
        return harness
    }

    private func style(_ property: String, of selector: String, in tab: Tab, harness: Harness) async throws -> String {
        try #require(try await harness.evaluate(
            "getComputedStyle(document.querySelector('\(selector)')).\(property)", in: tab
        ) as? String)
    }

    @Test func lightOnlyPageIsDarkenedWithItsPicturesKept() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }

        #expect(try await style("filter", of: "html", in: tab, harness: harness).contains("invert"))
        for picture in ["#img", "#pic", "#cv", "#inline", "#bg"] {
            #expect(try await style("filter", of: picture, in: tab, harness: harness).contains("invert"), "\(picture)")
        }
        // Inside a picture that already got the filter back: none of its own.
        #expect(try await style("filter", of: "#inner", in: tab, harness: harness) == "none")
        // An inline icon in greys is drawn like text: it flips with the page. A colored one is a
        // logo and keeps its colors.
        #expect(try await style("filter", of: "#icon", in: tab, harness: harness) == "none")
        #expect(try await style("filter", of: "#logo", in: tab, harness: harness).contains("invert"))
        #expect(try await style("filter", of: "#gradlogo", in: tab, harness: harness).contains("invert"))
        // Before the first paint the page was already dark: the guard, or the darkening itself.
        let early = try #require(try await harness.evaluate("window.__early", in: tab) as? [String: String])
        report("dark pages early root: \(early)")
        #expect(early["bg"] == "rgb(0, 0, 0)" || early["filter"]?.contains("invert") == true)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        var white: CGFloat = 1
        webView.underPageBackgroundColor.getWhite(&white, alpha: nil)
        #expect(white < 0.05)
    }

    @Test func unstyledPageIsDarkened() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/unstyled", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
    }

    @Test(arguments: [
        "/dark-media", "/dark-meta", "/dark-property", "/only-light", "/already-dark", "/dark-sheet", "/late-dark",
        "/oklch-dark", "/p3-dark", "/adopted-dark", "/imported-dark",
    ])
    func pagesWithTheirOwnDarkDesignAreLeftAlone(path: String) async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load(path, in: tab)
        try await waitUntil("judged \(path)") { tab.darkPages == .native }
        #expect(try await style("filter", of: "html", in: tab, harness: harness) == "none")
        // The guard is gone: the root shows the site's own background again.
        #expect(try await style("backgroundColor", of: "html", in: tab, harness: harness) == "rgba(0, 0, 0, 0)")
    }

    @Test func lightAppLeavesPagesAloneAndDarkensLiveWithoutReload() async throws {
        let harness = try await makeHarness(style: .light)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await Task.sleep(for: .milliseconds(200))
        #expect(tab.darkPages == .inactive)
        #expect(try await style("filter", of: "html", in: tab, harness: harness) == "none")
        // A light app adds nothing to the page.
        #expect(try await harness.evaluate("document.adoptedStyleSheets.length", in: tab) as? Int == 0)
        _ = try await harness.evaluate("window.__marker = 7", in: tab)

        harness.window.overrideUserInterfaceStyle = .dark
        harness.pool.interfaceStyle = .dark
        try await waitUntil("darkened live") { tab.darkPages == .darkened }
        #expect(try await harness.evaluate("window.__marker", in: tab) as? Int == 7)

        harness.window.overrideUserInterfaceStyle = .light
        harness.pool.interfaceStyle = .light
        try await waitUntil("light again") { tab.darkPages == .inactive }
        #expect(try await style("filter", of: "html", in: tab, harness: harness) == "none")
    }

    @Test func eachSwitchToDarkJudgesThePageAsItIsNow() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        harness.window.overrideUserInterfaceStyle = .light
        harness.pool.interfaceStyle = .light
        try await waitUntil("light") { tab.darkPages == .inactive }
        _ = try await harness.evaluate("document.body.style.background = '#101010'; 1", in: tab)
        harness.window.overrideUserInterfaceStyle = .dark
        harness.pool.interfaceStyle = .dark
        try await waitUntil("judged again") { tab.darkPages == .native }
        #expect(try await style("filter", of: "html", in: tab, harness: harness) == "none")
    }

    @Test func darkeningComesBackWhenThePageReplacesItsAdoptedSheets() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        try await Task.sleep(for: .milliseconds(100))
        _ = try await harness.evaluate(
            "document.adoptedStyleSheets = []; 1", in: tab
        )
        #expect(try await style("filter", of: "html", in: tab, harness: harness) == "none")
        // No DOM change: the next scroll puts the sheets back, even within the throttle.
        _ = try await harness.evaluate("window.dispatchEvent(new Event('scroll')); 1", in: tab)
        _ = try await harness.evaluate("document.adoptedStyleSheets = []; window.dispatchEvent(new Event('scroll')); 1", in: tab)
        let deadline = ContinuousClock.now + .seconds(3)
        var filter = ""
        while ContinuousClock.now < deadline {
            filter = try await style("filter", of: "html", in: tab, harness: harness)
            if filter.contains("invert") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(filter.contains("invert"))
    }

    @Test func aPageWithAnOldChoiceGetsTheSitesCurrentOne() async throws {
        let store = InMemorySiteDarkPagesStore()
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        // As if the site were turned off in another tab while this page waited in the
        // back-forward cache: its next report brings it in line.
        store.setDarkPagesOff(true, forSite: "127.0.0.1")
        let webView = try #require(harness.pool.existingWebView(for: tab))
        _ = try await webView.evaluateJavaScript(DarkPages.setOffSource(false), in: nil, contentWorld: UserScripts.world)
        try await waitUntil("corrected") { tab.darkPages == .offForSite }
    }

    @Test func turningItOffForASiteIsRememberedAndAppliesAtOnce() async throws {
        let store = InMemorySiteDarkPagesStore()
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        _ = try await harness.evaluate("window.__marker = 3", in: tab)

        tab.setDarkPagesOff(true)
        try await waitUntil("off") { tab.darkPages == .offForSite }
        #expect(store.offSites == ["127.0.0.1"])
        #expect(try await style("filter", of: "html", in: tab, harness: harness) == "none")
        #expect(try await harness.evaluate("window.__marker", in: tab) as? Int == 3)

        // Another tab on the site, and a reload, stay off.
        let other = harness.pool.makeTab()
        try await harness.load("/unstyled", in: other)
        try await waitUntil("other off") { other.darkPages == .offForSite }
        tab.reload()
        try await waitUntil("reloaded off") { tab.darkPages == .offForSite && !tab.isLoading }

        tab.setDarkPagesOff(false)
        try await waitUntil("on again") { tab.darkPages == .darkened }
        #expect(store.offSites.isEmpty)
    }

    @Test func storedListArrivingAfterLaunchReachesOpenWebViews() async throws {
        let store = InMemorySiteDarkPagesStore()
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        store.setDarkPagesOff(true, forSite: "127.0.0.1")
        harness.pool.darkPagesSitesDidChange()
        tab.reload()
        try await waitUntil("off after the list arrived") { tab.darkPages == .offForSite }
    }

    @Test func privateChoicesStayInThePrivateSession() async throws {
        let store = InMemorySiteDarkPagesStore()
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab(isPrivate: true)
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        tab.setDarkPagesOff(true)
        try await waitUntil("off") { tab.darkPages == .offForSite }
        #expect(store.offSites.isEmpty)
        let regular = harness.pool.makeTab()
        try await harness.load("/light", in: regular)
        try await waitUntil("regular still darkened") { regular.darkPages == .darkened }
    }

    @Test func pagesLoadedOffScreenGetTheAppsColors() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        try await harness.load("/dark-media", in: tab)
        #expect(try await harness.evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: tab) as? Bool == true)
        try await waitUntil("judged off screen") { tab.darkPages == .native }
        harness.pool.interfaceStyle = .light
        #expect(try await harness.evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: tab) as? Bool == false)
    }

    /// Main-frame load time of a large light-only page with dark pages darkening it, with dark
    /// pages off for the site (the script returns at once), and in a light app; and the script's
    /// own time on the page. Medians of several loads; the machine's load is printed with them.
    @Test func largePageCost() async throws {
        let store = InMemorySiteDarkPagesStore()
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        let clock = ContinuousClock()
        func measure(_ label: String, expect state: DarkPagesState) async throws {
            var loads: [Duration] = []
            var costs: [Double] = []
            for _ in 0..<7 {
                let start = clock.now
                try await harness.load("/big?\(UUID().uuidString)", in: tab)
                loads.append(clock.now - start)
                try await waitUntil("\(label) state") { tab.darkPages == state }
                let cost = try await webView.evaluateJavaScript(
                    "globalThis.__plainDarkPages ? globalThis.__plainDarkPages.cost : -1", in: nil, contentWorld: UserScripts.world
                )
                costs.append((cost as? Double) ?? Double((cost as? Int) ?? -1))
            }
            costs.sort()
            if state == .darkened {
                let bench = try await webView.evaluateJavaScript(
                    "globalThis.__plainDarkPages.bench(20)", in: nil, contentWorld: UserScripts.world
                )
                report("dark pages judgement + full picture scan of the big page: \(bench ?? "nil") ms per run")
            }
            report("dark pages \(label): load \(describe(loads)); script median \(String(format: "%.2f", costs[costs.count / 2])) ms, max \(String(format: "%.2f", costs.last ?? 0)) ms")
        }
        report("load average: \(ProcessInfo.processInfo.loadAverage)")
        // A warm-up round first, so the first mode measured doesn't pay for JIT and caches; then
        // the modes interleaved twice.
        for round in 0..<3 {
            let tag = round == 0 ? " (warm-up)" : ""
            try await measure("darkened\(tag)", expect: .darkened)
            store.setDarkPagesOff(true, forSite: "127.0.0.1")
            harness.pool.darkPagesSitesDidChange()
            try await measure("off for site\(tag)", expect: .offForSite)
            store.setDarkPagesOff(false, forSite: "127.0.0.1")
            harness.pool.darkPagesSitesDidChange()
            harness.window.overrideUserInterfaceStyle = .light
            harness.pool.interfaceStyle = .light
            try await measure("light app\(tag)", expect: .inactive)
            harness.window.overrideUserInterfaceStyle = .dark
            harness.pool.interfaceStyle = .dark
        }
    }
}

/// Page scripts like the reader's: a script and a message handler, which WebKit refuses to have
/// added twice, so a list change must not install them again.
private final class HandlerPageScripts: PageScripts {
    private final class Handler: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: "1", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(Handler(), name: "plainTestHandler")
    }
}

private extension ProcessInfo {
    var loadAverage: String {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads.map { String(format: "%.1f", $0) }.joined(separator: " ") : "n/a"
    }
}
#endif
