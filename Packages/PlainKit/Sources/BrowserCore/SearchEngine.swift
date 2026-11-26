import Foundation

/// A search engine, described by a results-page template where `%s` stands for the query.
public struct SearchEngine: Equatable, Sendable {
    public let name: String
    public let template: String

    public init(name: String, template: String) {
        self.name = name
        self.template = template
    }

    /// The first-launch default (docs/plan.md, section 11).
    public static let google = SearchEngine(name: "Google", template: "https://www.google.com/search?q=%s")

    /// The results page for `query`. The query is percent-encoded so that `&`, `=`, `+` and `#`
    /// stay part of the query instead of changing the URL's structure.
    public func resultsURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// RFC 3986 unreserved characters only.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
}

extension AddressBarInput {
    /// The URL to load for this input, searching with `engine` when it is a search.
    public func destination(searchingWith engine: SearchEngine) -> URL? {
        switch self {
        case .url(let url): url
        case .search(let query): engine.resultsURL(for: query)
        }
    }
}
