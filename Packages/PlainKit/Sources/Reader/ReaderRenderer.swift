import Foundation

/// Builds the reader page for an article from the bundled template (`reader.html`).
///
/// There are no reader settings: text size follows Dynamic Type and colors follow light and dark
/// mode, both in `reader.css`. The page loads from the `plain-reader:` scheme
/// (`ReaderSchemeHandler`), so the template and stylesheet never touch the network.
public struct ReaderRenderer: Sendable {
    /// The scheme the reader page and its stylesheet are served from.
    public static let scheme = "plain-reader"

    /// The page's content security policy: no scripts, no frames, styles only from the reader
    /// scheme (with the paper tile under the page). Article images and video may still load from
    /// the web.
    static let contentSecurityPolicy =
        "default-src 'none'; style-src \(scheme):; img-src \(scheme): https: http: data:; media-src https: http:; "
        + "base-uri 'none'; form-action 'none'"

    public init() {}

    /// The full reader page for `article`. Reads the template on first use and builds the page off
    /// the main thread.
    @concurrent public func page(for article: ReaderArticle) async throws -> String {
        try await ReaderResources.template().render(Self.values(for: article))
    }

    /// The page as UTF-8 data, ready to serve. Built off the main thread.
    @concurrent func pageData(for article: ReaderArticle) async throws -> Data {
        Data(try await page(for: article).utf8)
    }

    /// Whether `url` is a reader page or its stylesheet. The reader web view's navigation
    /// delegate allows only these in the reader view and opens every other link in the tab.
    public static func isReaderURL(_ url: URL?) -> Bool {
        url?.scheme == scheme
    }

    /// The template slots for `article`. Text values are escaped; `content` is Readability's
    /// cleaned HTML and goes in as is.
    static func values(for article: ReaderArticle) -> [String: String] {
        let site = clean(article.siteName) ?? article.url?.host().map(Self.displayHost)
        var byline = clean(article.byline)
        if let line = byline, let site, line.caseInsensitiveCompare(site) == .orderedSame { byline = nil }

        var meta = ""
        if site != nil || byline != nil {
            let parts = [site.map { #"<span class="site">\#(escape($0))</span>"# }, byline.map(escape)]
            meta = #"<p class="meta">\#(parts.compactMap { $0 }.joined(separator: " · "))</p>"#
        }
        return [
            "lang": escape(sanitizedLanguage(article.lang)),
            "dir": ["ltr", "rtl"].contains(article.dir?.lowercased()) ? article.dir!.lowercased() : "auto",
            "title": escape(clean(article.title) ?? ""),
            "meta": meta,
            "csp": escape(contentSecurityPolicy),
            "content": article.contentHTML,
        ]
    }

    /// Collapses runs of whitespace (bylines often span lines) and drops empty values.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func displayHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A BCP 47 tag keeps only letters, digits and hyphens; anything else becomes no language.
    static func sanitizedLanguage(_ lang: String?) -> String {
        guard let lang, lang.count <= 35,
              lang.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return "" }
        return lang
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}

/// A page template with `{{name}}` slots, parsed once. Rendering fills every slot in one pass, so
/// a value that happens to contain `{{…}}` is never filled again.
struct ReaderTemplate: Sendable {
    private enum Part: Sendable {
        case text(String)
        case slot(String)
    }

    private let parts: [Part]

    init(_ source: String) {
        var parts: [Part] = []
        var rest = source[...]
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            parts.append(.text(String(rest[..<open.lowerBound])))
            parts.append(.slot(String(rest[open.upperBound..<close.lowerBound])))
            rest = rest[close.upperBound...]
        }
        parts.append(.text(String(rest)))
        self.parts = parts
    }

    func render(_ values: [String: String]) -> String {
        var out = ""
        for part in parts {
            switch part {
            case .text(let text): out += text
            case .slot(let name): out += values[name] ?? ""
            }
        }
        return out
    }
}
