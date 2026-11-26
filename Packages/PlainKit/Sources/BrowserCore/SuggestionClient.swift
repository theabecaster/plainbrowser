import Foundation

/// Loads one HTTP request. `URLSession` conforms; tests inject a fake so they never touch the
/// network.
public protocol HTTPLoading: Sendable {
    func load(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPLoading {
    public func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// A search-suggestion endpoint and the parser for its response.
///
/// Every endpoint verified on 2026-11-26 answers in the OpenSearch suggestions format:
/// `["query", ["suggestion", ...], ...]`. Engines without a working endpoint use DuckDuckGo.
public enum SuggestionSource: String, Hashable, Sendable, Codable, CaseIterable {
    case google
    case duckDuckGo
    case brave
    case kagi
    case startpage

    /// The request URL for `query`. The query is percent-encoded strictly (unreserved characters
    /// only), so `+`, `&` and `#` reach the server as part of the query.
    public func endpoint(for query: String) -> URL? {
        let base: String
        var items: [(String, String)] = []
        switch self {
        case .google:
            base = "https://suggestqueries.google.com/complete/search"
            items = [("client", "firefox"), ("q", query)]
        case .duckDuckGo:
            base = "https://duckduckgo.com/ac/"
            items = [("q", query), ("type", "list")]
        case .brave:
            base = "https://search.brave.com/api/suggest"
            items = [("q", query)]
        case .kagi:
            base = "https://kagi.com/api/autosuggest"
            items = [("q", query)]
        case .startpage:
            base = "https://www.startpage.com/osuggestions"
            items = [("q", query)]
        }
        var components = URLComponents(string: base)
        components?.percentEncodedQueryItems = items.map { name, value in
            URLQueryItem(
                name: name,
                value: value.addingPercentEncoding(withAllowedCharacters: SearchEngine.queryValueAllowed)
            )
        }
        return components?.url
    }

    /// Suggestions from a response body, in the server's order, trimmed and without blanks or
    /// duplicates (Startpage repeats entries). Throws when the body is not the expected format.
    public func parse(_ data: Data, textEncoding: String.Encoding = .utf8) throws -> [String] {
        // JSONSerialization only reads Unicode. Re-encode bodies a server sent in another charset.
        var body = data
        if textEncoding != .utf8, let text = String(data: data, encoding: textEncoding) {
            body = Data(text.utf8)
        }
        guard let root = try JSONSerialization.jsonObject(with: body) as? [Any], root.count >= 2,
              let list = root[1] as? [Any]
        else { throw SuggestionError.unexpectedFormat }

        var seen = Set<String>()
        var result: [String] = []
        for case let item as String in list {
            let suggestion = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suggestion.isEmpty, seen.insert(suggestion.lowercased()).inserted else { continue }
            result.append(suggestion)
        }
        return result
    }
}

public enum SuggestionError: Error, Equatable, Sendable {
    case unexpectedFormat
    case badStatus(Int)
    case timedOut
}

/// Fetches search suggestions as the user types.
///
/// Each call cancels the request still running from the previous keystroke, so only the newest
/// query's answer is ever returned. A superseded call throws `CancellationError`; callers ignore
/// it. Requests give up after `timeout`, so a slow server never holds suggestions back for long.
public actor SuggestionClient {
    private let http: any HTTPLoading
    private let timeout: Duration
    private let limit: Int
    private var current: Task<[String], any Error>?

    public init(
        http: any HTTPLoading = SuggestionClient.makeSession(),
        timeout: Duration = FixedChoices.suggestionTimeout,
        limit: Int = FixedChoices.maxSearchSuggestions
    ) {
        self.http = http
        self.timeout = timeout
        self.limit = limit
    }

    /// A session for suggestion requests only: ephemeral (no cookies, cache or credentials are
    /// kept), so typing never leaves a trail on disk or identifies the user to the engine.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = FixedChoices.suggestionTimeout.seconds
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Suggestions for `query` from `engine`'s source. Returns an empty list for blank input
    /// without a request.
    public func suggestions(for query: String, engine: SearchEngine) async throws -> [String] {
        current?.cancel()
        current = nil

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = engine.suggestionSource.endpoint(for: trimmed) else { return [] }

        let source = engine.suggestionSource
        let http = http
        let timeout = timeout
        let limit = limit
        let task = Task<[String], any Error> {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout.seconds
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let finalRequest = request
            let (data, response) = try await Self.withTimeout(timeout) { try await http.load(finalRequest) }
            try Task.checkCancellation()

            var encoding = String.Encoding.utf8
            if let http = response as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode) else { throw SuggestionError.badStatus(http.statusCode) }
                encoding = Self.encoding(of: http)
            }
            return Array(try source.parse(data, textEncoding: encoding).prefix(limit))
        }
        current = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels the request in flight, if any. Call when the address bar closes.
    public func cancel() {
        current?.cancel()
        current = nil
    }

    private static func encoding(of response: HTTPURLResponse) -> String.Encoding {
        guard let name = response.textEncodingName else { return .utf8 }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// Runs `operation`, throwing `SuggestionError.timedOut` if it takes longer than `timeout`.
    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SuggestionError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
