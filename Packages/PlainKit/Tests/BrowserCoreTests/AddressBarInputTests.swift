import BrowserCore
import Foundation
import Testing

@Suite struct AddressBarInputTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("swift.org/documentation", "https://swift.org/documentation"),
        ("  Apple.com  ", "https://Apple.com"),
        ("https://www.apple.com/iphone", "https://www.apple.com/iphone"),
        ("http://neverssl.com", "http://neverssl.com"),
        ("about:blank", "about:blank"),
        ("localhost:8080", "http://localhost:8080"),
        ("192.168.1.1", "http://192.168.1.1"),
        ("10.0.0.2:3000/admin", "http://10.0.0.2:3000/admin"),
    ])
    func urls(text: String, expected: String) {
        #expect(AddressBarInput(text) == .url(URL(string: expected)!))
    }

    @Test(arguments: [
        "hello world",
        "swift",
        "what is example.com",
        "3.14",
        "999.1.1.1",
        "foo.",
        "https://",
        "mailto:me@example.com",
    ])
    func searches(text: String) {
        #expect(AddressBarInput(text) == .search(text))
    }

    @Test func emptyTextIsNothing() {
        #expect(AddressBarInput("") == nil)
        #expect(AddressBarInput(" \n\t") == nil)
    }
}
