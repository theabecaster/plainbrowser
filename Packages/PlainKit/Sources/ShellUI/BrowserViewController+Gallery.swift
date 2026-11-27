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
    /// The gallery kept ready while it is not up: a hidden child, laid out at the page's size with
    /// its cards built and their pictures decoded, so opening it shows them on the first frame
    /// (docs/research/perf-gallery-swipe.md). Dropped on a memory warning.
    var spareGallery: TabGalleryViewController?
    /// A spare gallery build is waiting for an idle moment.
    var isPrewarmScheduled = false
    /// The saved tabs are in and the first frame is long gone: idle work may start.
    var isLaunchDone = false
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
    /// The private start screen is on screen: drawn dark, it wants the light status bar.
    var prefersLightStatusBar = false
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
        // Reachable only with a card to show (state rules §3): another tab, or the page on screen.
        // The swipe up and Show All Tabs share this one condition, and the gallery never opens
        // empty.
        // The window's profile's list, or with none there (and no private tabs) the latest list of
        // another profile: the switcher then says whose it is.
        let profile = session.tabs.pageEntries(private: false).isEmpty && session.tabs.pageEntries(private: true).isEmpty
            ? session.tabs.profileWithLatestTab ?? session.tabs.activeProfile
            : session.tabs.activeProfile
        guard currentRules().galleryHasCards,
              let showsPrivate = GalleryRules.listToOpen(
                  screenTabIsPrivate: currentTab?.isPrivate,
                  regularCount: session.tabs.pageEntries(private: false, profile: profile).count,
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
        tabs.setShowingProfile(profile)
        tabs.setShowingPrivateTabs(showsPrivate)
        Signposts.signposter.emitEvent(Signposts.galleryOpen, "\(source)")
        // `gallery.show` runs from here: getting the gallery ready (a diff of the kept one, or a
        // new one) and the page's snapshot are part of what the user waits for.
        let showInterval = Signposts.signposter.beginInterval(Signposts.galleryShow)
        if isEditingAddress { endAddressEditing() }
        tabsUI.toast.hide(animated: false)
        let gallery = tabsUI.spareGallery ?? makeGallery(tabs)
        tabsUI.spareGallery = nil
        // Over the page, under the chrome (which fades as the gallery's own bar arrives) and the
        // search sheet (a new tab from the gallery opens it).
        view.insertSubview(gallery.view, aboveSubview: pageAreaTopView)
        gallery.pageTopInset = currentTab.map { session.pool.obscuredTop(for: $0) } ?? 0
        gallery.prepareToShow()
        gallery.view.isHidden = false
        tabsUI.gallery = gallery
        // The gallery has its own bar: the system's vertical bar (Duo) empties rather than hides,
        // so its column keeps its width and nothing under the gallery lays out again.
        applyToolbarItems()
        updateButtons()

        // The page zooms into its card; an empty tab has no card, so the gallery fades in.
        guard let tab = currentTab, tab.isPrivate == tabs.isShowingPrivateTabs,
              tab.isPrivate || tab.profileID == tabs.shownProfile, !session.tabs.isEmpty(tab.id),
              let snapshot = webContainer.snapshotView(afterScreenUpdates: false)
        else {
            gallery.view.alpha = 0
            Motion.animate(Motion.quick, changes: { gallery.view.alpha = 1 }) {
                Signposts.signposter.endInterval(Signposts.galleryShow, showInterval)
            }
            setChromeHiddenForGallery(true, animated: true)
            return nil
        }
        // A fresh card for the page being left.
        session.pool.captureThumbnail(of: tab)
        let generation = tabsUI.galleryGeneration
        let transition = TabGalleryTransition(
            tabID: tab.id, gallery: gallery, container: view, snapshot: snapshot,
            pageFrame: pageClip.convert(pageClip.bounds, to: view), contentTop: session.pool.obscuredTop(for: tab),
            from: .page, interval: showInterval
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

    /// A new gallery, a child of the browser with its view in the hierarchy, hidden.
    private func makeGallery(_ tabs: GalleryTabs) -> TabGalleryViewController {
        let gallery = TabGalleryViewController(dataSource: tabs)
        gallery.onLastTabClosed = { [weak self] in self?.galleryLastTabClosed() }
        addChild(gallery)
        gallery.view.frame = view.bounds
        gallery.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gallery.view.accessibilityViewIsModal = true
        gallery.view.isHidden = true
        view.insertSubview(gallery.view, aboveSubview: pageAreaTopView)
        gallery.didMove(toParent: self)
        return gallery
    }

    /// Builds the spare gallery once the app is idle, when the switcher has cards and none is
    /// ready: its view, its cards for the tabs on screen and their pictures (decoded off the
    /// main thread). Waits a second and for the default run loop mode, so it never lands in a
    /// scroll or a gesture.
    func scheduleGalleryPrewarm() {
        guard tabsUI.isLaunchDone, tabsUI.spareGallery == nil, !isShowingGallery, !tabsUI.isPrewarmScheduled,
              wantsSpareGallery else { return }
        tabsUI.isPrewarmScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated { self?.prewarmGallery() }
            }
        }
    }

    private func prewarmGallery() {
        tabsUI.isPrewarmScheduled = false
        guard tabsUI.spareGallery == nil, !isShowingGallery, presentedViewController == nil, wantsSpareGallery else { return }
        let gallery = makeGallery(galleryTabs())
        gallery.pageTopInset = currentTab.map { session.pool.obscuredTop(for: $0) } ?? 0
        gallery.prepareToShow()
        tabsUI.spareGallery = gallery
    }

    /// The switcher can open (it has a card) and is the gallery, not the sidebar.
    private var wantsSpareGallery: Bool {
        let rules = currentRules()
        return rules.galleryHasCards && !rules.state.sideTabs
    }

    /// Drops the spare gallery (a memory warning).
    func dropSpareGallery() {
        guard let spare = tabsUI.spareGallery else { return }
        tabsUI.spareGallery = nil
        spare.willMove(toParent: nil)
        spare.view.removeFromSuperview()
        spare.removeFromParent()
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
    /// bar taking its place. `progress` 0 is the page, 1 the gallery (a swipe drives it). It is gone
    /// by a third of the way, so a page held part way up never shows a faint ghost of the pill.
    func setChromeGalleryProgress(_ progress: CGFloat) {
        let t = min(max(progress, 0), 1)
        chromeGlass.isHidden = false
        chromeGlass.alpha = max(0, 1 - t * 3)
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
            // Turned back to the gallery mid-way: the page's buttons leave again.
            applyToolbarItems()
        case .page:
            removeGallery()
        }
    }

    /// Takes the gallery off screen at once; the page under it is already the selected tab.
    private func removeGallery() {
        guard let gallery = tabsUI.gallery else { return }
        dropGalleryTransition()
        // Kept, hidden, as the next opening's gallery: its cards and decoded pictures stay.
        gallery.view.isHidden = true
        gallery.view.alpha = 1
        tabsUI.gallery = nil
        tabsUI.spareGallery = gallery
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
        // After `show`: the tab's web view is attached and carries the page's insets.
        let top = session.pool.obscuredTop(for: tab)
        let transition = TabGalleryTransition(
            tabID: id, gallery: gallery, container: view, snapshot: cardPicture(for: id, top: top),
            pageFrame: pageClip.convert(pageClip.bounds, to: view), contentTop: top, from: .gallery
        ) { [weak self] end in
            self?.galleryTransitionEnded(at: end, generation: generation)
        }
        view.bringSubviewToFront(chromeGlass)
        view.bringSubviewToFront(tabsUI.toast)
        tabsUI.galleryTransition = transition
        transition.run()
        applyToolbarItems()
    }

    /// The page as its card shows it, sized like the page and pinned to its top: the transition's
    /// stand-in until the live page is uncovered.
    /// The thumbnail leaves out the strip a floating bar covers (`top`): it sits that far down,
    /// where the live page shows the same content.
    private func cardPicture(for id: TabID, top: CGFloat) -> UIView {
        let size = webContainer.bounds.size
        let view = UIView(frame: CGRect(origin: .zero, size: size))
        view.backgroundColor = Palette.surface
        view.clipsToBounds = true
        let thumbnail = session.pool.thumbnails.cachedThumbnail(for: id)
        if let image = thumbnail ?? tabsUI.previews[id], image.size.width > 0 {
            let imageView = UIImageView(image: image)
            // A neighbour's full-screen picture includes the strip; a thumbnail does not.
            let y = thumbnail != nil ? top : 0
            imageView.frame = CGRect(x: 0, y: y, width: size.width, height: size.width * image.size.height / image.size.width)
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

    func galleryCloseAll(private isPrivate: Bool, profile: ProfileID) {
        let closesShown = currentTab.map { $0.isPrivate == isPrivate && (isPrivate || $0.profileID == profile) } ?? false
        if closesShown { clearPage() }
        session.tabs.closeAll(private: isPrivate, profile: profile)
        if closesShown, let next = session.tabs.selected { show(next) }
    }

    func galleryNewTab(private isPrivate: Bool, profile: ProfileID) -> TabID {
        // An empty tab of the same kind (and profile) on screen is the new tab (state rules,
        // principle 7).
        let tab: Tab
        if let current = currentTab, current.isPrivate == isPrivate, isPrivate || current.profileID == profile,
           session.tabs.isEmpty(current.id) {
            tab = current
        } else {
            tab = session.tabs.newTab(isPrivate: isPrivate, profile: profile)
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
        if let selected = session.tabs.selected { show(selected) }
        tabsUI.galleryTabs?.setShowingProfile(session.tabs.activeProfile)
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
                if !current.isPrivate { tabs.setShowingProfile(current.profileID) }
                tabs.setShowingPrivateTabs(current.isPrivate)
                gallery.reloadTabs(animated: false)
                galleryOpenTab(current.id)
            } else {
                dismissGalleryFading()
            }
            if let batch { offerReopen(batch) }
        case .switchList:
            if wasPrivate { tabs.setShowingProfile(session.tabs.activeProfile) }
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
        // The last tab's picture stands in for its page until the restored session is in.
        let showsStart = currentTab.map { session.tabs.isEmpty($0.id) } ?? (launchUI.placeholder == nil)
        start.isHidden = !showsStart
        // Back on an idle start screen with the field closed (a load stopped before it
        // committed): the mark and its company return.
        if showsStart, !isEditingAddress, start.isReceded { start.setReceded(false, animated: true) }
        if showsStart {
            applyStartShortcuts()
            // An empty private tab says what it is, on the private dusk; with profiles, the
            // window's is named.
            start.setPrivate(currentTab?.isPrivate == true)
            updateStartScreenMessage()
        }
        updateStatusBarForStart()
        // Over a blank tab's web view, under the page-state message.
        if showsStart {
            webContainer.bringSubviewToFront(start)
            webContainer.bringSubviewToFront(engineUI.pageState)
        }
    }

    /// The start screen while typing (state rules §3): with a query, the mark and its shortcuts
    /// recede and the sheet takes the paper behind the suggestions; cleared, they come back.
    func updateStartForTyping(query: String, showsRows: Bool = false) {
        var state = rules.state
        state.isEditing = isEditingAddress
        state.hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        state.showsFocusRows = showsRows
        let recedes = ControlRules(state).startScreenRecedes
        let start = tabsUI.start
        guard recedes != start.isReceded else { return }
        // The field closed because a page is on its way: the start screen leaves with it rather
        // than bringing the mark back for a moment. The next empty field brings it back.
        if !recedes, !isEditingAddress, let tab = currentTab,
           !session.tabs.isEmpty(tab.id) || engineUI.typedVisitTabs.contains(tab.id) { return }
        start.setReceded(recedes, animated: true)
        updateStatusBarForStart()
    }

    /// The clock and battery stay light while the dark private start screen is what shows under
    /// them; once it recedes for suggestions the sheet's paper is, and the system's style returns.
    func updateStatusBarForStart() {
        let start = tabsUI.start
        let light = !start.isHidden && start.isPrivate && !start.isReceded
        guard light != tabsUI.prefersLightStatusBar else { return }
        tabsUI.prefersLightStatusBar = light
        setNeedsStatusBarAppearanceUpdate()
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
                // An empty private tab: this turns it into a regular one, so it says where it
                // goes (UX audit item 26), with the switcher's word for the other side.
                EmptyTabView.Shortcut(
                    id: "start.regularTab", title: String(localized: "Leave Private"),
                    accessibilityLabel: String(localized: "Leave Private Browsing"), symbol: "hand.raised.slash"
                ) {
                    [weak self] in self?.openNewTab(private: false)
                }
            case .reopenClosedTab:
                // Captions as in the page menu's row ("Reopen Tab", "Archive"); the full names
                // stay for VoiceOver.
                EmptyTabView.Shortcut(
                    id: "start.reopenClosedTab", title: String(localized: "Reopen Tab"),
                    accessibilityLabel: String(localized: "Reopen Closed Tab"), symbol: "arrow.uturn.backward"
                ) {
                    [weak self] in self?.reopenLastClosed(source: "start")
                }
            case .archivedTabs:
                EmptyTabView.Shortcut(
                    id: "start.archivedTabs", title: String(localized: "Archive"),
                    accessibilityLabel: String(localized: "Archived Tabs"), symbol: "archivebox"
                ) {
                    [weak self] in self?.showArchive()
                }
            }
        })
    }

    /// The tabs changed outside the gallery (a title, a thumbnail, the archive): it shows them.
    func tabsDidChange() {
        // The rules first: the sidebar's New Tab reads them.
        updateButtons()
        scheduleGalleryPrewarm()
        updatePageTabCount()
        tabsUI.gallery?.reloadTabs(animated: false)
        duo.sidebar?.reloadTabs()
        duo.strip?.reloadTabs()
        // A tab closed or archived elsewhere may have left the other pane.
        syncPanes()
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
