import BrowserCore
import Foundation
import Testing

@Suite struct SuggestionPolicyTests {
    @Test(arguments: [
        // Addresses, typed or on the way.
        "github.com", "github.com/apple/swift", "github.", "github.c", "www.", "www.goo",
        "nas.local", "printer.home", "en.wikipedia.org/wiki/Swift",
        // Pasted URLs, with or without words after them.
        "https://example.com/private?token=1", "http://intranet", "https://x.example/a look at this",
        "about:config", "file:///etc/hosts", "mailto:me@example.com",
        // Intranet and local names.
        "localhost", "localhost:3000", "intranet/", "intranet?q=1", "wiki/team", "nas:8080", "[::1]", "[fe80::1]:80",
        // IP addresses, whole or partial.
        "192.168.1.1", "192.168.", "10.0.0", "127.0.0.1:8080", "8.8.8.8", "::1", "fe80::1%en0",
        // An address with a path, port or local host, followed by words.
        "localhost/private note", "localhost login", "nas:8080 login", "10.0.0.1 router",
        "github.com/me/secret-repo issues", "::1 admin", "localhost?token=secret note",
        "example.com?token=secret note", "example.com#private note", "example.com?token=x",
        "intranet/private?token=secret note", "wiki/team notes",
    ])
    func addressesStayLocal(text: String) {
        #expect(!SuggestionPolicy.allowsRemote(text), "\(text)")
    }

    @Test(arguments: [
        "swift", "swift ui", "weather tomorrow", "c++", "define:", "3.14", "v1.2", "how to use github.com",
        "U.S. election", "node js", "café", "what is 192 168", "github.com down", "c++ tips", "and/or examples",
        "ac/dc songs", "AC/DC", "24/7 pharmacy", "1/2 cup in grams", "tcp/ip", "w/o",
    ])
    func searchesGoToTheEngine(text: String) {
        #expect(SuggestionPolicy.allowsRemote(text), "\(text)")
    }

    @Test func blankIsNotSent() {
        #expect(!SuggestionPolicy.allowsRemote("   "))
    }
}

@Suite struct SuggestionClientPrivacyTests {
    @Test func urlLikeInputMakesNoRequest() async throws {
        let http = FakeHTTP(handler: FakeHTTP.ok(SuggestionFixtures.google))
        let client = SuggestionClient(http: http)
        for text in ["github.com", "https://example.com/a", "localhost:8080", "192.168.1.1", "intranet/"] {
            #expect(try await client.suggestions(for: text, engine: .google).isEmpty)
        }
        #expect(http.requestCount == 0)
    }

    @Test func privateTabsGetNoRemoteSuggestions() async throws {
        #expect(FixedChoices.remoteSuggestionsInPrivateTabs == false)
        let http = FakeHTTP(handler: FakeHTTP.ok(SuggestionFixtures.google))
        let client = SuggestionClient(http: http)
        #expect(try await client.suggestions(for: "swift ui", engine: .google, isPrivate: true).isEmpty)
        #expect(await client.preconnect(engine: .google, isPrivate: true) == nil)
        #expect(http.requestCount == 0)

        // A normal tab's answer is cached, and a private tab still sees none of it.
        _ = try await client.suggestions(for: "swift ui", engine: .google)
        #expect(await client.cachedSuggestions(for: "swift ui", engine: .google, isPrivate: true).isEmpty)
    }
}

@Suite struct SuggestionCacheTests {
    @Test func repeatedQueryIsAnsweredFromTheCache() async throws {
        let http = FakeHTTP(handler: FakeHTTP.ok(SuggestionFixtures.google))
        let client = SuggestionClient(http: http)
        let first = try await client.suggestions(for: "swift ui", engine: .google)
        let second = try await client.suggestions(for: "Swift UI ", engine: .google)
        #expect(first == second)
        #expect(http.requestCount == 1)
        // Another engine's source is a separate entry.
        _ = try await client.suggestions(for: "swift ui", engine: .kagi)
        #expect(http.requestCount == 2)
    }

    @Test func longestCachedPrefixFillsInWhileTyping() async throws {
        let http = FakeHTTP(handler: FakeHTTP.ok(SuggestionFixtures.google))
        let client = SuggestionClient(http: http)
        #expect(await client.cachedSuggestions(for: "swift ui c", engine: .google).isEmpty)
        _ = try await client.suggestions(for: "swift ui", engine: .google)

        // "swift ui" is cached; "swift ui c" keeps the suggestions that still start with it.
        #expect(await client.cachedSuggestions(for: "swift ui c", engine: .google)
            == ["swift ui components"])
        #expect(await client.cachedSuggestions(for: "swift ui", engine: .google).first == "swift ui")
        #expect(await client.cachedSuggestions(for: "swift uz", engine: .google).isEmpty)
        #expect(http.requestCount == 1)
    }

    @Test func leastRecentlyUsedEntriesAreEvicted() async throws {
        let http = FakeHTTP(handler: FakeHTTP.ok(SuggestionFixtures.google))
        let client = SuggestionClient(http: http, cacheSize: 2)
        _ = try await client.suggestions(for: "a", engine: .google)
        _ = try await client.suggestions(for: "b", engine: .google)
        _ = try await client.suggestions(for: "a", engine: .google) // hit; "b" is now the oldest
        _ = try await client.suggestions(for: "c", engine: .google) // evicts "b"
        #expect(http.requestCount == 3)
        _ = try await client.suggestions(for: "a", engine: .google)
        #expect(http.requestCount == 3)
        _ = try await client.suggestions(for: "b", engine: .google)
        #expect(http.requestCount == 4)
    }

    @Test func staleEntriesAreAskedAgain() async throws {
        let http = FakeHTTP(handler: FakeHTTP.ok(SuggestionFixtures.google))
        let client = SuggestionClient(http: http, cacheLifetime: .zero)
        _ = try await client.suggestions(for: "a", engine: .google)
        _ = try await client.suggestions(for: "a", engine: .google)
        #expect(http.requestCount == 2)
    }

    @Test func failuresAreNotCached() async throws {
        let http = FakeHTTP(handler: FakeHTTP.ok("", status: 503))
        let client = SuggestionClient(http: http)
        _ = try? await client.suggestions(for: "a", engine: .google)
        _ = try? await client.suggestions(for: "a", engine: .google)
        #expect(http.requestCount == 2)
    }
}

@Suite struct SuggestionPreconnectTests {
    @Test func preconnectSendsOneEmptyHeadRequestToTheSuggestionHost() async throws {
        let methods = Methods()
        let http = FakeHTTP { request in
            await methods.add(request.httpMethod ?? "GET")
            return try await FakeHTTP.ok(SuggestionFixtures.kagi)(request)
        }
        let client = SuggestionClient(http: http)
        await client.preconnect(engine: .google)?.value
        // Focusing again soon after does nothing: the connection is still warm.
        #expect(await client.preconnect(engine: .google) == nil)
        let urls = http.requests.withLock(\.self)
        #expect(urls.map(\.host) == ["suggestqueries.google.com"])
        #expect(urls.first?.query?.contains("q=") == true)
        #expect(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value == "")
        #expect(await methods.all == ["HEAD"])

        // A suggestion request also counts as contact with that host.
        _ = try await client.suggestions(for: "swift", engine: .kagi)
        #expect(await client.preconnect(engine: .kagi) == nil)
    }

    actor Methods {
        var all: [String] = []
        func add(_ method: String) { all.append(method) }
    }
}
