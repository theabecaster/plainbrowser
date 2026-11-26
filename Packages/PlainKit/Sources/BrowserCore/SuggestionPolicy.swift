import Foundation

/// What typed text may go to the search engine's suggestion endpoint.
///
/// Suggestions are for searches. An address on its way to being typed or pasted says where the
/// user is going, and an intranet name, IP address or `localhost` says something about their
/// network; none of it is the engine's business. Firefox applies the same rule (bug 1628079).
public enum SuggestionPolicy {
    /// True when `text` may be sent to the engine for suggestions. Pure and cheap: it runs on
    /// every keystroke.
    ///
    /// Not sent:
    /// - text that `AddressBarInput` would open as a page (a dotted host with a TLD, `localhost`,
    ///   an IPv4 address, an explicit `http`/`https`/`about` URL);
    /// - anything with a scheme (`://`, `about:`, `file:`, `mailto:` …), so pasted URLs never leak;
    /// - a host still being typed (`github.`, `github.c`, `www.`), a single-label host with a port
    ///   or a path (`intranet/`, `nas:8080`), an IPv6 literal, and numbers shaped like an IP
    ///   address (`192.168.`, `10.0.0`).
    ///
    /// Text with a space in it is a search, but a pasted URL followed by words is still held back.
    public static func allowsRemote(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        // A URL anywhere at the start, even with words after it (a pasted link plus a note).
        if hasScheme(lower) { return false }
        if lower.contains(where: \.isWhitespace) { return true }

        if case .url = AddressBarInput(trimmed) { return false }
        if lower.hasPrefix("www.") || lower.hasPrefix("[") { return false }
        if looksLikeHost(lower) { return false }
        return true
    }

    /// `scheme:` at the start, as a URL has it: `https://…`, `about:blank`, `mailto:x@y`. A word
    /// followed by a colon and a space ("note: …") has whitespace and is handled before; a single
    /// word with a trailing colon ("define:") is a search.
    private static func hasScheme(_ text: String) -> Bool {
        if text.contains("://") { return true }
        for scheme in ["about:", "file:", "data:", "javascript:", "mailto:", "tel:", "blob:"] where text.hasPrefix(scheme) {
            return text.count > scheme.count
        }
        return false
    }

    /// A host, possibly with a port and a path, as people type it on the way to an address.
    private static func looksLikeHost(_ text: String) -> Bool {
        // Split off the path, then the port.
        let hostAndPort = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        let hasPath = hostAndPort.count < text.count
        var host = Substring(hostAndPort)
        var hasPort = false
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            // "define:" is a search; "nas:8080" is a host.
            guard !port.isEmpty, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) else { return false }
            hasPort = true
            host = host[..<colon]
        }
        guard !host.isEmpty else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else {
            return false
        }

        if labels.count == 1 {
            // "intranet/", "nas:8080": a bare word is a search, a word with a port or path is not.
            return hasPort || hasPath
        }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            // "3.14" is a number; "192.168." and "10.0.0" are addresses being typed.
            return labels.count >= 3 || hasPort || hasPath || labels.last?.isEmpty == true
        }
        // "github.", "github.c", "nas.local": dotted names whose last label is letters (or not
        // typed yet), with the first label naming something. "v1.2" ends in a digit: a search.
        guard let first = labels.first, !first.isEmpty, let last = labels.last else { return false }
        return last.allSatisfy(\.isLetter) || hasPort || hasPath
    }
}
