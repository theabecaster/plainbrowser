import Foundation

/// What the user meant by the text they submitted in the address bar: a page to open, or a search.
public enum AddressBarInput: Equatable, Sendable {
    case url(URL)
    case search(String)

    /// Schemes typed explicitly that the browser loads itself.
    static let loadableSchemes: Set<String> = ["http", "https", "about"]

    /// Classifies submitted text. Returns nil for text that is empty after trimming.
    ///
    /// Rules, in order:
    /// 1. Text with whitespace inside is a search.
    /// 2. Text with an explicit loadable scheme (`https://…`, `about:blank`) is that URL.
    /// 3. Text whose host is `localhost`, an IPv4 address, or a dotted name ending in a
    ///    letters-only label of two or more characters is a URL. `localhost` and IP addresses get
    ///    `http` (dev servers and routers); everything else gets `https`.
    /// 4. Anything else is a search.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(where: \.isWhitespace) {
            self = .search(trimmed)
            return
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           Self.loadableSchemes.contains(scheme) {
            // "https://" alone has a scheme but nothing to load.
            if scheme == "about" || url.host() != nil {
                self = .url(url)
                return
            }
        }
        if let url = Self.webURL(fromSchemeless: trimmed) {
            self = .url(url)
            return
        }
        self = .search(trimmed)
    }

    private static func webURL(fromSchemeless text: String) -> URL? {
        guard let components = URLComponents(string: "https://" + text),
              let host = components.host?.lowercased(), !host.isEmpty,
              // "mailto:me@example.com" would otherwise parse as user "mailto" at example.com.
              components.user == nil
        else { return nil }

        var result = components
        if host == "localhost" || isIPv4(host) {
            result.scheme = "http"
        } else if !hasPlausibleTLD(host) {
            return nil
        }
        return result.url
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard (1...3).contains(part.count), let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    private static func hasPlausibleTLD(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let tld = labels.last else {
            return false
        }
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }
}
