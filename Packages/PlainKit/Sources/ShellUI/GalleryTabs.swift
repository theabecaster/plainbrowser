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
    func galleryCloseAll(private isPrivate: Bool)
    func galleryNewTab(private isPrivate: Bool) -> TabID
    func galleryReopenClosedTab() -> TabID?
    func galleryShowArchive()
    var galleryCanShowArchive: Bool { get }
    var galleryCanOpenInOtherPane: Bool { get }
    func galleryOpenInOtherPane(_ id: TabID)
}

/// The tab gallery's data source over `EngineTabs` (and so BrowserCore's `TabStore`, the one owner
/// of tabs): the list in order, the selected tab, thumbnails from the pool's `ThumbnailService`.
/// It holds no tab state of its own besides which list the gallery shows, regular or private.
final class GalleryTabs: TabGalleryDataSource {
    private let engineTabs: EngineTabs
    weak var host: (any GalleryHost)?
    /// The gallery lists private tabs instead of regular ones.
    private(set) var isShowingPrivateTabs = false

    init(tabs: EngineTabs) {
        engineTabs = tabs
    }

    var tabs: [TabGalleryItem] {
        engineTabs.galleryItems(private: isShowingPrivateTabs)
    }

    var selectedTabID: UUID? { engineTabs.selectedID }
    var canReopenClosedTab: Bool { !isShowingPrivateTabs && engineTabs.canReopenClosedTab }
    var supportsPrivateTabs: Bool { true }
    var canOpenInOtherPane: Bool { host?.galleryCanOpenInOtherPane ?? false }

    func openInOtherPane(_ id: UUID) {
        host?.galleryOpenInOtherPane(id)
    }
    var canShowArchive: Bool { !isShowingPrivateTabs && (host?.galleryCanShowArchive ?? false) }

    func thumbnail(for id: UUID) async -> UIImage? {
        await engineTabs.pool.thumbnails.thumbnail(for: id)
    }

    /// No site icons are stored yet; the card shows its placeholder.
    func favicon(for id: UUID) async -> UIImage? { nil }

    func selectTab(_ id: UUID) {
        host?.galleryOpenTab(id)
    }

    func closeTab(_ id: UUID) {
        host?.galleryCloseTab(id)
    }

    func closeAllTabs() {
        host?.galleryCloseAll(private: isShowingPrivateTabs)
    }

    func moveTab(_ id: UUID, to index: Int) {
        engineTabs.move(id, to: index)
    }

    @discardableResult
    func newTab() -> UUID {
        host?.galleryNewTab(private: isShowingPrivateTabs) ?? UUID()
    }

    @discardableResult
    func reopenClosedTab() -> UUID? {
        host?.galleryReopenClosedTab()
    }

    func setShowingPrivateTabs(_ isPrivate: Bool) {
        isShowingPrivateTabs = isPrivate
    }

    func showArchive() {
        host?.galleryShowArchive()
    }
}
#endif
