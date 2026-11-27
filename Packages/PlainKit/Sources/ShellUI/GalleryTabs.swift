#if canImport(UIKit)
import BrowserCore
import Foundation
import TabGalleryUI
import UIKit
import WebEngine

/// What the gallery's actions need from the browser screen: they move what is on screen, so the
/// browser runs them (transitions, the search field, the archive sheet).
@MainActor
protocol GalleryHost: AnyObject {
    func galleryOpenTab(_ id: TabID)
    func galleryCloseTab(_ id: TabID)
    func galleryCloseAll(private isPrivate: Bool, profile: ProfileID)
    func galleryNewTab(private isPrivate: Bool, profile: ProfileID) -> TabID
    func galleryReopen(batch: UUID?) -> TabID?
    var galleryLastClosedBatch: UUID? { get }
    func galleryShowArchive()
    var galleryCanShowArchive: Bool { get }
    var galleryCanOpenInOtherPane: Bool { get }
    func galleryOpenInOtherPane(_ id: TabID)
    func galleryReturnToPage()
    func galleryProfileMenu() -> [UIMenuElement]
    func galleryNewProfile()
}

/// The tab gallery's data source over `EngineTabs` (and so BrowserCore's `TabStore`, the one owner
/// of tabs): the list in order, the selected tab, thumbnails from the pool's `ThumbnailService`.
/// It holds no tab state of its own besides which list the gallery shows: a profile's regular
/// tabs, or the private ones.
final class GalleryTabs: TabGalleryDataSource {
    private let engineTabs: EngineTabs
    weak var host: (any GalleryHost)?
    /// The gallery lists private tabs instead of regular ones.
    private(set) var isShowingPrivateTabs = false
    /// The profile whose regular tabs the gallery lists. Showing another profile's list changes
    /// nothing else: opening one of its cards (or a new tab there) makes it the window's.
    private(set) var shownProfile = Profile.defaultID

    init(tabs: EngineTabs) {
        engineTabs = tabs
    }

    /// The shown list's cards. An empty tab is never a card (docs/state-rules.md, principle 7).
    var tabs: [TabGalleryItem] {
        engineTabs.galleryItems(private: isShowingPrivateTabs, profile: shownProfile)
    }

    var selectedTabID: UUID? { engineTabs.selectedID }
    var canReopenClosedTab: Bool { !isShowingPrivateTabs && engineTabs.store.lastClosedBatch(in: shownProfile) != nil }
    var supportsPrivateTabs: Bool { true }
    var canOpenInOtherPane: Bool { host?.galleryCanOpenInOtherPane ?? false }

    func openInOtherPane(_ id: UUID) {
        host?.galleryOpenInOtherPane(id)
    }
    /// The archive screen shows the window's profile's archive, so it is offered on that list.
    var canShowArchive: Bool {
        !isShowingPrivateTabs && shownProfile == engineTabs.activeProfile && (host?.galleryCanShowArchive ?? false)
    }

    func thumbnail(for id: UUID) async -> UIImage? {
        await engineTabs.pool.thumbnails.thumbnail(for: id)
    }

    /// The site's icon on a tile of its own (a dark mark shows on any card); nil until the site
    /// has one, and the card shows its placeholder.
    func favicon(for id: UUID) async -> UIImage? {
        guard let site = FaviconService.site(of: engineTabs.existingTab(id)?.url ?? engineTabs.entry(id)?.url) else { return nil }
        return await engineTabs.pool.favicons.icon(
            site: site, scope: engineTabs.iconScope(of: id), pixelSize: FixedChoices.faviconPixelSize, plated: true
        )?.image
    }

    func selectTab(_ id: UUID) {
        host?.galleryOpenTab(id)
    }

    /// The batch the gallery's Reopen toast brings back: the one its last close made.
    private var offeredBatch: UUID?

    func closeTab(_ id: UUID) {
        host?.galleryCloseTab(id)
        offeredBatch = isShowingPrivateTabs ? nil : host?.galleryLastClosedBatch
    }

    func closeAllTabs() {
        host?.galleryCloseAll(private: isShowingPrivateTabs, profile: shownProfile)
        offeredBatch = isShowingPrivateTabs ? nil : host?.galleryLastClosedBatch
    }

    /// The Reopen toast: exactly the close it was offered for.
    func reopenOfferedTab() -> UUID? {
        guard let batch = offeredBatch else { return nil }
        offeredBatch = nil
        return host?.galleryReopen(batch: batch)
    }

    /// The shell moved the offer here after switching lists (the last card of the other list).
    func offerReopen(_ batch: UUID) {
        offeredBatch = batch
    }

    func moveTab(_ id: UUID, to index: Int) {
        engineTabs.move(id, to: index)
    }

    @discardableResult
    func newTab() -> UUID {
        host?.galleryNewTab(private: isShowingPrivateTabs, profile: shownProfile) ?? UUID()
    }

    /// The gallery menu's Reopen Closed Tab: the shown profile's last close.
    @discardableResult
    func reopenClosedTab() -> UUID? {
        guard let batch = engineTabs.store.lastClosedBatch(in: shownProfile) else { return nil }
        return host?.galleryReopen(batch: batch.id)
    }

    func setShowingPrivateTabs(_ isPrivate: Bool) {
        isShowingPrivateTabs = isPrivate
    }

    /// Lists `profile`'s regular tabs (the switcher, or the window's profile when the gallery
    /// opens).
    func setShowingProfile(_ profile: ProfileID) {
        isShowingPrivateTabs = false
        shownProfile = profile
    }

    var profileCount: Int { engineTabs.profiles.count }

    var profileTitle: String? { engineTabs.store.profile(shownProfile)?.name }

    func profileMenuElements() -> [UIMenuElement] {
        host?.galleryProfileMenu() ?? []
    }

    func newProfile() {
        host?.galleryNewProfile()
    }

    /// With a second profile, an empty list says whose it is and what that means.
    var emptyListText: String? {
        guard profileCount > 1, let name = profileTitle else { return nil }
        return String(localized: "Tabs in \(name) show up here, with \(name)'s own logins and history.")
    }

    func showArchive() {
        host?.galleryShowArchive()
    }

    func returnToPage() {
        host?.galleryReturnToPage()
    }
}
#endif
