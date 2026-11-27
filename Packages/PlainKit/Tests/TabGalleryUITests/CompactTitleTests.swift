import Foundation
import Testing
@testable import TabGalleryUI

/// The strip's and the sidebar's short titles.
@MainActor
struct CompactTitleTests {
    func item(_ title: String, _ url: String) -> TabGalleryItem {
        TabGalleryItem(id: UUID(), title: title, url: URL(string: url))
    }

    @Test func dropsTheSiteNameAtTheEnd() {
        #expect(item("Web browser - Wikipedia", "https://en.wikipedia.org/wiki/Web_browser").compactTitle == "Web browser")
        #expect(item("Safari (web browser) – Wikipedia", "https://en.wikipedia.org/wiki/Safari").compactTitle == "Safari (web browser)")
        #expect(item("Pull requests · apple/swift · GitHub", "https://github.com/apple/swift/pulls").compactTitle == "Pull requests · apple/swift")
    }

    @Test func keepsTitlesWithoutTheSiteNameAtTheEnd() {
        #expect(item("The Verge | Tech news", "https://www.theverge.com").compactTitle == "The Verge | Tech news")
        #expect(item("A - B", "https://example.com").compactTitle == "A - B")
        #expect(item("", "https://example.com/x").compactTitle == "example.com")
        #expect(item("Wikipedia", "https://wikipedia.org").compactTitle == "Wikipedia")
    }
}
