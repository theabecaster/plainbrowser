#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import WebKit
@testable import WebEngine

/// Appearance and dark pages: web views follow the app's colors, light-only pages are darkened
/// per color while it is dark (dark sections kept, text readable, pictures untouched), pages with
/// a dark design are never touched, and the per-site switch sticks.
@Suite(.serialized) @MainActor
struct DarkPagesTests {
    /// Records the root's background while the body starts parsing: before the page has painted,
    /// so whatever shows first.
    nonisolated static let early = """
        <script>window.__early = { bg: getComputedStyle(document.documentElement).backgroundColor,
          body: document.body ? getComputedStyle(document.body).backgroundColor : '' };</script>
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
        <h1 id=title>Light only</h1><p id=text>Text</p><img id=img src="\(svg)">
        <picture id=pic><img id=inner src="\(svg)"></picture>
        <div id=bg class=hero>hero</div><div id=inline style="background-image: url('\(svg)')">inline</div>
        <canvas id=cv width=10 height=10></canvas><svg id=icon width=10 height=10><rect id=iconrect width=10 height=10/></svg>
        <svg id=logo width=10 height=10><circle id=logocircle cx=5 cy=5 r=5 fill="#e33"/></svg>
        <svg id=gradlogo width=10 height=10><defs><linearGradient id=g1><stop offset=0 stop-color="#ff7a00"/>
        <stop offset=1 stop-color="#2060ff"/></linearGradient></defs><rect id=gradrect width=10 height=10 fill="url(#g1)"/></svg>
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

    nonisolated static func fixture(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures/DarkPages"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "<p>missing fixture \(name)</p>" }
        return text
    }

    /// The apple.com-like page at the size of a real store page: 4,000 more rules (variables,
    /// gradients, borders, states, media queries) and its sections repeated 25 times.
    nonisolated static let bigApplePage: String = {
        var rules = ":root{"
        for i in 0..<200 { rules += "--token-\(i):#\(String(format: "%02x%02x%02x", 200 + i % 56, 210 + i % 46, 220 + i % 36));" }
        rules += "}\n"
        for i in 0..<3_800 {
            switch i % 5 {
            case 0: rules += ".r\(i){background:var(--token-\(i % 200));color:#1d1d1f;padding:\(i % 9)px}\n"
            case 1: rules += ".r\(i):hover{color:#06c;border-bottom:1px solid #d2d2d7}\n"
            case 2: rules += "@media (min-width:\(300 + i % 700)px){.r\(i){background:linear-gradient(#fff,#f\(i % 10)f\(i % 10)f7)}}\n"
            case 3: rules += ".r\(i)>a{color:#2997ff;text-decoration-color:#6e6e73}\n"
            default: rules += ".r\(i){box-shadow:0 2px 8px rgba(0,0,0,.08);border:1px solid #e8e8ed;margin:\(i % 5)px}\n"
            }
        }
        var html = fixture("apple-like")
        guard let start = html.range(of: "<section class=\"hero\" id=\"hero\">"),
              let end = html.range(of: "<footer") else { return html }
        let sections = String(html[start.lowerBound..<end.lowerBound])
        var repeated = ""
        for i in 0..<25 {
            repeated += sections.replacingOccurrences(of: "id=\"", with: "id=\"s\(i)-")
        }
        html.replaceSubrange(start.lowerBound..<end.lowerBound, with: repeated)
        return html.replacingOccurrences(of: "</head>", with: "<style>\(rules)</style></head>")
    }()

    /// A black wordmark on a transparent ground, as a PNG (the kind Safari inverts).
    nonisolated static let wordmarkPNG: Data = picture(size: CGSize(width: 200, height: 50), opaque: false) { _ in
        let text = NSAttributedString(string: "Plain", attributes: [
            .font: UIFont.systemFont(ofSize: 40, weight: .heavy), .foregroundColor: UIColor(white: 0.07, alpha: 1),
        ])
        text.draw(at: CGPoint(x: 10, y: 0))
    }

    /// A grey photograph-like picture: opaque, no transparent ground, many greys.
    nonisolated static let greyPhotoPNG: Data = picture(size: CGSize(width: 200, height: 50), opaque: true) { context in
        for x in 0..<200 {
            UIColor(white: CGFloat(x) / 200, alpha: 1).setFill()
            context.fill(CGRect(x: x, y: 0, width: 1, height: 50))
        }
    }

    /// A red mark on a transparent ground: a colored logo, kept.
    nonisolated static let redMarkPNG: Data = picture(size: CGSize(width: 200, height: 50), opaque: false) { context in
        UIColor(red: 0.85, green: 0.1, blue: 0.15, alpha: 1).setFill()
        context.fill(CGRect(x: 10, y: 10, width: 180, height: 30))
    }

    nonisolated static func picture(size: CGSize, opaque: Bool, draw: (UIGraphicsImageRendererContext) -> Void) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).pngData(actions: draw)
    }

    /// A black-and-white SVG wordmark, served (same origin, or another with CORS).
    nonisolated static let wordmarkSVG = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="50" viewBox="0 0 200 50">
        <path d="M10 10h30v30h-30z M50 10h10v30h-10z M70 10h40v8h-40z M70 32h40v8h-40z" fill="#111"/></svg>
        """.utf8)

    @Sendable nonisolated static func route(_ request: TestServer.Request) -> TestServer.Response {
        let base = "body{background:#fff;color:#111} .hero{background-image:url(\"\(svg)\");height:20px}"
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        // Another origin: the same routes on a second server's port (`?port=`).
        let port = request.path.split(separator: "port=").last.map(String.init) ?? ""
        let other = "127.0.0.1:\(port)"
        switch path {
        case "/light": return .html(page(style: base, body: lightBody))
        // A picture across the width over the center and the top quarter points, as a hero shows
        // on a wide screen (the Duo's inner screen); white below it.
        case "/light-hero":
            return .html(page(style: base, body: "<img src=\"/grey-photo.png\" style=\"display:block;width:100%;height:45vh;margin-top:15vh\">"
                + (1...20).map { "<p>Paragraph \($0) of a light page.</p>" }.joined()))
        // A white root under a dark app shell that fills the screen.
        case "/dark-shell":
            return .html(page(style: base, body: "<div style=\"position:fixed;inset:0;background:#141414;color:#eee\"><p>app</p></div>"))
        // Pictures everywhere the check looks.
        case "/all-pictures":
            return .html(page(style: base, body: "<img src=\"/grey-photo.png\" style=\"position:fixed;inset:0;width:100%;height:100%\">"))
        case "/unstyled": return .html(page(style: "", body: "<p id=text>No colors at all</p>"))
        case "/apple": return .html(fixture("apple-like"))
        case "/apple-big": return .html(bigApplePage)
        case "/article": return .html(fixture("article"))
        case "/own-dark": return .html(fixture("own-dark"))
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
        case "/cross-origin":
            // Style sheets from another origin: one shared with CORS, one not.
            return .html(page(
                head: "<link rel=stylesheet href='http://\(other)/shared.css'><link rel=stylesheet href='http://\(other)/private.css'>",
                style: "body{margin:0}",
                body: "<div id=shared class=shared>Shared sheet</div><div id=private class=private>Private sheet</div>"
            ))
        case "/shared.css":
            return .data(Data("body{background:#fff;color:#222} .shared{background:#f0f0f0;color:#333;padding:8px}".utf8),
                         type: "text/css", headers: ["Access-Control-Allow-Origin": "*"])
        case "/private.css":
            return .data(Data(".private{background:#fafafa;color:#444;border:1px solid #ddd;padding:8px}".utf8), type: "text/css")
        case "/dynamic":
            return .html(page(style: base + " .card{background:#f5f5f7;color:#1d1d1f;padding:8px}", body: "<p id=text>Dynamic</p>"))
        case "/svg-and-variables":
            // SVG paints set by style sheets, and a gradient held in a variable used by a shorthand.
            return .html(page(style: base + """
                 :root{--panel:linear-gradient(#ffffff,#eeeeee)}
                .css-logo path{fill:#e33} .css-icon path{fill:#333} .panel{background:var(--panel);height:40px}
                """, body: """
                <svg class=css-logo width=20 height=20><path id=css-logo d="M0 0h20v20H0z"/></svg>
                <svg class=css-icon width=20 height=20><path id=css-icon d="M0 0h20v20H0z"/></svg>
                <div id=panel class=panel>Panel</div>
                """))
        case "/wordmark.png": return .data(wordmarkPNG, type: "image/png")
        case "/grey-photo.png": return .data(greyPhotoPNG, type: "image/png")
        case "/red-mark.png": return .data(redMarkPNG, type: "image/png")
        case "/wordmark.svg": return .data(wordmarkSVG, type: "image/svg+xml")
        case "/wordmark-cors.svg":
            return .data(wordmarkSVG, type: "image/svg+xml", headers: ["Access-Control-Allow-Origin": "*"])
        case "/logos":
            // Black-and-white marks on a transparent ground (inverted), and pictures that keep
            // their colors: a colored mark, a grey photo, a mark too large to be a logo, one from
            // another origin that won't share it, and one on the site's own dark band.
            return .html(page(style: base + """
                 img{display:block;margin:8px 0} .bg-logo{display:block;width:200px;height:50px;background:url('/wordmark.svg') no-repeat;
                text-indent:-9999px;overflow:hidden} .band{background:#000;padding:8px}
                """, body: """
                <p id=text>Logos</p>
                <img id=png src="/wordmark.png" width=200 height=50>
                <img id=svg src="/wordmark.svg" width=200 height=50>
                <img id=cors src="http://\(other)/wordmark-cors.svg" width=200 height=50>
                <img id=private src="http://\(other)/wordmark.svg" width=200 height=50>
                <a id=bg-logo class=bg-logo href="/">Plain</a>
                <img id=red src="/red-mark.png" width=200 height=50>
                <img id=photo src="/grey-photo.png" width=200 height=50>
                <img id=big src="/wordmark.png" width=800 height=200>
                <div class=band><img id=on-dark src="/wordmark.png" width=200 height=50></div>
                """))
        case "/shadow":
            // Web components: an open shadow root with its own <style>, one with an adopted sheet
            // shared by two instances, and one defined after the page loaded.
            return .html(page(style: base, body: """
                <p id=text>Components</p>
                <x-card id=card><span id=slotted>Slotted text</span></x-card>
                <x-panel id=panel1></x-panel><x-panel id=panel2></x-panel>
                <x-late id=late></x-late>
                <script>
                class XCard extends HTMLElement { constructor() { super(); const r = this.attachShadow({ mode: 'open' });
                  r.innerHTML = '<style>.card{background:#fff;color:#222;padding:8px;border:1px solid #ddd}</style>'
                    + '<div class=card id=inner>Shadow text <span id=sub style="background:#f4f4f4;color:#333">inline</span></div><slot></slot>'; } }
                customElements.define('x-card', XCard);
                const shared = new CSSStyleSheet(); shared.replaceSync('.panel{background:#f5f5f7;color:#1d1d1f;padding:8px}');
                class XPanel extends HTMLElement { constructor() { super(); const r = this.attachShadow({ mode: 'open' });
                  r.adoptedStyleSheets = [shared]; r.innerHTML = '<div class=panel id=inner>Panel</div>'; } }
                customElements.define('x-panel', XPanel);
                addEventListener('load', () => setTimeout(() => {
                  class XLate extends HTMLElement { constructor() { super(); const r = this.attachShadow({ mode: 'open' });
                    r.innerHTML = '<style>div{background:#fafafa;color:#111}</style><div id=inner>Late</div>'; } }
                  customElements.define('x-late', XLate);
                }, 300));
                </script>
                """))
        case "/frames":
            // A same-origin frame (darkened with the page), another origin's frame (kept), and a
            // same-origin frame added after the page turned dark.
            return .html(page(style: base, body: """
                <p id=text>Frames</p>
                <iframe id=same src="/frame-light" width=300 height=120></iframe>
                <iframe id=other src="http://\(other)/frame-light?report" width=300 height=120></iframe>
                <script>
                addEventListener('message', (e) => { if (e.data && e.data.bg) window.__otherBg = e.data.bg; });
                addEventListener('load', () => setTimeout(() => {
                  const f = document.createElement('iframe'); f.id = 'added'; f.src = '/frame-light?added';
                  f.width = 300; f.height = 120; document.body.append(f);
                }, 300));
                </script>
                """))
        case "/frame-light":
            let report = request.path.contains("report")
                ? "<script>addEventListener('load', () => setTimeout(() => parent.postMessage({ bg: getComputedStyle(document.body).backgroundColor }, '*'), 1200))</script>"
                : ""
            return .html(page(style: "body{background:#fff;color:#222} .box{background:#f0f0f0;color:#333}",
                              body: "<p id=text>Frame</p><div id=box class=box>Box</div>\(report)"))
        default: return Pages.route(request)
        }
    }

    private func makeHarness(style: UIUserInterfaceStyle, darkPages: any PageAppearanceStore = InMemoryPageAppearanceStore(defaultAppearance: .dark))
        async throws -> Harness
    {
        let harness = try await Harness(darkPages: darkPages, pageScripts: HandlerPageScripts(), route: Self.route)
        harness.window.overrideUserInterfaceStyle = style
        harness.pool.interfaceStyle = style
        return harness
    }

    /// Plain's colors changing, with the page appearance a user who wants dark pages has: Dark
    /// while Plain is dark, Off (each site as made, in Plain's colors) while light. Dark alone
    /// keeps pages dark in a light Plain (docs/decisions.md, "Page appearance").
    private func appColors(_ style: UIUserInterfaceStyle, _ store: InMemoryPageAppearanceStore, _ harness: Harness) async {
        store.choices.defaultAppearance = style == .dark ? .dark : .off
        harness.window.overrideUserInterfaceStyle = style
        harness.pool.interfaceStyle = style
        await harness.pool.darkPagesChoicesDidChange()
    }

    private func style(_ property: String, of selector: String, in tab: Tab, harness: Harness) async throws -> String {
        try #require(try await harness.evaluate(
            "getComputedStyle(document.querySelector('\(selector)')).\(property)", in: tab
        ) as? String)
    }

    /// Relative luminance (0 black, 1 white) of a computed color property.
    private func luminance(_ property: String, of selector: String, in tab: Tab, harness: Harness) async throws -> Double {
        let value = try await harness.evaluate("""
            (() => { const s = getComputedStyle(document.querySelector('\(selector)')).\(property);
              const n = s.match(/[\\d.]+/g).map(Number);
              const lin = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
              return 0.2126 * lin(n[0]) + 0.7152 * lin(n[1]) + 0.0722 * lin(n[2]); })()
            """, in: tab)
        return try #require(value as? Double ?? (value as? Int).map(Double.init))
    }

    private func engine(_ script: String, in tab: Tab, harness: Harness) async throws -> Any? {
        let webView = try #require(harness.pool.existingWebView(for: tab))
        return try await webView.evaluateJavaScript(script, in: nil, contentWorld: UserScripts.world)
    }

    /// Every visible text element's contrast with what is behind it, as the engine measures it.
    private func audit(_ tab: Tab, harness: Harness) async throws -> [(id: String, ratio: Double, color: String, bg: String)] {
        let rows = try #require(try await engine("globalThis.__plainDarkPages.audit()", in: tab, harness: harness) as? [[String: Any]])
        return rows.map {
            ($0["id"] as? String ?? "?", ($0["ratio"] as? Double) ?? Double($0["ratio"] as? Int ?? 0),
             $0["color"] as? String ?? "", $0["bg"] as? String ?? "")
        }
    }

    /// Waits for the idle slices to finish the elements below the first screen.
    private func settle(_ tab: Tab, harness: Harness) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let done = try await engine("globalThis.__plainDarkPages.stats.firstPatchDone >= 0", in: tab, harness: harness) as? Bool
            if done == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func lightOnlyPageIsDarkenedWithItsPicturesKept() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        try await settle(tab, harness: harness)

        #expect(try await luminance("backgroundColor", of: "body", in: tab, harness: harness) < 0.02)
        #expect(try await luminance("color", of: "#title", in: tab, harness: harness) > 0.6)
        // Pictures, canvases and background pictures are never touched: no filter, no mark.
        for picture in ["#img", "#pic", "#inner", "#cv", "#inline", "#bg"] {
            #expect(try await style("filter", of: picture, in: tab, harness: harness) == "none", "\(picture)")
        }
        for picture in ["#img", "#pic", "#inner", "#cv"] {
            let mark = try await harness.evaluate("document.querySelector('\(picture)').getAttribute('data-plain-dark')", in: tab)
            #expect(mark is NSNull || mark == nil, "\(picture): \(String(describing: mark))")
        }
        #expect(try await style("backgroundImage", of: "#bg", in: tab, harness: harness).contains("url("))
        // Text on a background picture keeps the site's color: the picture isn't darkened.
        #expect(try await style("color", of: "#bg", in: tab, harness: harness) == "rgb(17, 17, 17)")
        // A black icon flips so it shows on the dark page; colored logos keep their colors.
        #expect(try await luminance("fill", of: "#iconrect", in: tab, harness: harness) > 0.4)
        #expect(try await style("fill", of: "#logocircle", in: tab, harness: harness) == "rgb(238, 51, 51)")
        #expect(try await style("fill", of: "#gradrect", in: tab, harness: harness).contains("url("))
        #expect(try await style("filter", of: "html", in: tab, harness: harness) == "none")
        // Before the first paint the page was already dark: the guard, or the darkening itself.
        let early = try #require(try await harness.evaluate("window.__early", in: tab) as? [String: String])
        report("dark pages early root: \(early)")
        #expect(early["bg"] == "rgb(24, 24, 24)" || early["body"] == "rgb(24, 24, 24)")
        let webView = try #require(harness.pool.existingWebView(for: tab))
        var white: CGFloat = 1
        webView.underPageBackgroundColor.getWhite(&white, alpha: nil)
        #expect(white < 0.12)
    }

    @Test func unstyledPageIsDarkened() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/unstyled", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        try await settle(tab, harness: harness)
        #expect(try await luminance("backgroundColor", of: "html", in: tab, harness: harness) < 0.02)
        #expect(try await luminance("color", of: "#text", in: tab, harness: harness) > 0.6)
    }

    /// The owner's case: a page like apple.com, light by design with black heroes and dark cards.
    /// The dark parts stay exactly as made, the light parts turn dark, every text passes 4.5:1,
    /// brand colors, pictures, logos and emoji keep their colors.
    @Test func mixedLightAndDarkSectionsKeepTheirDesign() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/apple", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        try await settle(tab, harness: harness)
        func css(_ property: String, _ selector: String) async throws -> String {
            try await style(property, of: selector, in: tab, harness: harness)
        }
        func lum(_ property: String, _ selector: String) async throws -> Double {
            try await luminance(property, of: selector, in: tab, harness: harness)
        }

        // Dark sections and their light text: untouched.
        #expect(try await css("backgroundColor", "#hero") == "rgb(0, 0, 0)")
        #expect(try await css("color", "#hero-title") == "rgb(245, 245, 247)")
        #expect(try await css("backgroundColor", "#hero-2") == "rgb(0, 0, 0)")
        #expect(try await css("color", "#tile-dark-title") == "rgb(245, 245, 247)")
        // The dark card on the light section stays dark, lifted just enough to stand off the
        // section, which is dark now too.
        let card = try await lum("backgroundColor", "#tile-dark")
        let section = try await lum("backgroundColor", "#light")
        #expect(card < 0.05 && (card + 0.05) / (section + 0.05) > 1.1, "card \(card), section \(section)")
        #expect(try await css("backgroundColor", "#vars-dark") == "rgb(0, 0, 0)")
        #expect(try await css("color", "#vars-dark-title") == "rgb(245, 245, 247)")
        // Brand colors stay: the blue button, the gradient headline.
        #expect(try await css("backgroundColor", "#hero-buy") == "rgb(0, 113, 227)")
        #expect(try await css("backgroundImage", "#hero-glow").contains("rgb(255, 95, 109)"))
        // Light sections turn dark with light text.
        for section in ["#light", "#tile", "#ribbon", "#vars-light", "#tinted", "#inline", "#footer", "#tile-blue"] {
            #expect(try await lum("backgroundColor", section) < 0.03, "\(section) background")
        }
        for text in ["#light-title", "#tile-text", "#vars-light-title", "#inline-title", "#inline-text", "#footer-head", "#promo-title"] {
            #expect(try await lum("color", text) > 0.35, "\(text) text")
        }
        // The light gradient turns dark, every stop.
        let promo = try await css("backgroundImage", "#promo")
        let stops = try #require(try await harness.evaluate("""
            getComputedStyle(document.querySelector('#promo')).backgroundImage.match(/rgba?\\([^)]*\\)/g)
              .map((s) => s.match(/[\\d.]+/g).slice(0, 3).map(Number)).map(([r, g, b]) => (r + g + b) / 3)
            """, in: tab) as? [Double])
        #expect(!stops.isEmpty && stops.allSatisfy { $0 < 70 }, "promo gradient: \(promo)")
        // Icons drawn in black flip to show; the colored logo keeps its gradient.
        #expect(try await lum("fill", "#icon-truck path") > 0.4)
        #expect(try await lum("stroke", "#search-icon circle") > 0.4)
        #expect(try await lum("fill", "#logo-mark path") > 0.4)
        #expect(try await css("fill", "#logo-color circle").contains("url("))
        #expect(try await harness.evaluate("getComputedStyle(document.querySelector('#lg stop')).stopColor", in: tab) as? String == "rgb(255, 45, 85)")
        // Text over a light photograph keeps the site's dark color, so it stays readable on it.
        #expect(try await css("color", "#photo-tile-title") == "rgb(29, 29, 31)")
        #expect(try await css("color", "#photo-tile-text") == "rgb(29, 29, 31)")
        // A picture that loads late rechecks the text around it; the icons there stay fixed.
        _ = try await harness.evaluate("document.querySelector('#photo').dispatchEvent(new Event('load')); 1", in: tab)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await lum("fill", "#icon-truck path") > 0.4)
        // Pictures and emoji: nothing applied.
        #expect(try await css("filter", "#photo") == "none")
        #expect(try await css("filter", "#emoji") == "none")
        #expect(try await harness.evaluate("document.querySelector('#photo').hasAttribute('data-plain-dark')", in: tab) as? Bool == false)
        // Every visible text: at least 4.5:1 against what is behind it.
        let rows = try await audit(tab, harness: harness)
        #expect(rows.count > 25)
        let failing = rows.filter { $0.ratio < 4.5 }
        report("apple-like contrast: \(rows.count) texts, min \(rows.map(\.ratio).min() ?? 0), failing \(failing)")
        #expect(failing.isEmpty, "\(failing)")
    }

    @Test func classicArticleIsReadableEverywhere() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/article", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        try await settle(tab, harness: harness)
        #expect(try await luminance("backgroundColor", of: "body", in: tab, harness: harness) < 0.02)
        // Legacy color attributes, reached element by element.
        #expect(try await luminance("backgroundColor", of: "#legacy", in: tab, harness: harness) < 0.05)
        #expect(try await luminance("color", of: "#font", in: tab, harness: harness) > 0.3)
        // Links keep their hue: still blue, now light.
        let link = try await style("color", of: "#link", in: tab, harness: harness)
        let channels = link.split(whereSeparator: { !"0123456789".contains($0) }).compactMap { Int($0) }
        #expect(channels.count >= 3 && channels[2] > channels[0] && channels[2] > 150, "link \(link)")
        #expect(try await style("filter", of: "#figure", in: tab, harness: harness) == "none")
        let rows = try await audit(tab, harness: harness)
        let failing = rows.filter { $0.ratio < 4.5 }
        report("article contrast: \(rows.count) texts, min \(rows.map(\.ratio).min() ?? 0), failing \(failing)")
        #expect(rows.count > 15)
        #expect(failing.isEmpty, "\(failing)")
    }

    @Test func styleSheetsFromAnotherOriginAreDarkened() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let other = try await TestServer(route: Self.route)
        defer { other.stop() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/cross-origin?port=\(other.port)", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        // The shared sheet is fetched again and rewritten; the private one is fixed per element.
        let deadline = ContinuousClock.now + .seconds(5)
        var shared = 1.0, priv = 1.0
        var stats: [String: Any] = [:]
        while ContinuousClock.now < deadline {
            shared = try await luminance("backgroundColor", of: "#shared", in: tab, harness: harness)
            priv = try await luminance("backgroundColor", of: "#private", in: tab, harness: harness)
            stats = try await engine("globalThis.__plainDarkPages.stats", in: tab, harness: harness) as? [String: Any] ?? [:]
            if shared < 0.05 && priv < 0.05 && (stats["unreadable"] as? Int ?? 0) >= 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(shared < 0.05)
        #expect(priv < 0.05)
        #expect(try await luminance("color", of: "#private", in: tab, harness: harness) > 0.4)
        report("cross-origin stats: fetched \(stats["fetched"] ?? "?"), unreadable \(stats["unreadable"] ?? "?")")
        #expect((stats["fetched"] as? Int ?? 0) >= 1)
        #expect((stats["unreadable"] as? Int ?? 0) >= 1)
        // Both sheets did load and style the page.
        #expect(try await style("paddingTop", of: "#private", in: tab, harness: harness) == "8px")
        #expect(try await style("paddingTop", of: "#shared", in: tab, harness: harness) == "8px")
    }

    @Test func contentAddedLaterIsDarkenedToo() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/dynamic", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        _ = try await harness.evaluate("""
            const a = document.createElement('div'); a.id = 'added'; a.className = 'card'; a.textContent = 'Added';
            const b = document.createElement('div'); b.id = 'inline-added'; b.style.cssText = 'background:#fff;color:#000';
            b.textContent = 'Inline'; document.body.append(a, b);
            document.styleSheets[0].insertRule('.late{background:#eee;color:#222}', document.styleSheets[0].cssRules.length);
            const c = document.createElement('div'); c.id = 'late'; c.className = 'late'; c.textContent = 'Late rule';
            document.body.append(c); 1
            """, in: tab)
        let deadline = ContinuousClock.now + .seconds(3)
        var values: [Double] = []
        while ContinuousClock.now < deadline {
            values = []
            for id in ["#added", "#inline-added", "#late"] {
                values.append(try await luminance("backgroundColor", of: id, in: tab, harness: harness))
            }
            if values.allSatisfy({ $0 < 0.05 }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(values.allSatisfy { $0 < 0.05 }, "\(values)")
        #expect(try await luminance("color", of: "#inline-added", in: tab, harness: harness) > 0.5)
    }

    @Test func svgPaintsAndGradientVariablesFromStyleSheets() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/svg-and-variables", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        try await settle(tab, harness: harness)
        // A colored fill from a style sheet is a logo: kept. A grey one is an icon: flipped.
        #expect(try await style("fill", of: "#css-logo", in: tab, harness: harness) == "rgb(238, 51, 51)")
        #expect(try await luminance("fill", of: "#css-icon", in: tab, harness: harness) > 0.4)
        // A light gradient in a variable, used through the background shorthand: darkened.
        let panel = try await style("backgroundImage", of: "#panel", in: tab, harness: harness)
        let stops = panel.matches(of: /rgb\((\d+), (\d+), (\d+)\)/).map { (Int($0.1)! + Int($0.2)! + Int($0.3)!) / 3 }
        #expect(!stops.isEmpty && stops.allSatisfy { $0 < 80 }, "\(panel)")
    }

    /// A picture of the tab's page for review, when `PLAIN_CAPTURE_DIR` is set
    /// (`TEST_RUNNER_PLAIN_CAPTURE_DIR` through xcodebuild).
    private func capture(_ name: String, _ tab: Tab, harness: Harness) async {
        guard let directory = ProcessInfo.processInfo.environment["PLAIN_CAPTURE_DIR"],
              let webView = harness.pool.existingWebView(for: tab) else { return }
        try? await Task.sleep(for: .milliseconds(300))
        let image = try? await webView.takeSnapshot(configuration: nil)
        try? image?.pngData()?.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
    }

    /// Waits until `condition` (a script in the page's world) is true, or 5 s.
    private func waitFor(_ condition: String, in tab: Tab, harness: Harness) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let check = "(() => { try { return !!(\(condition)); } catch (e) { return false; } })()"
            if try await harness.evaluate(check, in: tab) as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Black-and-white logos (a dark mark on a transparent ground) are inverted, as Safari does:
    /// PNG and SVG, the page's own and another origin's that allows it, and a CSS background
    /// logo. Colored marks, photos, large pictures, unreadable pictures and marks on the site's
    /// own dark band keep their colors.
    @Test func blackAndWhiteLogosAreInverted() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let other = try await TestServer(route: Self.route)
        defer { other.stop() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/logos?port=\(other.port)", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        try await settle(tab, harness: harness)
        let inverted = ["#png", "#svg", "#cors", "#bg-logo"]
        let all = inverted.map { "getComputedStyle(document.querySelector('\($0)')).filter.includes('invert')" }
        let done = try await waitFor(all.joined(separator: " && "), in: tab, harness: harness)
        let stats = try await engine("globalThis.__plainDarkPages.stats", in: tab, harness: harness) as? [String: Any]
        await capture("dark-logos-darkened", tab, harness: harness)
        report("logos: stats logos \(stats?["logos"] ?? "?"), read \(stats?["logosRead"] ?? "?"), \(stats?["logoMs"] ?? "?") ms, max \(stats?["logoMax"] ?? "?") ms")
        #expect(done)
        for id in inverted {
            #expect(try await style("filter", of: id, in: tab, harness: harness).contains("invert(0.92)"), "\(id)")
        }
        for id in ["#red", "#photo", "#big", "#private", "#on-dark"] {
            #expect(try await style("filter", of: id, in: tab, harness: harness) == "none", "\(id) keeps its colors")
        }
        // Off for the site: the pictures are as made again.
        await tab.setPageAppearance(.off)
        try await waitUntil("off") { tab.darkPages == .offForSite }
        await capture("dark-logos-off", tab, harness: harness)
        #expect(try await style("filter", of: "#png", in: tab, harness: harness) == "none")
    }

    /// Web components: light boxes in open shadow roots are darkened (their own sheets, a sheet
    /// shared by several roots, inline styles inside, a component defined after load), and text in
    /// them stays readable.
    @Test func openShadowRootsAreDarkened() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/shadow", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        try await settle(tab, harness: harness)
        func inner(_ host: String, _ id: String, _ property: String) -> String {
            "getComputedStyle(document.querySelector('\(host)').shadowRoot.querySelector('\(id)')).\(property)"
        }
        let lum = """
            ((s) => { const n = s.match(/[\\d.]+/g).map(Number);
              const lin = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
              return 0.2126 * lin(n[0]) + 0.7152 * lin(n[1]) + 0.0722 * lin(n[2]); })
            """
        let dark = ["#card": "#inner", "#panel1": "#inner", "#panel2": "#inner", "#late": "#inner"]
        let condition = dark.map { "\(lum)(\(inner($0.key, $0.value, "backgroundColor"))) < 0.03" }
            + ["\(lum)(\(inner("#card", "#sub", "backgroundColor"))) < 0.03"]
        let done = try await waitFor(condition.joined(separator: " && "), in: tab, harness: harness)
        let values = try await harness.evaluate("[" + (dark.map { inner($0.key, $0.value, "backgroundColor") }
            + [inner("#card", "#sub", "backgroundColor"), inner("#card", "#inner", "color"), inner("#late", "#inner", "color")])
            .joined(separator: ",") + "]", in: tab)
        report("shadow roots: \(values ?? "nil")")
        #expect(done, "\(values ?? "nil")")
        for (host, id) in [("#card", "#inner"), ("#card", "#sub"), ("#panel1", "#inner"), ("#late", "#inner")] {
            let color = try await harness.evaluate("\(lum)(\(inner(host, id, "color")))", in: tab) as? Double ?? 0
            #expect(color > 0.5, "\(host) \(id) text is light: \(color)")
        }
        #expect(try await luminance("color", of: "#slotted", in: tab, harness: harness) > 0.5)
        let stats = try await engine("globalThis.__plainDarkPages.stats", in: tab, harness: harness) as? [String: Any]
        #expect((stats?["shadowRoots"] as? Int ?? 0) >= 4)
        await capture("dark-shadow-darkened", tab, harness: harness)
        // Off and on again: the components are as made, then darkened again.
        await tab.setPageAppearance(.off)
        try await waitUntil("off") { tab.darkPages == .offForSite }
        #expect(try await harness.evaluate(inner("#card", "#inner", "backgroundColor"), in: tab) as? String == "rgb(255, 255, 255)")
        #expect(try await harness.evaluate(inner("#card", "#sub", "backgroundColor"), in: tab) as? String == "rgb(244, 244, 244)")
        await tab.setPageAppearance(nil)
        try await waitUntil("on") { tab.darkPages == .darkened }
        #expect(try await waitFor(condition.joined(separator: " && "), in: tab, harness: harness))
    }

    /// Same-origin frames are darkened with the page (one there from the start, one added later,
    /// and one there before the app turned dark); another origin's frame is left as made.
    @Test func sameOriginFramesAreDarkened() async throws {
        let store = InMemoryPageAppearanceStore(defaultAppearance: .dark)
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let other = try await TestServer(route: Self.route)
        defer { other.stop() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/frames?port=\(other.port)", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        func frame(_ id: String, _ selector: String, _ property: String) -> String {
            "getComputedStyle(document.getElementById('\(id)').contentDocument.querySelector('\(selector)')).\(property)"
        }
        let dark = { (id: String) in
            "\(frame(id, "body", "backgroundColor")) === 'rgb(24, 24, 24)' && \(frame(id, "#box", "backgroundColor")) !== 'rgb(240, 240, 240)'"
        }
        #expect(try await waitFor("document.getElementById('added') && document.getElementById('added').contentDocument.body && " + dark("same") + " && " + dark("added"), in: tab, harness: harness))
        let text = try await harness.evaluate(frame("same", "#text", "color"), in: tab) as? String ?? ""
        report("frames: same text \(text), box \(try await harness.evaluate(frame("same", "#box", "backgroundColor"), in: tab) ?? "")")
        #expect(text != "rgb(34, 34, 34)", "the frame's text turned light: \(text)")
        await capture("dark-frames-darkened", tab, harness: harness)
        // The other origin's frame reports its own background: white, as made.
        #expect(try await waitFor("window.__otherBg", in: tab, harness: harness))
        #expect(try await harness.evaluate("window.__otherBg", in: tab) as? String == "rgb(255, 255, 255)")
        // Off for the site: the frames follow the page.
        await tab.setPageAppearance(.off)
        try await waitUntil("off") { tab.darkPages == .offForSite }
        #expect(try await waitFor("\(frame("same", "body", "backgroundColor")) === 'rgb(255, 255, 255)'", in: tab, harness: harness))

        // A frame that was there while the app was light is darkened when the app turns dark.
        await tab.setPageAppearance(nil)
        await appColors(.light, store, harness)
        try await harness.load("/frames?port=\(other.port)&light", in: tab)
        try await waitUntil("light") { tab.darkPages == .inactive }
        #expect(try await waitFor("document.getElementById('same').contentDocument.body", in: tab, harness: harness))
        await appColors(.dark, store, harness)
        try await waitUntil("darkened live") { tab.darkPages == .darkened }
        #expect(try await waitFor(dark("same"), in: tab, harness: harness))
    }

    @Test(arguments: [
        "/dark-media", "/dark-meta", "/dark-property", "/only-light", "/already-dark", "/dark-sheet", "/late-dark",
        "/oklch-dark", "/p3-dark", "/adopted-dark", "/imported-dark", "/own-dark",
    ])
    func pagesWithTheirOwnDarkDesignAreLeftAlone(path: String) async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load(path, in: tab)
        try await waitUntil("judged \(path)") { tab.darkPages == .native }
        // The guard is gone: the root shows the site's own background again.
        #expect(try await style("backgroundColor", of: "html", in: tab, harness: harness) == "rgba(0, 0, 0, 0)")
        #expect(try await harness.evaluate("document.querySelectorAll('[data-plain-dark]').length", in: tab) as? Int == 0)
        if path == "/own-dark" {
            #expect(try await style("backgroundColor", of: "body", in: tab, harness: harness) == "rgb(27, 20, 48)")
            #expect(try await style("color", of: "#title", in: tab, harness: harness) == "rgb(200, 182, 255)")
        }
    }

    /// A link preview shows a light-only page dark in a dark app, as the page will open.
    @Test func linkPreviewsAreDarkenedToo() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let (webView, _) = harness.pool.makePreviewWebView()
        webView.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        harness.window.addSubview(webView)
        defer { webView.removeFromSuperview() }
        webView.load(URLRequest(url: harness.server.url("/light")))
        try await waitUntil("preview loaded") { !webView.isLoading && webView.url != nil }
        let deadline = ContinuousClock.now + .seconds(5)
        var background = ""
        while ContinuousClock.now < deadline {
            background = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String ?? ""
            if background != "rgb(255, 255, 255)" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(background == "rgb(24, 24, 24)", "preview background \(background)")
    }

    @Test func lightAppLeavesPagesAloneAndDarkensLiveWithoutReload() async throws {
        let store = InMemoryPageAppearanceStore()
        let harness = try await makeHarness(style: .light, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await Task.sleep(for: .milliseconds(200))
        #expect(tab.darkPages == .inactive)
        #expect(try await style("backgroundColor", of: "body", in: tab, harness: harness) == "rgb(255, 255, 255)")
        // A light app adds nothing to the page.
        #expect(try await harness.evaluate("document.adoptedStyleSheets.length", in: tab) as? Int == 0)
        _ = try await harness.evaluate("window.__marker = 7", in: tab)

        await appColors(.dark, store, harness)
        try await waitUntil("darkened live") { tab.darkPages == .darkened }
        #expect(try await harness.evaluate("window.__marker", in: tab) as? Int == 7)
        #expect(try await luminance("backgroundColor", of: "body", in: tab, harness: harness) < 0.02)

        await appColors(.light, store, harness)
        try await waitUntil("light again") { tab.darkPages == .inactive }
        #expect(try await style("backgroundColor", of: "body", in: tab, harness: harness) == "rgb(255, 255, 255)")
        #expect(try await style("color", of: "#title", in: tab, harness: harness) == "rgb(17, 17, 17)")
    }

    @Test func eachSwitchToDarkJudgesThePageAsItIsNow() async throws {
        let store = InMemoryPageAppearanceStore(defaultAppearance: .dark)
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        await appColors(.light, store, harness)
        try await waitUntil("light") { tab.darkPages == .inactive }
        _ = try await harness.evaluate("document.body.style.background = '#101010'; 1", in: tab)
        await appColors(.dark, store, harness)
        try await waitUntil("judged again") { tab.darkPages == .native }
        #expect(try await style("backgroundColor", of: "body", in: tab, harness: harness) == "rgb(16, 16, 16)")
    }

    @Test func darkeningComesBackWhenThePageReplacesItsAdoptedSheets() async throws {
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        try await Task.sleep(for: .milliseconds(100))
        _ = try await harness.evaluate("document.adoptedStyleSheets = []; 1", in: tab)
        #expect(try await style("backgroundColor", of: "body", in: tab, harness: harness) == "rgb(255, 255, 255)")
        // No DOM change: the next scroll puts the sheets back, even within the throttle.
        _ = try await harness.evaluate("window.dispatchEvent(new Event('scroll')); 1", in: tab)
        _ = try await harness.evaluate("document.adoptedStyleSheets = []; window.dispatchEvent(new Event('scroll')); 1", in: tab)
        let deadline = ContinuousClock.now + .seconds(3)
        var lum = 1.0
        while ContinuousClock.now < deadline {
            lum = try await luminance("backgroundColor", of: "body", in: tab, harness: harness)
            if lum < 0.02 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(lum < 0.02)
    }

    @Test func aPageWithAnOldChoiceGetsTheSitesCurrentOne() async throws {
        let store = InMemoryPageAppearanceStore(defaultAppearance: .dark)
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        // As if the site were turned off in another tab while this page waited in the
        // back-forward cache: its next report brings it in line.
        store.setAppearance(.off, forSite: "127.0.0.1")
        let webView = try #require(harness.pool.existingWebView(for: tab))
        _ = try await webView.evaluateJavaScript(DarkPages.setChoiceSource(applies: true, siteOff: false), in: nil, contentWorld: UserScripts.world)
        try await waitUntil("corrected") { tab.darkPages == .offForSite }
    }

    @Test func turningItOffForASiteIsRememberedAndAppliesAtOnce() async throws {
        let store = InMemoryPageAppearanceStore(defaultAppearance: .dark)
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        _ = try await harness.evaluate("window.__marker = 3", in: tab)

        await tab.setPageAppearance(.off)
        try await waitUntil("off") { tab.darkPages == .offForSite }
        #expect(store.choices.sites == ["127.0.0.1": .off])
        #expect(try await style("backgroundColor", of: "body", in: tab, harness: harness) == "rgb(255, 255, 255)")
        #expect(try await harness.evaluate("window.__marker", in: tab) as? Int == 3)

        // Another tab on the site, and a reload, stay off. Off screen it is not even checked.
        let other = harness.pool.makeTab()
        try await harness.load("/unstyled", in: other)
        #expect(try await style("backgroundColor", of: "html", in: other, harness: harness) != "rgb(24, 24, 24)")
        #expect(other.darkPages != .darkened)
        tab.reload()
        try await waitUntil("reloaded off") { tab.darkPages == .offForSite && !tab.isLoading }

        await tab.setPageAppearance(nil)
        try await waitUntil("on again") { tab.darkPages == .darkened }
        #expect(store.choices.sites.isEmpty)
        #expect(try await luminance("backgroundColor", of: "body", in: tab, harness: harness) < 0.02)
    }

    @Test func storedListArrivingAfterLaunchReachesOpenWebViews() async throws {
        let store = InMemoryPageAppearanceStore(defaultAppearance: .dark)
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        store.setAppearance(.off, forSite: "127.0.0.1")
        await harness.pool.darkPagesChoicesDidChange()
        tab.reload()
        try await waitUntil("off after the list arrived") { tab.darkPages == .offForSite }
    }

    @Test func privateChoicesStayInThePrivateSession() async throws {
        let store = InMemoryPageAppearanceStore(defaultAppearance: .dark)
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab(isPrivate: true)
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        await tab.setPageAppearance(.off)
        try await waitUntil("off") { tab.darkPages == .offForSite }
        #expect(store.choices.sites.isEmpty)
        let regular = harness.pool.makeTab()
        try await harness.load("/light", in: regular)
        try await waitUntil("regular still darkened") { regular.darkPages == .darkened }
    }

    // MARK: Off by default (docs/research/dark-pages-optin.md)

    @Test func offByDefaultAPageThatCouldUseItIsOnlyReported() async throws {
        let store = InMemoryPageAppearanceStore()
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("checked") { tab.darkPages == .available }
        #expect(tab.darkPagesDocument != nil)
        // Nothing of Plain's touched it: the page as the site made it.
        #expect(try await style("backgroundColor", of: "body", in: tab, harness: harness) == "rgb(255, 255, 255)")
        #expect(try await harness.evaluate("document.adoptedStyleSheets.length", in: tab) as? Int == 0)

        // The switch turned on: darkened at once, no reload.
        _ = try await harness.evaluate("window.__marker = 7", in: tab)
        store.choices.defaultAppearance = .dark
        #expect(await harness.pool.darkPagesChoicesDidChange())
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        #expect(try await harness.evaluate("window.__marker", in: tab) as? Int == 7)
        #expect(try await luminance("backgroundColor", of: "body", in: tab, harness: harness) < 0.02)
    }

    @Test func aSiteSetToDarkIsDarkenedAndSetToOffStaysOff() async throws {
        let store = InMemoryPageAppearanceStore()
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await waitUntil("checked") { tab.darkPages == .available }
        // Dark for this site while there is no default.
        #expect(await tab.setPageAppearance(.dark))
        #expect(store.choices.sites == ["127.0.0.1": .dark])
        try await waitUntil("darkened") { tab.darkPages == .darkened }
        // Off for it: the page as made, and it still says it could use dark.
        await tab.setPageAppearance(.off)
        #expect(store.choices.sites == ["127.0.0.1": .off])
        try await waitUntil("off") { tab.darkPages == .offForSite }
        #expect(try await style("backgroundColor", of: "body", in: tab, harness: harness) == "rgb(255, 255, 255)")
        tab.reload()
        try await waitUntil("reloaded, checked, off") { tab.darkPages == .offForSite && !tab.isLoading }
    }

    @Test func offByDefaultAPageWithItsOwnDarkDesignIsNative() async throws {
        let harness = try await makeHarness(style: .dark, darkPages: InMemoryPageAppearanceStore())
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        for path in ["/dark-media", "/dark-meta", "/already-dark", "/dark-property"] {
            try await harness.load(path, in: tab)
            try await waitUntil("checked \(path)") { tab.darkPages == .native }
        }
    }

    /// Pictures leave the light check's vote: a light page whose hero covers most sample points is
    /// still offered (the Duo's inner screen), a dark shell or a screen of pictures is not.
    @Test func offByDefaultPicturesLeaveTheLightCheck() async throws {
        let harness = try await makeHarness(style: .dark, darkPages: InMemoryPageAppearanceStore())
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light-hero", in: tab)
        try await waitUntil("a light page behind its hero") { tab.darkPages == .available }
        for path in ["/dark-shell", "/all-pictures"] {
            try await harness.load(path, in: tab)
            try await waitUntil("checked \(path)") { tab.darkPages == .native }
        }
    }

    @Test func offByDefaultALightAppReadsNothing() async throws {
        let harness = try await makeHarness(style: .light, darkPages: InMemoryPageAppearanceStore())
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        try await Task.sleep(for: .milliseconds(800))
        #expect(tab.darkPages == .inactive, "never available in light colors: no suggestion, no indicator")
        // Dark, light before the check ran, dark again: the check is not lost.
        harness.window.overrideUserInterfaceStyle = .dark
        harness.pool.interfaceStyle = .dark
        harness.window.overrideUserInterfaceStyle = .light
        harness.pool.interfaceStyle = .light
        harness.window.overrideUserInterfaceStyle = .dark
        harness.pool.interfaceStyle = .dark
        try await waitUntil("checked once dark") { tab.darkPages == .available }
    }

    // MARK: Page appearance apart from Plain's colors

    @Test func darkInALightAppDarkensOnlyThatSite() async throws {
        let store = InMemoryPageAppearanceStore()
        let harness = try await makeHarness(style: .light, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/light", in: tab)
        #expect(try await harness.evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: tab) as? Bool == false)
        await tab.setPageAppearance(.dark)
        try await waitUntil("darkened in a light app") { tab.darkPages == .darkened }
        #expect(try await harness.evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: tab) as? Bool == true)
        #expect(harness.window.traitCollection.userInterfaceStyle == .light, "Plain's own colors never change")
    }

    @Test func lightInADarkAppShowsTheSitesLightDesign() async throws {
        let store = InMemoryPageAppearanceStore(defaultAppearance: .light)
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/dark-media", in: tab)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await harness.evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: tab) as? Bool == false,
                "the default Light reaches a new site, in a dark app")
        // The site's own choice survives the default.
        store.setAppearance(.dark, forSite: "127.0.0.1")
        await harness.pool.darkPagesChoicesDidChange()
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await harness.evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: tab) as? Bool == true)
        store.choices.defaultAppearance = .off
        await harness.pool.darkPagesChoicesDidChange()
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await harness.evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: tab) as? Bool == true,
                "a site's own choice survives a change of the default")
    }

    @Test func pagesLoadedOffScreenGetTheAppsColors() async throws {
        let store = InMemoryPageAppearanceStore(defaultAppearance: .dark)
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        try await harness.load("/dark-media", in: tab)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await harness.evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: tab) as? Bool == true)
        try await waitUntil("judged off screen") { tab.darkPages == .native }
        await appColors(.light, store, harness)
        #expect(try await harness.evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: tab) as? Bool == false)
    }

    /// Main-frame load time of large light-only pages (the 6,600-element page and the apple.com-like
    /// page at store size) darkened, with dark pages off for the site, and in a light app; the
    /// script's own time on each page, when the first darkened frame came relative to
    /// DOMContentLoaded, and the engine's work from scratch. Medians of several loads; the
    /// machine's load is printed with them.
    @Test(arguments: ["/big", "/apple-big"])
    func largePageCost(path: String) async throws {
        let store = InMemoryPageAppearanceStore(defaultAppearance: .dark)
        let harness = try await makeHarness(style: .dark, darkPages: store)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        let clock = ContinuousClock()
        let elements = try await {
            try await harness.load(path, in: tab)
            return try await harness.evaluate("document.querySelectorAll('*').length", in: tab) as? Int ?? 0
        }()
        report("dark pages \(path): \(elements) elements")
        func measure(_ label: String, expect state: DarkPagesState) async throws {
            var loads: [Duration] = []
            var costs: [Double] = []
            var firstFrames: [Double] = []
            var allDone: [Double] = []
            for _ in 0..<7 {
                let start = clock.now
                try await harness.load("\(path)?\(UUID().uuidString)", in: tab)
                loads.append(clock.now - start)
                // Off for the site, a page reports `off` only when its light check says it could
                // use dark pages; one with a dark first screen (the apple-like hero) is `native`.
                try await waitUntil("\(label) state") {
                    tab.darkPages == state || (state == .offForSite && tab.darkPages == .native)
                }
                if state == .darkened { try await settle(tab, harness: harness) }
                let stats = try await webView.evaluateJavaScript(
                    "globalThis.__plainDarkPages ? globalThis.__plainDarkPages.stats : null", in: nil, contentWorld: UserScripts.world
                ) as? [String: Any]
                func number(_ key: String) -> Double { (stats?[key] as? Double) ?? Double((stats?[key] as? Int) ?? -1) }
                costs.append(number("cost"))
                if state == .darkened {
                    firstFrames.append(number("firstDark") - number("dcl"))
                    allDone.append(number("firstPatchDone") - number("dcl"))
                }
            }
            costs.sort()
            var line = "dark pages \(path) \(label): load \(describe(loads)); script median \(String(format: "%.2f", costs[costs.count / 2])) ms, max \(String(format: "%.2f", costs.last ?? 0)) ms"
            if state == .darkened {
                firstFrames.sort(); allDone.sort()
                line += String(format: "; darkened at DCL%+.1f ms (median), every element checked at DCL%+.1f ms",
                               firstFrames[firstFrames.count / 2], allDone[allDone.count / 2])
                let bench = try await webView.evaluateJavaScript(
                    "globalThis.__plainDarkPages.bench(5)", in: nil, contentWorld: UserScripts.world
                ) as? [String: Any]
                report("dark pages \(path) from scratch per run: \(bench ?? [:])")
                let stats = try await webView.evaluateJavaScript(
                    "globalThis.__plainDarkPages.stats", in: nil, contentWorld: UserScripts.world
                ) as? [String: Any]
                report("dark pages \(path) last stats: \(stats ?? [:])")
            }
            report(line)
        }
        report("load average: \(ProcessInfo.processInfo.loadAverage)")
        // A warm-up round first, so the first mode measured doesn't pay for JIT and caches; then
        // the modes interleaved twice.
        for round in 0..<3 {
            let tag = round == 0 ? " (warm-up)" : ""
            try await measure("darkened\(tag)", expect: .darkened)
            store.setAppearance(.off, forSite: "127.0.0.1")
            await harness.pool.darkPagesChoicesDidChange()
            try await measure("off for site\(tag)", expect: .offForSite)
            store.setAppearance(nil, forSite: "127.0.0.1")
            await harness.pool.darkPagesChoicesDidChange()
            await appColors(.light, store, harness)
            try await measure("light app\(tag)", expect: .inactive)
            await appColors(.dark, store, harness)
        }
    }

    /// Real sites, on request (`TEST_RUNNER_PLAIN_DARK_REAL=1`, needs the network): the engine's
    /// time, when the first darkened frame came, and the contrast of every visible text.
    @Test(arguments: ["https://www.apple.com/", "https://www.wikipedia.org/", "https://apnews.com/", "https://news.ycombinator.com/"])
    func realSites(address: String) async throws {
        guard ProcessInfo.processInfo.environment["PLAIN_DARK_REAL"] == "1" else { return }
        let harness = try await makeHarness(style: .dark)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        tab.load(try #require(URL(string: address)))
        try await waitUntil("loaded \(address)", timeout: .seconds(40)) { !tab.isLoading && tab.url != nil && tab.darkPages != .inactive }
        try await Task.sleep(for: .seconds(2))
        report("dark pages real \(address): \(tab.darkPages)")
        guard tab.darkPages == .darkened else { return }
        try await settle(tab, harness: harness)
        let stats = try await engine("globalThis.__plainDarkPages.stats", in: tab, harness: harness) as? [String: Any]
        let rows = try await audit(tab, harness: harness)
        let failing = rows.filter { $0.ratio < 4.5 }
        report("dark pages real \(address): stats \(stats ?? [:])")
        report("dark pages real \(address): \(rows.count) texts, \(failing.count) under 4.5, min \(rows.map(\.ratio).min() ?? 0); first failing \(failing.prefix(8))")
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
