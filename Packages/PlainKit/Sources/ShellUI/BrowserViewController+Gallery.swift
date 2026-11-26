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
    /// What an empty tab shows: the mark above the search field (TabGalleryUI's `EmptyTabView`).
    let start = EmptyTabView()
    /// The start screen's shortcuts as last applied, so they are rebuilt only when they change.
    var startShortcuts: [StartShortcut]?
    /// A toast that waits while the gallery or a sheet is up (it could not act from there); the
    /// newest one shows when they close.
    var pendingToast: (() -> Void)?
    /// The one-time hint for the tabs slot's long press.
    let tip = TabsTipPresenter()
    /// The edge swipe back that closes a link-opened tab on its first page.
    let openerSwipe = OpenerEdgeSwipe()
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
        // Reachable only with another tab to switch to (state rules §3): the tap, the swipe up and
        // Show All Tabs share this one condition, and the gallery never opens empty.
        guard currentRules().swipeUpOpensGallery,
              let showsPrivate = GalleryRules.listToOpen(
                  screenTabIsPrivate: currentTab?.isPrivate,
                  regularCount: session.tabs.pageEntries(private: false).count,
                  privateCount: session.tabs.pageEntries(private: true).count
              )
        else { return nil }
        // Leaving an empty tab for the gallery drops it (principle 7): the start screen waits under
        // the cards, with nothing selected.
        if let tab = currentTab, session.tabs.isEmpty(tab.id) {
            clearPage()
            engineUI.typedVisitTabs.remove(tab.id)
            session.tabs.discard(tab.id, refillingPane: false)
        }
        let tabs = galleryTabs()
        tabs.setShowingPrivateTabs(showsPrivate)
        Signposts.signposter.emitEvent(Signposts.galleryOpen, "\(source)")
        if isEditingAddress { endAddressEditing() }
        tabsUI.toast.hide(animated: false)
        let gallery = TabGalleryViewController(dataSource: tabs)
        gallery.onLastTabClosed = { [weak self] in self?.galleryLastTabClosed() }
        addChild(gallery)
        gallery.view.frame = view.bounds
        gallery.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gallery.view.accessibilityViewIsModal = true
        // Over the page, under the chrome (which fades as the gallery's own bar arrives) and the
        // search sheet (a new tab from the gallery opens it).
        view.insertSubview(gallery.view, aboveSubview: pageAreaTopView)
        gallery.didMove(toParent: self)
        tabsUI.gallery = gallery
        // The gallery has its own bar: the system's vertical bar (Duo) empties rather than hides,
        // so its column keeps its width and nothing under the gallery lays out again.
        applyToolbarItems()
        updateButtons()

        // The page zooms into its card; an empty tab has no card, so the gallery fades in.
        guard let tab = currentTab, tab.isPrivate == tabs.isShowingPrivateTabs, !session.tabs.isEmpty(tab.id),
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
            pageFrame: pageClip.convert(pageClip.bounds, to: view), from: .page
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
        applyToolbarItems()
        setChromeHiddenForGallery(false, animated: false)
        updateButtons()
        updatePageState()
        showPendingToast()
        tabsUI.tip.showIfPossible(in: self)
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
            pageFrame: pageClip.convert(pageClip.bounds, to: view), from: .gallery
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
        // An empty tab of the same kind on screen is the new tab (state rules, principle 7).
        let tab: Tab
        if let current = currentTab, current.isPrivate == isPrivate, session.tabs.isEmpty(current.id) {
            tab = current
        } else {
            tab = session.tabs.newTab(isPrivate: isPrivate)
            show(tab)
        }
        // Straight to the search field: it rises over the fading gallery.
        dismissGalleryFading()
        beginAddressEditing()
        return tab.id
    }

    /// Reopen Closed Tab from the gallery's menu (`batch` nil: the last close) or its toast (the
    /// close it was offered for). Reopened tabs are regular: the gallery shows that list.
    func galleryReopen(batch: UUID?) -> TabID? {
        let ids = batch.map { session.tabs.reopenClosed($0) } ?? session.tabs.reopenLastClosed()
        guard !ids.isEmpty else {
            Haptic.nothingThere.play()
            return nil
        }
        tabsUI.galleryTabs?.setShowingPrivateTabs(false)
        if let selected = session.tabs.selected { show(selected) }
        return ids.first
    }

    var galleryLastClosedBatch: UUID? { session.tabs.lastClosedBatchID }

    var galleryCanShowArchive: Bool { sheets.isReady && session.tabs.hasArchivedTabs }

    /// The empty space was tapped with no card of the tab on screen in the list (an empty tab, or
    /// the other list): back to that tab as it is.
    func galleryReturnToPage() {
        dismissGalleryFading()
    }

    func galleryShowArchive() {
        showArchive()
    }

    /// The gallery's list is empty after a close (state rules §6), first match: the tab on screen
    /// still exists → it opens; the other list has tabs → the gallery switches to it; else the
    /// search field. Never an empty gallery. A regular close's Reopen follows wherever this lands.
    private func galleryLastTabClosed() {
        guard let tabs = tabsUI.galleryTabs, let gallery = tabsUI.gallery else { return }
        let wasPrivate = tabs.isShowingPrivateTabs
        let batch = wasPrivate ? nil : session.tabs.lastClosedBatchID
        let screenTabOpen = currentTab.map { session.tabs.entry($0.id) != nil } ?? false
        let otherCount = session.tabs.pageEntries(private: !wasPrivate).count
        switch GalleryRules.afterLastCard(screenTabStillOpen: screenTabOpen, otherListCount: otherCount) {
        case .openScreenTab:
            if let current = currentTab, !session.tabs.isEmpty(current.id) {
                tabs.setShowingPrivateTabs(current.isPrivate)
                gallery.reloadTabs(animated: false)
                galleryOpenTab(current.id)
            } else {
                dismissGalleryFading()
            }
            if let batch { offerReopen(batch) }
        case .switchList:
            tabs.setShowingPrivateTabs(!wasPrivate)
            gallery.reloadTabs(animated: false)
            if let batch {
                tabs.offerReopen(batch)
                gallery.showReopenToast()
            }
        case .search:
            dismissGalleryFading()
            beginAddressEditing()
            if let batch { offerReopen(batch) }
        }
    }

    // MARK: Toasts that wait

    /// Shows a toast now, or when the gallery or a sheet closes (a toast over them could not act).
    func showToastWhenFree(_ show: @escaping () -> Void) {
        if isShowingGallery || presentedViewController != nil {
            tabsUI.pendingToast = show
        } else {
            show()
        }
    }

    func showPendingToast() {
        guard !isShowingGallery, presentedViewController == nil, let show = tabsUI.pendingToast else { return }
        tabsUI.pendingToast = nil
        show()
    }

    // MARK: The start screen

    /// An empty tab (or no tab) shows the start screen instead of bare paper: the mark, which a
    /// finger can spin, in the space above the search field, and a Search button while the
    /// keyboard is down. The search sheet goes clear over it, so it shows with the keyboard up too.
    func updateStartScreen() {
        let start = tabsUI.start
        // In the page's own container: it moves with a bar swipe and is in the page's snapshot
        // when the page zooms into its card.
        if start.superview !== webContainer {
            start.frame = webContainer.bounds
            start.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            start.buttonTitle = String(localized: "Search")
            // The field and the favorites strip sit in this space above the keyboard or the bar.
            start.bottomReserve = Metrics.favoriteTile + Metrics.rowHeight * 2
            start.onAction = { [weak self] in self?.beginAddressEditing() }
            webContainer.addSubview(start)
        }
        let showsStart = currentTab.map { session.tabs.isEmpty($0.id) } ?? true
        start.isHidden = !showsStart
        if showsStart { applyStartShortcuts() }
        // Over a blank tab's web view, under the page-state message.
        if showsStart {
            webContainer.bringSubviewToFront(start)
            webContainer.bringSubviewToFront(engineUI.pageState)
        }
        sheet.backgroundColor = showsStart && !start.isReceded ? .clear : Palette.background
    }

    /// The start screen while typing (state rules §3): with a query, the mark and its shortcuts
    /// recede and the sheet takes the paper behind the suggestions; cleared, they come back.
    func updateStartForTyping(query: String) {
        var state = rules.state
        state.isEditing = isEditingAddress
        state.hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let recedes = ControlRules(state).startScreenRecedes
        let start = tabsUI.start
        guard recedes != start.isReceded else { return }
        start.setReceded(recedes, animated: true)
        guard !start.isHidden else { return }
        let paper: UIColor = recedes ? Palette.background : .clear
        Motion.animate(Motion.reflow, crossfading: sheet) { self.sheet.backgroundColor = paper }
    }

    /// The start screen's shortcuts under the mark (state rules §3): a private tab always, Reopen
    /// Closed Tab and Archived Tabs when they lead somewhere.
    func applyStartShortcuts() {
        let shortcuts = rules.startShortcuts
        guard shortcuts != tabsUI.startShortcuts else { return }
        tabsUI.startShortcuts = shortcuts
        tabsUI.start.setShortcuts(shortcuts.map { shortcut in
            switch shortcut {
            case .privateTab:
                EmptyTabView.Shortcut(id: "start.privateTab", title: String(localized: "Private Tab"), symbol: "hand.raised") {
                    [weak self] in self?.openNewTab(private: true)
                }
            case .regularTab:
                EmptyTabView.Shortcut(id: "start.newTab", title: String(localized: "New Tab"), symbol: "plus") {
                    [weak self] in self?.openNewTab(private: false)
                }
            case .reopenClosedTab:
                EmptyTabView.Shortcut(id: "start.reopenClosedTab", title: String(localized: "Reopen Closed Tab"), symbol: "arrow.uturn.backward") {
                    [weak self] in self?.reopenLastClosed(source: "start")
                }
            case .archivedTabs:
                EmptyTabView.Shortcut(id: "start.archivedTabs", title: String(localized: "Archived Tabs"), symbol: "archivebox") {
                    [weak self] in self?.showArchive()
                }
            }
        })
    }

    /// The tabs changed outside the gallery (a title, a thumbnail, the archive): it shows them.
    func tabsDidChange() {
        tabsUI.gallery?.reloadTabs(animated: false)
        duo.sidebar?.reloadTabs()
        duo.strip?.reloadTabs()
        // A tab closed or archived elsewhere may have left the other pane.
        syncPanes()
        updateButtons()
        updateStartScreen()
    }

    var galleryCanOpenInOtherPane: Bool { canSplit }

    /// The gallery's Open in Other Pane: the gallery fades and the tab shows beside the page.
    func galleryOpenInOtherPane(_ id: TabID) {
        dismissGalleryFading()
        openInOtherPane(session.tabs.tab(id))
    }
}
#endif
