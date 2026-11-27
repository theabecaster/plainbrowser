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
    /// Pinned tabs stay through Close All Tabs.
    public var isPinned: Bool

    public init(
        id: UUID, title: String, url: URL?, isPrivate: Bool = false, thumbnailRevision: Int = 0, faviconRevision: Int = 0,
        isPinned: Bool = false
    ) {
        self.id = id
        self.isPinned = isPinned
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

    /// The title for a narrow tab (the strip, the sidebar): without the site's name when the title
    /// ends with it ("Web browser - Wikipedia" on wikipedia.org reads "Web browser"), since the
    /// tile already shows the site and the words that tell tabs apart come first.
    public var compactTitle: String {
        let full = displayTitle
        guard let site = Self.siteName(of: host) else { return full }
        for separator in [" - ", " – ", " — ", " | ", " · ", " : "] {
            guard let range = full.range(of: separator, options: .backwards) else { continue }
            let head = full[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = full[range.upperBound...].lowercased().filter { $0.isLetter || $0.isNumber }
            if !head.isEmpty, tail == site { return head }
        }
        return full
    }

    /// The site's name from its host, lowercased: "wikipedia" for en.wikipedia.org, "bbc" for
    /// bbc.co.uk. Nil when the host has no name before its suffix.
    static func siteName(of host: String?) -> String? {
        guard let host else { return nil }
        var labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 1 else { return nil }
        labels.removeLast()
        // A short second level under a country code (co.uk, com.au) is not the site's name.
        if labels.count > 1, let last = labels.last, ["co", "com", "org", "net", "ac", "gov", "edu"].contains(last) {
            labels.removeLast()
        }
        guard let name = labels.last, name.count > 1 else { return nil }
        return name
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

    /// Whether the gallery offers private browsing (its private toggle shows).
    var supportsPrivateTabs: Bool { get }
    /// The gallery lists private tabs instead of regular ones; New Tab then opens a private one.
    var isShowingPrivateTabs: Bool { get }
    /// The private toggle. The gallery reads `tabs` again after it.
    func setShowingPrivateTabs(_ isPrivate: Bool)

    /// Whether the gallery menu offers the archive.
    var canShowArchive: Bool { get }
    /// "Archived Tabs" from the gallery menu: the shell presents the archive.
    func showArchive()
    /// The empty space was tapped while the tab on screen is not a card in the list (an empty tab,
    /// or a tab of the other list): the shell goes back to it as it is.
    func returnToPage()
    /// The Reopen toast after a close: brings back exactly that close, if it still can.
    @discardableResult func reopenOfferedTab() -> UUID?

    /// Profiles there are (0: the data source has none). With one, the More menu offers New
    /// Profile; with two or more, the switcher shows over the cards.
    var profileCount: Int { get }
    /// The name of the profile whose tabs the gallery lists.
    var profileTitle: String? { get }
    /// The switcher's menu: the profiles, New Profile, and Rename and Delete for the shown one.
    func profileMenuElements() -> [UIMenuElement]
    /// New Profile from the More menu.
    func newProfile()
    /// The empty regular list's sentence (a profile with no tabs yet); nil for the default.
    var emptyListText: String? { get }
}

extension TabGalleryDataSource {
    public var canOpenInOtherPane: Bool { false }
    public func openInOtherPane(_ id: UUID) {}
    public var supportsPrivateTabs: Bool { false }
    public var isShowingPrivateTabs: Bool { false }
    public func setShowingPrivateTabs(_ isPrivate: Bool) {}
    public var canShowArchive: Bool { false }
    public func showArchive() {}
    public func returnToPage() {}
    @discardableResult public func reopenOfferedTab() -> UUID? { reopenClosedTab() }
    public var profileCount: Int { 0 }
    public var profileTitle: String? { nil }
    public func profileMenuElements() -> [UIMenuElement] { [] }
    public func newProfile() {}
    public var emptyListText: String? { nil }
}
#endif
