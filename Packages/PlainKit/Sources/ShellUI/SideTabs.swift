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

    var regularTabs: [TabGalleryItem] { engineTabs.galleryItems(private: false) }
    var privateTabs: [TabGalleryItem] { engineTabs.galleryItems(private: true) }
    var focusedTabID: UUID? { engineTabs.selectedID }
    var otherPaneTabID: UUID? { host?.otherShownPaneTabID }
    var canOpenInOtherPane: Bool { host?.canSplit ?? false }

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
}

extension EngineTabs {
    /// The window's tabs as the gallery and the sidebar show them.
    func galleryItems(private isPrivate: Bool) -> [TabGalleryItem] {
        // An empty tab is never a card or a row (docs/state-rules.md, principle 7).
        pageEntries(private: isPrivate).map { entry in
            let tab = existingTab(entry.id)
            return TabGalleryItem(
                id: entry.id,
                title: tab?.title ?? entry.title ?? "",
                url: tab?.url ?? entry.url,
                isPrivate: entry.isPrivate,
                thumbnailRevision: entry.thumbnail?.revision ?? 0,
                isPinned: entry.isPinned
            )
        }
    }
}
#endif
