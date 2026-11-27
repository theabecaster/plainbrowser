import Foundation
import PlainShared
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

/// One entry Plain puts in Spotlight: a favorite. Plain values, so the sync is tested without
/// Core Spotlight.
public struct SpotlightItem: Hashable, Sendable {
    /// `favorite:` plus the page address; Spotlight hands it back when the result is tapped.
    public var identifier: String
    public var title: String
    public var url: URL
    public var domain: String

    /// Every favorite's item lives in this domain, so a change replaces them all in one call.
    public static let favoritesDomain = "favorites"
    static let favoritePrefix = "favorite:"

    public init(favorite: SharedFavorite) {
        identifier = Self.favoritePrefix + favorite.url.absoluteString
        title = favorite.title
        url = favorite.url
        domain = Self.favoritesDomain
    }

    /// The page behind a tapped result's identifier, or nil when it is not one of Plain's.
    public static func url(fromIdentifier identifier: String) -> URL? {
        guard identifier.hasPrefix(favoritePrefix) else { return nil }
        let address = identifier.dropFirst(favoritePrefix.count)
        guard let url = URL(string: String(address)), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

/// The calls Plain makes on the Spotlight index (the seam tests replace).
public protocol SpotlightIndexing: Sendable {
    /// Replaces every item in `domain` with `items`.
    func replace(_ items: [SpotlightItem], inDomain domain: String) async throws
    /// Removes everything Plain put in Spotlight, and every activity iOS saved for it.
    func deleteAll() async throws
}

#if canImport(CoreSpotlight)
/// Core Spotlight's default index, on device only: nothing leaves the phone.
public struct CoreSpotlightIndex: SpotlightIndexing {
    public init() {}

    public func replace(_ items: [SpotlightItem], inDomain domain: String) async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = CSSearchableIndex.default()
        try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
        guard !items.isEmpty else { return }
        try await index.indexSearchableItems(items.map(Self.searchableItem))
    }

    public func deleteAll() async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        try await CSSearchableIndex.default().deleteAllSearchableItems()
        #if os(iOS)
        // Handoff activities are never eligible for search, so this is a safety net: whatever iOS
        // kept of Plain's activities goes too.
        await NSUserActivity.deleteAllSavedUserActivities()
        #endif
    }

    static func searchableItem(_ item: SpotlightItem) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .url)
        attributes.title = item.title
        // The address under the title, without the scheme, as the favorites strip shows sites.
        let host = item.url.host() ?? item.url.absoluteString
        attributes.contentDescription = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        attributes.url = item.url
        attributes.keywords = [host]
        let searchable = CSSearchableItem(
            uniqueIdentifier: item.identifier, domainIdentifier: item.domain, attributeSet: attributes
        )
        // Items expire after 30 days by default; a favorite lasts until it is removed.
        searchable.expirationDate = .distantFuture
        return searchable
    }
}
#endif
