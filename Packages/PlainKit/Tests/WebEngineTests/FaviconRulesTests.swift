import BrowserCore
import Foundation
import Testing
@testable import WebEngine

/// Which of a page's icons is fetched, and how an icon sits on its tile: pure rules, so they also
/// run on macOS.
@Suite struct FaviconRulesTests {
    let page = URL(string: "https://www.example.com/news/today?x=1#top")!

    @Test func siteKeyIsTheHostWithoutWww() {
        #expect(FaviconRules.siteKey(for: page) == "example.com")
        #expect(FaviconRules.siteKey(for: URL(string: "http://EN.Wikipedia.org/wiki/A")) == "en.wikipedia.org")
        #expect(FaviconRules.siteKey(for: URL(string: "about:blank")) == nil)
        #expect(FaviconRules.siteKey(for: URL(string: "file:///tmp/a.html")) == nil)
        #expect(FaviconRules.siteKey(for: nil) == nil)
    }

    @Test func declaredSizeReadsTheLargestSide() {
        #expect(FaviconRules.declaredSize("32x32") == 32)
        #expect(FaviconRules.declaredSize("16x16 48X48 32x32") == 48)
        #expect(FaviconRules.declaredSize("any") == 0)
        #expect(FaviconRules.declaredSize("") == 0)
    }

    @Test func vectorAndInsecureIconsAreLeftOut() {
        #expect(FaviconRules.candidate(href: "https://example.com/i.svg", isTouchIcon: false, sizes: "any", type: "", page: page) == nil)
        #expect(FaviconRules.candidate(href: "https://example.com/i", isTouchIcon: false, sizes: "", type: "image/svg+xml", page: page) == nil)
        #expect(FaviconRules.candidate(href: "http://example.com/i.png", isTouchIcon: false, sizes: "", type: "", page: page) == nil)
        #expect(FaviconRules.candidate(href: "data:image/png;base64,AAAA", isTouchIcon: false, sizes: "", type: "", page: page) == nil)
        let plain = URL(string: "http://example.com/")!
        #expect(FaviconRules.candidate(href: "http://example.com/i.png", isTouchIcon: false, sizes: "", type: "", page: plain) != nil)
        let kept = FaviconRules.candidate(href: "https://cdn.example.com/i.png", isTouchIcon: true, sizes: "180x180", type: "image/png", page: page)
        #expect(kept == FaviconCandidate(url: URL(string: "https://cdn.example.com/i.png")!, isTouchIcon: true, declaredSize: 180))
    }

    @Test func theSmallestIconThatIsLargeEnoughComesFirst() {
        func icon(_ name: String, touch: Bool = false, size: Int = 0) -> FaviconCandidate {
            FaviconCandidate(url: URL(string: "https://example.com/\(name)")!, isTouchIcon: touch, declaredSize: size)
        }
        let ranked = FaviconRules.ranked(
            [icon("16.png", size: 16), icon("touch.png", touch: true), icon("192.png", size: 192), icon("96.png", size: 96), icon("32.png", size: 32)],
            page: page
        ).map(\.lastPathComponent)
        // 96 is the smallest at least 60 px; then the touch icon (180), then 192; the small ones
        // give way to /favicon.ico, always the last try.
        #expect(ranked == ["96.png", "touch.png", "192.png", "favicon.ico"])
        #expect(ranked.count == FixedChoices.faviconAttempts)
    }

    @Test func aPageWithNoIconsFallsBackToFaviconIco() {
        #expect(FaviconRules.ranked([], page: page) == [URL(string: "https://www.example.com/favicon.ico")!])
        let local = URL(string: "http://127.0.0.1:8080/a/b?c")!
        #expect(FaviconRules.ranked([], page: local) == [URL(string: "http://127.0.0.1:8080/favicon.ico")!])
    }

    @Test func smallIconsAreTriedLargestFirst() {
        let small = [16, 48, 32].map {
            FaviconCandidate(url: URL(string: "https://example.com/\($0).png")!, isTouchIcon: false, declaredSize: $0)
        }
        #expect(FaviconRules.ranked(small, page: page).map(\.lastPathComponent) == ["48.png", "32.png", "16.png", "favicon.ico"])
    }

    @Test func aPublicPageCannotSendTheDownloadIntoTheLocalNetwork() {
        let allowed = { (url: String, page: URL) in FaviconRules.allows(URL(string: url)!, from: page) }
        #expect(allowed("https://cdn.example.com/i.png", page))
        #expect(!allowed("https://user:secret@example.com/i.png", page), "no credentials in the address")
        #expect(!allowed("http://example.com/i.png", page), "no plain HTTP for an HTTPS page")
        #expect(!allowed("ftp://example.com/i.png", page))
        for local in ["localhost", "127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.4.2", "169.254.169.254", "100.64.0.1",
                      "printer.local", "router", "[::1]", "[fe80::1]", "[fd00::2]", "0.0.0.0", "2130706433", "0x7f000001"] {
            #expect(!allowed("https://\(local)/favicon.ico", page), "\(local)")
        }
        // A page on the local network may show its own icon, and only its own.
        let home = URL(string: "http://192.168.1.10:8080/admin")!
        #expect(allowed("http://192.168.1.10:8080/favicon.ico", home))
        #expect(!allowed("http://192.168.1.1/favicon.ico", home))
        #expect(allowed("https://example.com/i.png", home))
    }

    @Test func styleFollowsThePixels() {
        // Opaque edge to edge: the icon is the tile.
        #expect(SiteIconStyle.style(clear: 0, dark: 0.9, light: 0) == .tile)
        #expect(SiteIconStyle.style(clear: 0.04, dark: 0, light: 0.2) == .tile)
        // One dark shape on a clear ground needs a light tile at night; one light shape a dark one.
        #expect(SiteIconStyle.style(clear: 0.5, dark: 0.95, light: 0) == .darkGlyph)
        #expect(SiteIconStyle.style(clear: 0.5, dark: 0, light: 0.9) == .lightGlyph)
        // Colors show on either.
        #expect(SiteIconStyle.style(clear: 0.5, dark: 0.3, light: 0.3) == .glyph)
    }
}
