import Foundation

/// One tab as the gallery shows it. A value: the gallery keeps the last list it read and diffs the
/// next one against it.
public struct TabGalleryItem: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// The page title; empty while a page has none.
    public var title: String
    /// The page's address, for Copy Link and Share. `nil` for a new tab with no page yet.
    public var url: URL?
    public var isPrivate: Bool
    /// Bumps when the tab has a newer thumbnail, so the gallery drops its decoded copy.
    public var thumbnailRevision: Int
    /// Bumps when the tab's site icon arrives or changes.
    public var faviconRevision: Int

    public init(
        id: UUID, title: String, url: URL?, isPrivate: Bool = false, thumbnailRevision: Int = 0, faviconRevision: Int = 0
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isPrivate = isPrivate
        self.thumbnailRevision = thumbnailRevision
        self.faviconRevision = faviconRevision
    }

    /// The host without a leading "www.", for the card and VoiceOver.
    public var host: String? {
        guard let host = url?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What the card's title row shows: the title, else the host, else "New Tab".
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return host ?? String(localized: "New Tab")
    }
}

#if canImport(UIKit)
import UIKit

/// What the gallery needs from the tabs. The shell implements it over `TabStore`; tests and
/// previews use `TabGalleryDemoData`. The gallery never owns tab state: it reads it from here and
/// sends every change back here (AGENTS.md, one owner per piece of state).
///
/// After calling an action the gallery reads `tabs` again, so an action must update the list
/// before it returns. Changes that start elsewhere (a page title, a new thumbnail) reach the
/// gallery through `TabGalleryViewController.reloadTabs(animated:)`.
@MainActor
public protocol TabGalleryDataSource: AnyObject {
    /// Open tabs, in order.
    var tabs: [TabGalleryItem] { get }
    /// The tab the page shows, if any.
    var selectedTabID: UUID? { get }
    /// Whether "Open in Other Pane" applies (a split is possible). The menu hides it otherwise.
    var canOpenInOtherPane: Bool { get }
    /// Whether a closed tab can come back (the gallery menu's "Reopen Closed Tab").
    var canReopenClosedTab: Bool { get }

    /// The tab's page thumbnail, full size. The gallery downsamples and decodes it off the main
    /// thread. Return `nil` when there is none yet.
    func thumbnail(for id: UUID) async -> UIImage?
    /// The tab's site icon, if known.
    func favicon(for id: UUID) async -> UIImage?

    /// The user opened `id` from the gallery. The shell runs the open transition.
    func selectTab(_ id: UUID)
    func closeTab(_ id: UUID)
    func closeAllTabs()
    /// Moves `id` so it sits at `index` in `tabs` after the move.
    func moveTab(_ id: UUID, to index: Int)
    /// Opens a new tab at once and returns its id. The shell shows the search field for it.
    @discardableResult func newTab() -> UUID
    /// Reopens the most recently closed tab, if any, and returns its id.
    @discardableResult func reopenClosedTab() -> UUID?
    func openInOtherPane(_ id: UUID)
}

extension TabGalleryDataSource {
    public var canOpenInOtherPane: Bool { false }
    public func openInOtherPane(_ id: UUID) {}
}
#endif
