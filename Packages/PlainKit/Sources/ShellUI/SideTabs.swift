#if canImport(UIKit)
import BrowserCore
import Foundation
import TabGalleryUI
import WebEngine

/// The sidebar's data source over `EngineTabs` (and so `TabStore`, the one owner of tabs). It
/// keeps no tab state; actions that move what is on screen go to the browser.
final class SideTabs: SideTabsDataSource {
    private let engineTabs: EngineTabs
    weak var host: BrowserViewController?

    init(tabs: EngineTabs) {
        engineTabs = tabs
    }

    var showsPrivate: Bool { host?.showsPrivateMode ?? false }
    var tabs: [TabGalleryItem] { engineTabs.galleryItems(private: showsPrivate) }
    var regularCount: Int { engineTabs.pageEntries(private: false).count }
    var privateCount: Int { engineTabs.pageEntries(private: true).count }
    var focusedTabID: UUID? { engineTabs.selectedID }
    var otherPaneTabID: UUID? { host?.otherShownPaneTabID }
    var canOpenInOtherPane: Bool { host?.canSplit ?? false }

    func cachedIcon(for item: TabGalleryItem, pixelSize: Int) -> SiteIcon? {
        guard let site = FaviconService.site(of: item.url) else { return nil }
        return engineTabs.pool.favicons.cachedIcon(site: site, scope: engineTabs.iconScope(of: item.id), pixelSize: pixelSize)
    }

    func icon(for item: TabGalleryItem, pixelSize: Int) async -> SiteIcon? {
        guard let site = FaviconService.site(of: item.url) else { return nil }
        return await engineTabs.pool.favicons.icon(site: site, scope: engineTabs.iconScope(of: item.id), pixelSize: pixelSize)
    }

    func selectTab(_ id: UUID) {
        host?.sideTabsSelect(id)
    }

    func closeTab(_ id: UUID) {
        host?.galleryCloseTab(id)
    }

    func moveTab(_ id: UUID, to index: Int) {
        engineTabs.move(id, to: index)
    }

    func newTab(private isPrivate: Bool) {
        host?.openNewTab(private: isPrivate)
    }

    func openInOtherPane(_ id: UUID) {
        guard let host else { return }
        host.openInOtherPane(engineTabs.tab(id))
    }

    func showMode(private isPrivate: Bool) {
        host?.showTabMode(private: isPrivate)
    }

    func closeAllPrivateTabs() {
        host?.closeAllPrivateTabs()
    }
}

extension EngineTabs {
    /// Whose icon a tab's row shows: its profile's, or the private tabs' (memory only).
    func iconScope(of id: TabID) -> SiteIconScope {
        guard let entry = entry(id) else { return .profile(activeProfile) }
        return entry.isPrivate ? .privateTabs : .profile(entry.profileID)
    }

    /// The window's tabs as the gallery and the sidebar show them.
    func galleryItems(private isPrivate: Bool, profile: ProfileID? = nil) -> [TabGalleryItem] {
        // An empty tab is never a card or a row (docs/state-rules.md, principle 7).
        let favicons = pool.favicons
        return pageEntries(private: isPrivate, profile: profile).map { entry in
            let tab = existingTab(entry.id)
            let url = tab?.url ?? entry.url
            let scope: SiteIconScope = entry.isPrivate ? .privateTabs : .profile(entry.profileID)
            return TabGalleryItem(
                id: entry.id,
                title: tab?.title ?? entry.title ?? "",
                url: url,
                isPrivate: entry.isPrivate,
                thumbnailRevision: entry.thumbnail?.revision ?? 0,
                // Bumps when the site's icon arrives, so the row and the card show it.
                faviconRevision: FaviconService.site(of: url).map { favicons.revision(site: $0, scope: scope) } ?? 0,
                isPinned: entry.isPinned
            )
        }
    }
}
#endif
