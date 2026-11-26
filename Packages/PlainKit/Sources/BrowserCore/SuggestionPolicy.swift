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

        // A URL at the start, even with words after it (a pasted link plus a note).
        if hasScheme(lower) { return false }
        if isIPv6(lower) || lower.hasPrefix("[") { return false }
        if let space = lower.firstIndex(where: \.isWhitespace) {
            // Words after an address: still held back when the address names a path, a query, a
            // port or a local machine ("localhost/admin notes", "example.com?token=x note",
            // "nas:8080 login", "10.0.0.1 router"). A bare public domain followed by words
            // ("github.com down") is a search about that site.
            let first = String(lower[..<space])
            let hasMore = first.contains { $0 == "/" || $0 == ":" || $0 == "?" || $0 == "#" }
            return !(isLocal(first) || (looksLikeHost(first) && hasMore))
        }

        if case .url = AddressBarInput(trimmed) { return false }
        if lower.hasPrefix("www.") { return false }
        if looksLikeHost(lower) { return false }
        return true
    }

    /// `localhost` or an IP address, with or without a port, path or query.
    private static func isLocal(_ token: String) -> Bool {
        let host = token.split(whereSeparator: { "/:?#".contains($0) }).first.map(String.init) ?? token
        if host == "localhost" || host.hasSuffix(".localhost") || isIPv6(token) { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }
    }

    /// A bare IPv6 address (`::1`, `fe80::1%en0`): two or more colons and only hex digits, colons,
    /// dots and a zone index.
    private static func isIPv6(_ token: String) -> Bool {
        let address = token.split(separator: "%", maxSplits: 1).first ?? Substring(token)
        return address.filter { $0 == ":" }.count >= 2
            && address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
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
        // Split off the path, query or fragment, then the port.
        let hostAndPort = String(text.prefix { !"/?#".contains($0) })
        let rest = text.dropFirst(hostAndPort.count)
        let hasPath = !rest.isEmpty
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
            // "intranet/", "wiki/team", "localhost?x", "nas:8080": a word with a port, path, query
            // or fragment is a host. The one exception is two short words around a slash
            // ("and/or", "AC/DC", "24/7", "tcp/ip"): common in searches, rare as intranet paths.
            guard hasPort || hasPath else { return false }
            let isShortSlashPair = rest.first == "/" && host.count <= 3 && rest.count - 1 <= 3 && rest.count > 1
                && !rest.dropFirst().contains { "/?#".contains($0) }
            return !isShortSlashPair
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
