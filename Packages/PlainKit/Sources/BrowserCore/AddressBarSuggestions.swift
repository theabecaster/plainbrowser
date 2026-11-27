import Foundation

/// A page that matched what the user typed: from history, favorites or both.
public struct PageCandidate: Hashable, Sendable {
    public var url: URL
    public var title: String?
    /// The page's `Frecency` key, or nil for a favorite never visited.
    public var frecency: Double?
    public var isFavorite: Bool
    /// An unread page in the reading list: it ranks right after favorites
    /// (`FixedChoices.readingListRanksInSuggestions`).
    public var isSaved: Bool
    /// How often the user picked this page after typing text that starts like the current
    /// input (adaptive history), or nil when never. Higher is stronger.
    public var adaptiveUse: Double?

    public init(
        url: URL, title: String?, frecency: Double?, isFavorite: Bool, isSaved: Bool = false, adaptiveUse: Double? = nil
    ) {
        self.url = url
        self.title = title
        self.frecency = frecency
        self.isFavorite = isFavorite
        self.isSaved = isSaved
        self.adaptiveUse = adaptiveUse
    }
}

/// One row in the address bar's suggestion list.
public enum AddressBarSuggestion: Hashable, Sendable {
    /// `isSaved`: an unread page in the reading list (its own symbol in the row).
    case page(url: URL, title: String?, isFavorite: Bool, isSaved: Bool = false)
    case search(String)
}

/// Merges history, favorites, the reading list and engine suggestions into the address bar's list.
///
/// Order:
/// 1. **Top hit**, the first of:
///    - the page the user picked most after typing this text before (adaptive history);
///    - while the text can still be a host ("git", "github.co"), the site itself: the root page
///      of the best matching host (`github.com`, not `github.com/apple/swift`), made from that
///      host when only deeper pages were visited;
///    - once the text reaches a path ("github.com/ap"), the best page whose address starts with it.
///    So the obvious destination is one tap away.
/// 2. **Pages**: favorites first, then unread saved pages, then history by frecency, up to `maxPages` in total with the top hit.
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
        saved: [PageCandidate] = [],
        searches: [String],
        maxPages: Int = FixedChoices.maxPageSuggestions,
        maxTotal: Int = FixedChoices.maxAddressBarSuggestions
    ) -> [AddressBarSuggestion] {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, maxTotal > 0 else { return [] }

        let pages = rankedPages(favorites + saved + history)

        var orderedPages = pages
        if let top = topHit(in: pages, typedAddress: normalizedPrefix(typed)) {
            switch top {
            case .existing(let index):
                orderedPages.remove(at: index)
                orderedPages.insert(pages[index], at: 0)
            case .origin(let origin):
                orderedPages.insert(origin, at: 0)
            }
        }

        var result = orderedPages.prefix(min(maxPages, maxTotal)).map {
            AddressBarSuggestion.page(url: $0.url, title: $0.title, isFavorite: $0.isFavorite, isSaved: $0.isSaved)
        }

        var seen: Set<String> = [typed.lowercased()]
        for search in searches where result.count < maxTotal {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(.search(trimmed))
        }
        return result
    }

    enum TopHit: Equatable {
        case existing(Int)
        case origin(PageCandidate)
    }

    /// The top hit among ranked `pages` (see the type's documentation), or nil when nothing fits.
    static func topHit(in pages: [PageCandidate], typedAddress: String?) -> TopHit? {
        // Adaptive history: the page picked most for text like this.
        var picked: (index: Int, use: Double)?
        for (index, page) in pages.enumerated() {
            guard let use = page.adaptiveUse, use > (picked?.use ?? 0) else { continue }
            picked = (index, use)
        }
        if let picked { return .existing(picked.index) }

        guard let typedAddress,
              let first = pages.firstIndex(where: { addressKey($0.url).hasPrefix(typedAddress) })
        else { return nil }
        // Past the host: the best page whose address starts with the text.
        guard !typedAddress.contains("/") && !typedAddress.contains("?") else { return .existing(first) }
        let host = siteKey(addressKey(pages[first].url))
        guard host.hasPrefix(typedAddress) else { return .existing(first) }
        // Still a host: the site itself.
        if let root = pages.firstIndex(where: { addressKey($0.url) == host }) { return .existing(root) }
        guard var components = URLComponents(url: pages[first].url, resolvingAgainstBaseURL: false),
              components.host != nil
        else { return .existing(first) }
        components.user = nil
        components.password = nil
        components.percentEncodedPath = "/"
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else { return .existing(first) }
        return .origin(PageCandidate(url: origin, title: nil, frecency: nil, isFavorite: false))
    }

    /// The host part of an `addressKey` (host and port, without path or query).
    static func siteKey(_ key: String) -> String {
        String(key.prefix { $0 != "/" && $0 != "?" })
    }

    /// Candidates merged by address and sorted: favorites first, then unread saved pages, then by
    /// frecency.
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
            existing.isSaved = existing.isSaved || candidate.isSaved
            existing.frecency = [existing.frecency, candidate.frecency].compactMap(\.self).max()
            existing.adaptiveUse = [existing.adaptiveUse, candidate.adaptiveUse].compactMap(\.self).max()
            if existing.title?.isEmpty ?? true { existing.title = candidate.title }
            byKey[key] = existing
        }
        // `order` keeps input order as the tie-breaker, so the sort is deterministic.
        return order.enumerated().map { ($0.offset, byKey[$0.element]!) }
            .sorted { lhs, rhs in
                if lhs.1.isFavorite != rhs.1.isFavorite { return lhs.1.isFavorite }
                if lhs.1.isSaved != rhs.1.isSaved { return lhs.1.isSaved }
                let left = lhs.1.frecency ?? -.infinity, right = rhs.1.frecency ?? -.infinity
                if left != right { return left > right }
                return lhs.0 < rhs.0
            }
            .map(\.1)
    }

    /// The part of a URL that identifies a page for deduplication: host without `www.`, port,
    /// path without a trailing slash, and query. Lowercased host; scheme and fragment dropped.
    /// Storage's history query dedupes with this too, so both agree on what one page is.
    public static func addressKey(_ url: URL) -> String {
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
