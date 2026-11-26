import BrowserCore
import Foundation
import Synchronization
import Testing

@Suite struct SuggestionParsingTests {
    @Test(arguments: [
        (SuggestionSource.google, SuggestionFixtures.google, 10, "swift ui documentation"),
        (.duckDuckGo, SuggestionFixtures.duckDuckGo, 8, "swift ui tutorial"),
        (.brave, SuggestionFixtures.brave, 8, "swiftui tutorial"),
        (.kagi, SuggestionFixtures.kagi, 10, "swift ui windows"),
    ])
    func recordedResponsesParse(source: SuggestionSource, body: String, count: Int, second: String) throws {
        let suggestions = try source.parse(Data(body.utf8))
        #expect(suggestions.count == count)
        #expect(suggestions[1] == second)
    }

    @Test func startpageDuplicatesAreDropped() throws {
        #expect(try SuggestionSource.startpage.parse(Data(SuggestionFixtures.startpage.utf8)) == ["swift ui"])
    }

    @Test func unicodeSurvives() throws {
        let suggestions = try SuggestionSource.google.parse(Data(SuggestionFixtures.googleUnicode.utf8))
        #expect(suggestions == ["café", "café au lait", "café de flore"])
    }

    @Test func latin1BodyIsDecodedWithItsCharset() throws {
        let body = try #require(#"["caf\#u{e9}",["caf\#u{e9} noir"]]"#.data(using: .isoLatin1))
        #expect(try SuggestionSource.google.parse(body, textEncoding: .isoLatin1) == ["café noir"])
    }

    @Test func blanksAreSkipped() throws {
        let body = Data(#"["q",["  ", "a", 3, "A ", null, "b"]]"#.utf8)
        #expect(try SuggestionSource.duckDuckGo.parse(body) == ["a", "b"])
    }

    @Test(arguments: [#"{"q": []}"#, #"["q"]"#, "<html>", "", #"["q", "not a list"]"#])
    func malformedBodiesThrow(body: String) {
        #expect(throws: (any Error).self) { try SuggestionSource.duckDuckGo.parse(Data(body.utf8)) }
    }

    @Test(arguments: [
        (SuggestionSource.google, "https://suggestqueries.google.com/complete/search?client=firefox&q=a%2Bb%26c%20d"),
        (.duckDuckGo, "https://duckduckgo.com/ac/?q=a%2Bb%26c%20d&type=list"),
        (.brave, "https://search.brave.com/api/suggest?q=a%2Bb%26c%20d"),
        (.kagi, "https://kagi.com/api/autosuggest?q=a%2Bb%26c%20d"),
        (.startpage, "https://www.startpage.com/osuggestions?q=a%2Bb%26c%20d"),
    ])
    func endpoints(source: SuggestionSource, expected: String) {
        #expect(source.endpoint(for: "a+b&c d")?.absoluteString == expected)
    }
}

/// A fake network: records requests and answers through `handler`.
final class FakeHTTP: HTTPLoading {
    let requests = Mutex<[URL]>([])
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.withLock { $0.append(request.url!) }
        return try await handler(request)
    }

    var requestCount: Int { requests.withLock(\.count) }

    static func ok(_ body: String, status: Int = 200, charset: String = "utf-8") -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=\(charset)"]
            )!
            return (Data(body.utf8), response)
        }
    }
}

@Suite struct SuggestionClientTests {
    @Test func fetchesFromTheEngineSourceAndCapsTheList() async throws {
        let http = FakeHTTP(handler: FakeHTTP.ok(SuggestionFixtures.kagi))
        let client = SuggestionClient(http: http, limit: 3)
        let suggestions = try await client.suggestions(for: " swift ui ", engine: .kagi)
        #expect(suggestions == ["swift ui tutorial", "swift ui windows", "swift uikit"])
        #expect(http.requests.withLock(\.self).map(\.host) == ["kagi.com"])
    }

    @Test func enginesWithoutEndpointsAskDuckDuckGo() async throws {
        let http = FakeHTTP(handler: FakeHTTP.ok(SuggestionFixtures.duckDuckGo))
        let client = SuggestionClient(http: http)
        _ = try await client.suggestions(for: "swift ui", engine: .bing)
        _ = try await client.suggestions(for: "swift ui", engine: try .custom(name: "X", template: "https://x.example/?q=%s"))
        #expect(http.requests.withLock(\.self).map(\.host) == ["duckduckgo.com", "duckduckgo.com"])
    }

    @Test func blankQueryMakesNoRequest() async throws {
        let http = FakeHTTP(handler: FakeHTTP.ok(SuggestionFixtures.google))
        let client = SuggestionClient(http: http)
        #expect(try await client.suggestions(for: "   ", engine: .google).isEmpty)
        #expect(http.requestCount == 0)
    }

    @Test func badStatusThrows() async {
        let client = SuggestionClient(http: FakeHTTP(handler: FakeHTTP.ok("", status: 503)))
        await #expect(throws: SuggestionError.badStatus(503)) {
            try await client.suggestions(for: "a", engine: .google)
        }
    }

    @Test func slowServerTimesOut() async {
        let http = FakeHTTP { _ in
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        let client = SuggestionClient(http: http, timeout: .milliseconds(50))
        let start = ContinuousClock.now
        await #expect(throws: SuggestionError.timedOut) {
            try await client.suggestions(for: "a", engine: .google)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func deadlineHoldsEvenIfTheLoaderIgnoresCancellation() async {
        let http = FakeHTTP { request in
            // Not cancellable: resumes after 3 s whatever happens to the task.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
            }
            return try await FakeHTTP.ok(SuggestionFixtures.google)(request)
        }
        let client = SuggestionClient(http: http, timeout: .milliseconds(50))
        let start = ContinuousClock.now
        await #expect(throws: SuggestionError.timedOut) {
            try await client.suggestions(for: "a", engine: .google)
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func newKeystrokeCancelsThePreviousRequest() async throws {
        let http = FakeHTTP { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value
            if query == "s" {
                // Hold the first keystroke's request until it is cancelled.
                try await Task.sleep(for: .seconds(30))
            }
            return try await FakeHTTP.ok(SuggestionFixtures.google)(request)
        }
        let client = SuggestionClient(http: http, timeout: .seconds(60))

        let first = Task { try await client.suggestions(for: "s", engine: .google) }
        while http.requestCount == 0 { await Task.yield() }

        let start = ContinuousClock.now
        let second = try await client.suggestions(for: "sw", engine: .google)
        #expect(second.first == "swift ui")

        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func callerCancellationStopsTheRequest() async {
        let http = FakeHTTP { _ in
            try await Task.sleep(for: .seconds(30))
            return (Data(), URLResponse())
        }
        let client = SuggestionClient(http: http, timeout: .seconds(60))
        let task = Task { try await client.suggestions(for: "a", engine: .google) }
        while http.requestCount == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
