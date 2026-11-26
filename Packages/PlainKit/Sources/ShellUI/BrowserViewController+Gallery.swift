#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import TabGalleryUI
import UIKit
import WebEngine

/// What the browser keeps for tabs besides the tab on screen: the gallery while it shows, the bar
/// swipe, swipe previews and the toast. One stored property on `BrowserViewController`.
final class TabsUIState {
    var gallery: TabGalleryViewController?
    /// The page ↔ card transition running now, if any.
    var galleryTransition: TabGalleryTransition?
    /// Bumped whenever a running transition is replaced or dropped, so its late completion is
    /// ignored instead of removing the gallery a newer transition uses.
    var galleryGeneration = 0
    var galleryTabs: GalleryTabs?
    let swipe = TabSwipe()
    let toast = ShellToast()
    /// Full-screen pictures of the tab on screen's two neighbours, for a bar swipe toward a tab
    /// without a web view: a 2x snapshot taken when it left the screen, else its thumbnail.
    var previews: [TabID: UIImage] = [:]
    /// Whether `previews[id]` is a full-screen snapshot (better than a thumbnail).
    var fullPreviews: Set<TabID> = []
    /// A launch or foreground archive pass is running.
    var isArchiving = false
}

// MARK: - The tab gallery

extension BrowserViewController: GalleryHost {
    var isShowingGallery: Bool { tabsUI.gallery != nil }

    /// Opens the gallery: the page zooms into its card (docs/plan.md, motion table, "Open tab
    /// gallery"). With `interactive`, a finger drives it through the returned transition
    /// (`update(progress:)`, `finish(at:)`); nil when there is no page to zoom (the gallery fades
    /// in instead) or the gallery is already up.
    @discardableResult
    func presentGallery(source: StaticString, interactive: Bool = false) -> TabGalleryTransition? {
        guard !isShowingGallery, presentedViewController == nil else { return nil }
        Signposts.signposter.emitEvent(Signposts.galleryOpen, "\(source)")
        if isEditingAddress { endAddressEditing() }
        tabsUI.toast.hide(animated: false)
        let tabs = galleryTabs()
        tabs.setShowingPrivateTabs(currentTab?.isPrivate ?? false)
        let gallery = TabGalleryViewController(dataSource: tabs)
        gallery.onLastTabClosed = { [weak self] in self?.galleryLastTabClosed() }
        addChild(gallery)
        gallery.view.frame = view.bounds
        gallery.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gallery.view.accessibilityViewIsModal = true
        // Over the page, under the chrome (which fades as the gallery's own bar arrives) and the
        // search sheet (a new tab from the gallery opens it).
        view.insertSubview(gallery.view, aboveSubview: pageClip)
        gallery.didMove(toParent: self)
        tabsUI.gallery = gallery
        // The gallery has its own bar: the system's vertical bar (Duo) empties rather than hides,
        // so its column keeps its width and nothing under the gallery lays out again.
        setToolbarItems([], animated: true)
        updateButtons()

        guard let tab = currentTab, tab.isPrivate == tabs.isShowingPrivateTabs,
              let snapshot = webContainer.snapshotView(afterScreenUpdates: false)
        else {
            gallery.view.alpha = 0
            Motion.animate(Motion.quick) { gallery.view.alpha = 1 }
            setChromeHiddenForGallery(true, animated: true)
            return nil
        }
        // A fresh card for the page being left.
        session.pool.captureThumbnail(of: tab)
        let generation = tabsUI.galleryGeneration
        let transition = TabGalleryTransition(
            tabID: tab.id, gallery: gallery, container: view, snapshot: snapshot,
            pageFrame: pageClip.frame, from: .page
        ) { [weak self] end in
            self?.galleryTransitionEnded(at: end, generation: generation)
        }
        // The chrome stays above the zooming page while it fades.
        view.bringSubviewToFront(chromeGlass)
        view.bringSubviewToFront(tabsUI.toast)
        tabsUI.galleryTransition = transition
        if !interactive {
            transition.run()
            setChromeHiddenForGallery(true, animated: true)
        }
        return transition
    }

    /// The gallery data source, made once.
    private func galleryTabs() -> GalleryTabs {
        if let tabs = tabsUI.galleryTabs { return tabs }
        let tabs = GalleryTabs(tabs: session.tabs)
        tabs.host = self
        tabsUI.galleryTabs = tabs
        return tabs
    }

    /// The chrome while the gallery is up: it slides down a little and fades, the gallery's own
    /// bar taking its place. `progress` 0 is the page, 1 the gallery (a swipe drives it).
    func setChromeGalleryProgress(_ progress: CGFloat) {
        let t = min(max(progress, 0), 1)
        chromeGlass.isHidden = false
        chromeGlass.alpha = max(0, 1 - t * 2)
        chromeGlass.transform = CGAffineTransform(translationX: 0, y: t * Spacing.xl)
    }

    func setChromeHiddenForGallery(_ hidden: Bool, animated: Bool) {
        let finish = { [weak self] in
            guard let self else { return }
            // Hidden, the chrome's glass and controls leave the accessibility tree too.
            chromeGlass.isHidden = hidden && isShowingGallery
        }
        if !hidden { chromeGlass.isHidden = false }
        guard animated else {
            setChromeGalleryProgress(hidden ? 1 : 0)
            finish()
            return
        }
        Motion.animate(Motion.galleryZoom, changes: { self.setChromeGalleryProgress(hidden ? 1 : 0) }, completion: finish)
    }

