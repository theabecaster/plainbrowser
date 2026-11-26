import Foundation

/// A page that matched what the user typed: from history, favorites or both.
public struct PageCandidate: Hashable, Sendable {
    public var url: URL
    public var title: String?
    /// The page's `Frecency` key, or nil for a favorite never visited.
    public var frecency: Double?
    public var isFavorite: Bool

    public init(url: URL, title: String?, frecency: Double?, isFavorite: Bool) {
        self.url = url
        self.title = title
        self.frecency = frecency
        self.isFavorite = isFavorite
    }
}

/// One row in the address bar's suggestion list.
public enum AddressBarSuggestion: Hashable, Sendable {
    case page(url: URL, title: String?, isFavorite: Bool)
    case search(String)
}

/// Merges history, favorites and engine suggestions into the address bar's list.
///
/// Order:
/// 1. **Top hit**: the best page whose address starts with what was typed ("git" finds
///    github.com), so the obvious destination is one tap away.
/// 2. **Pages**: favorites first, then history by frecency, up to `maxPages` in total with the top hit.
/// 3. **Searches** from the engine, filling the rest of the list.
///
/// Pages are deduplicated by address, ignoring scheme, `www.`, a trailing slash and the fragment.
/// Searches are deduplicated ignoring case, and the typed text itself is left out because the
/// return key already searches for it.
public enum AddressBarSuggestions {
    public static func merge(
        query: String,
        history: [PageCandidate],
        favorites: [PageCandidate],
        searches: [String],
        maxPages: Int = FixedChoices.maxPageSuggestions,
        maxTotal: Int = FixedChoices.maxAddressBarSuggestions
    ) -> [AddressBarSuggestion] {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, maxTotal > 0 else { return [] }

        let pages = rankedPages(favorites + history)

        var orderedPages: [PageCandidate] = []
        let typedAddress = normalizedPrefix(typed)
        if let typedAddress, let topIndex = pages.firstIndex(where: { addressKey($0.url).hasPrefix(typedAddress) }) {
            orderedPages.append(pages[topIndex])
            orderedPages += pages.enumerated().filter { $0.offset != topIndex }.map(\.element)
        } else {
            orderedPages = pages
        }

        var result = orderedPages.prefix(min(maxPages, maxTotal)).map {
            AddressBarSuggestion.page(url: $0.url, title: $0.title, isFavorite: $0.isFavorite)
        }

        var seen: Set<String> = [typed.lowercased()]
        for search in searches where result.count < maxTotal {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(.search(trimmed))
        }
        return result
    }

    /// Candidates merged by address and sorted: favorites first, then by frecency.
    static func rankedPages(_ candidates: [PageCandidate]) -> [PageCandidate] {
        var byKey: [String: PageCandidate] = [:]
        var order: [String] = []
        for candidate in candidates {
            let key = addressKey(candidate.url)
            guard var existing = byKey[key] else {
                byKey[key] = candidate
                order.append(key)
                continue
            }
            existing.isFavorite = existing.isFavorite || candidate.isFavorite
            existing.frecency = [existing.frecency, candidate.frecency].compactMap(\.self).max()
            if existing.title?.isEmpty ?? true { existing.title = candidate.title }
            byKey[key] = existing
        }
        // `order` keeps input order as the tie-breaker, so the sort is deterministic.
        return order.enumerated().map { ($0.offset, byKey[$0.element]!) }
            .sorted { lhs, rhs in
                if lhs.1.isFavorite != rhs.1.isFavorite { return lhs.1.isFavorite }
                let left = lhs.1.frecency ?? -.infinity, right = rhs.1.frecency ?? -.infinity
                if left != right { return left > right }
                return lhs.0 < rhs.0
            }
            .map(\.1)
    }

    /// The part of a URL that identifies a page for deduplication: host without `www.`, port,
    /// path without a trailing slash, and query. Lowercased host; scheme and fragment dropped.
    static func addressKey(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else { return url.absoluteString.lowercased() }
        var key = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = components.port { key += ":\(port)" }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        key += path
        if let query = components.percentEncodedQuery, !query.isEmpty { key += "?" + query }
        return key
    }

    /// Typed text as an address prefix ("https://www.Git" becomes "git"), or nil when it can't
    /// be the start of an address (it has spaces).
    static func normalizedPrefix(_ typed: String) -> String? {
        guard !typed.contains(where: \.isWhitespace) else { return nil }
        var text = typed.lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text.isEmpty ? nil : text
    }
}
