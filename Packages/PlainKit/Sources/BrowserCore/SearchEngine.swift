import Foundation

/// A search engine, described by a results-page template where `%s` stands for the query.
///
/// The catalog (`SearchEngine.catalog`) holds the engines Plain offers in Settings. A custom engine
/// comes from `SearchEngine.custom(name:template:)`, which validates the template.
public struct SearchEngine: Hashable, Sendable, Codable, Identifiable {
    /// Stable identifier, stored in settings. Built-in engines use a fixed slug; custom engines use
    /// `SearchEngine.customID`.
    public let id: String
    public let name: String
    public let template: String
    /// Where address-bar suggestions for this engine come from.
    public let suggestionSource: SuggestionSource

    /// The placeholder replaced by the percent-encoded query.
    public static let queryPlaceholder = "%s"
    /// The `id` every custom engine shares. There is only ever one custom engine.
    public static let customID = "custom"

    init(id: String, name: String, template: String, suggestionSource: SuggestionSource) {
        self.id = id
        self.name = name
        self.template = template
        self.suggestionSource = suggestionSource
    }

    public var isCustom: Bool { id == Self.customID }

    /// The results page for `query`. The query is percent-encoded so that `&`, `=`, `+` and `#`
    /// stay part of the query instead of changing the URL's structure.
    public func resultsURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: Self.queryPlaceholder, with: encoded))
    }

    /// The query `url` searches for, when it is this engine's results page: same host (`www.`
    /// aside) and path as the template, with the query in the template's parameter. Nil for any
    /// other page, so the pill shows the query on results pages only (as Safari does) and the
    /// host everywhere else.
    public func query(inResults url: URL) -> String? {
        guard let page = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let form = URLComponents(string: template.replacingOccurrences(of: Self.queryPlaceholder, with: "QUERY")),
              let name = form.queryItems?.first(where: { $0.value == "QUERY" })?.name,
              Self.bareHost(page.host) == Self.bareHost(form.host), !Self.bareHost(page.host).isEmpty,
              page.path == form.path || (page.path.isEmpty && form.path == "/") || (form.path.isEmpty && page.path == "/"),
              let encoded = page.percentEncodedQueryItems?.first(where: { $0.name == name })?.value,
              // A form's "+" is a space; an encoded plus (%2B) stays a plus.
              let value = encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        else { return nil }
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    private static func bareHost(_ host: String?) -> String {
        let host = (host ?? "").lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// RFC 3986 unreserved characters only.
    static let queryValueAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
}

// MARK: - Catalog

extension SearchEngine {
    /// The first-launch default (docs/plan.md, section 11).
    public static let google = SearchEngine(
        id: "google", name: "Google",
        template: "https://www.google.com/search?q=%s", suggestionSource: .google
    )
    public static let duckDuckGo = SearchEngine(
        id: "duckduckgo", name: "DuckDuckGo",
        template: "https://duckduckgo.com/?q=%s", suggestionSource: .duckDuckGo
    )
    /// Bing's own suggestion endpoint is dead (docs/research/notes.md), so it uses DuckDuckGo's.
    public static let bing = SearchEngine(
        id: "bing", name: "Bing",
        template: "https://www.bing.com/search?q=%s", suggestionSource: .duckDuckGo
    )
    public static let brave = SearchEngine(
        id: "brave", name: "Brave Search",
        template: "https://search.brave.com/search?q=%s", suggestionSource: .brave
    )
    public static let kagi = SearchEngine(
        id: "kagi", name: "Kagi",
        template: "https://kagi.com/search?q=%s", suggestionSource: .kagi
    )
    public static let ecosia = SearchEngine(
        id: "ecosia", name: "Ecosia",
        template: "https://www.ecosia.org/search?q=%s", suggestionSource: .duckDuckGo
    )
    public static let startpage = SearchEngine(
        id: "startpage", name: "Startpage",
        template: "https://www.startpage.com/sp/search?query=%s", suggestionSource: .startpage
    )
    public static let yahoo = SearchEngine(
        id: "yahoo", name: "Yahoo",
        template: "https://search.yahoo.com/search?p=%s", suggestionSource: .duckDuckGo
    )
    public static let perplexity = SearchEngine(
        id: "perplexity", name: "Perplexity",
        template: "https://www.perplexity.ai/search?q=%s", suggestionSource: .duckDuckGo
    )
    public static let chatGPT = SearchEngine(
        id: "chatgpt", name: "ChatGPT",
        template: "https://chatgpt.com/?q=%s", suggestionSource: .duckDuckGo
    )

    /// The engines offered in Settings, in display order. The custom engine is not in this list.
    public static let catalog: [SearchEngine] = [
        .google, .duckDuckGo, .bing, .brave, .kagi, .ecosia, .startpage, .yahoo, .perplexity, .chatGPT,
    ]

    /// The catalog engine with `id`, or nil.
    public static func builtIn(id: String) -> SearchEngine? {
        catalog.first { $0.id == id }
    }
}

// MARK: - Custom engine

extension SearchEngine {
    public enum TemplateError: Error, Equatable, Sendable {
        case emptyName
        case missingPlaceholder
        case notAWebURL
    }

    /// A user-defined engine. The template must be an `http` or `https` URL with a host and must
    /// contain `%s` at least once. Custom engines take their suggestions from DuckDuckGo.
    public static func custom(name: String, template: String) throws(TemplateError) -> SearchEngine {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .emptyName }
        guard template.contains(queryPlaceholder) else { throw .missingPlaceholder }

        // Check the URL the template produces, not the template itself: `%s` is not valid
        // percent-encoding, so the raw template may not parse.
        let sample = template.replacingOccurrences(of: queryPlaceholder, with: "test")
        guard let components = URLComponents(string: sample),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { throw .notAWebURL }

        return SearchEngine(id: customID, name: name, template: template, suggestionSource: .duckDuckGo)
    }
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