    private func galleryTransitionEnded(at end: TabGalleryTransition.End, generation: Int) {
        guard generation == tabsUI.galleryGeneration else { return }
        tabsUI.galleryTransition = nil
        switch end {
        case .gallery:
            setChromeHiddenForGallery(true, animated: false)
        case .page:
            removeGallery()
        }
    }

    /// Takes the gallery off screen at once; the page under it is already the selected tab.
    private func removeGallery() {
        guard let gallery = tabsUI.gallery else { return }
        dropGalleryTransition()
        gallery.willMove(toParent: nil)
        gallery.view.removeFromSuperview()
        gallery.removeFromParent()
        tabsUI.gallery = nil
        setToolbarItems(PageButton.allCases.compactMap { barItems[$0] }, animated: true)
        setChromeHiddenForGallery(false, animated: false)
        updateButtons()
        updatePageState()
    }

    /// Ends a running transition where it was heading, without running its end (the caller
    /// decides what happens next).
    private func dropGalleryTransition() {
        tabsUI.galleryGeneration += 1
        let running = tabsUI.galleryTransition
        tabsUI.galleryTransition = nil
        running?.cancel()
    }

    /// Fades the gallery out with no zoom (a new tab, the last tab closed).
    func dismissGalleryFading() {
        guard let gallery = tabsUI.gallery else { return }
        dropGalleryTransition()
        setChromeHiddenForGallery(false, animated: true)
        Motion.animate(Motion.quick, changes: { gallery.view.alpha = 0 }) { [weak self] in
            self?.removeGallery()
        }
    }

    // MARK: GalleryHost

    /// A card was tapped (or Done): its page grows out of the card. The web view goes under the
    /// gallery at once; the card's picture stands in for it while it grows, then the gallery
    /// leaves and the live page shows (motion table, "Open tab").
    func galleryOpenTab(_ id: TabID) {
        guard let gallery = tabsUI.gallery else { return }
        // A page still zooming lands at once, without its end; the new zoom starts from the gallery.
        dropGalleryTransition()
        let tab = session.tabs.tab(id)
        show(tab)
        setChromeHiddenForGallery(false, animated: true)
        let generation = tabsUI.galleryGeneration
        let transition = TabGalleryTransition(
            tabID: id, gallery: gallery, container: view, snapshot: cardPicture(for: id),
            pageFrame: pageClip.frame, from: .gallery
        ) { [weak self] end in
            self?.galleryTransitionEnded(at: end, generation: generation)
        }
        view.bringSubviewToFront(chromeGlass)
        view.bringSubviewToFront(tabsUI.toast)
        tabsUI.galleryTransition = transition
        transition.run()
    }

    /// The page as its card shows it, sized like the page and pinned to its top: the transition's
    /// stand-in until the live page is uncovered.
    private func cardPicture(for id: TabID) -> UIView {
        let size = webContainer.bounds.size
        let view = UIView(frame: CGRect(origin: .zero, size: size))
        view.backgroundColor = Palette.surface
        view.clipsToBounds = true
        if let image = session.pool.thumbnails.cachedThumbnail(for: id) ?? tabsUI.previews[id], image.size.width > 0 {
            let imageView = UIImageView(image: image)
            imageView.frame = CGRect(x: 0, y: 0, width: size.width, height: size.width * image.size.height / image.size.width)
            view.addSubview(imageView)
        }
        return view
    }

    func galleryCloseTab(_ id: TabID) {
        let wasShown = currentTab?.id == id
        if wasShown { clearPage() }
        session.tabs.close(id)
        if wasShown, let next = session.tabs.selected { show(next) }
    }

    func galleryCloseAll(private isPrivate: Bool) {
        let closesShown = currentTab?.isPrivate == isPrivate
        if closesShown { clearPage() }
        session.tabs.closeAll(private: isPrivate)
        if closesShown, let next = session.tabs.selected { show(next) }
    }

    func galleryNewTab(private isPrivate: Bool) -> TabID {
        let tab = session.tabs.newTab(isPrivate: isPrivate)
        show(tab)
        // Straight to the search field: it rises over the fading gallery.
        dismissGalleryFading()
        beginAddressEditing()
        return tab.id
    }

    func galleryReopenClosedTab() -> TabID? {
        let ids = session.tabs.reopenLastClosed()
        if let selected = session.tabs.selected { show(selected) }
        return ids.first
    }

    var galleryCanShowArchive: Bool { sheets.isReady }

    func galleryShowArchive() {
        showArchive()
    }

    /// The gallery's list is empty after a close. Private tabs all gone with regular ones left:
    /// back to the regular list. Otherwise straight to the search field (docs/ui-reference.md:
    /// no empty screen after the last tab).
    private func galleryLastTabClosed() {
        if let tabs = tabsUI.galleryTabs, tabs.isShowingPrivateTabs, !session.tabs.entries(private: false).isEmpty {
            tabs.setShowingPrivateTabs(false)
            tabsUI.gallery?.reloadTabs(animated: false)
            return
        }
        dismissGalleryFading()
        if let selected = session.tabs.selected {
            show(selected)
        } else {
            beginAddressEditing()
        }
    }

    /// The tabs changed outside the gallery (a title, a thumbnail, the archive): it shows them.
    func tabsDidChange() {
        tabsUI.gallery?.reloadTabs(animated: false)
        updateButtons()
    }
}
#endif
