#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import TabGalleryUI
import UIKit
import WebEngine

/// What the browser keeps for the Duo layout: the last layout, the constraints it drives, the
/// sidebar and the running fold. One stored property on `BrowserViewController`.
final class DuoUIState {
    var layout: DuoLayout?
    /// The chrome's lane (pill, search field, toast): the focused pane, off a fold and the camera.
    let chromeLane = UILayoutGuide()
    var laneLeading: NSLayoutConstraint!
    var laneWidth: NSLayoutConstraint!
    /// The panes' edges: beside the sidebar's docked width (left or right). The strip floats.
    var panesLeading: NSLayoutConstraint!
    var panesTrailing: NSLayoutConstraint!
    var panesTop: NSLayoutConstraint!
    /// Which tab each pane slot has attached, so a pane change attaches or detaches only what moved.
    var slotTabs: [Int: TabID] = [:]
    /// A fold, unfold or rotation is running: page insets wait for its completion.
    var isResizing = false
    var resizeGeneration = 0
    var resizeInterval: OSSignpostIntervalState?
    /// Side tabs (`+SideTabs`).
    var sidebar: SideTabsViewController?
    var sideTabs: SideTabs?
    var sidebarWidth: NSLayoutConstraint?
    /// The sidebar's side: its leading or its trailing edge is pinned.
    var sidebarLeading: NSLayoutConstraint?
    var sidebarTrailing: NSLayoutConstraint?
    /// Tab Layout: Above (`+SideTabs`).
    var strip: TabStripViewController?
    /// The state the user left the sidebar in; the layout limits it (Rail during a split or fold).
    var sidebarRequest: SidebarState = .rail
    /// The state the Tabs button brings the sidebar back to after hiding it.
    var lastShownSidebar: SidebarState = .rail
    /// A finger is resizing the sidebar; its width when the drag began.
    var isDraggingSidebar = false
    var sidebarDragStart: CGFloat = 0
    var sidebarInterval: OSSignpostIntervalState?
    /// Settings > Tab Layout, once the saved settings are read.
    var tabLayout: TabLayout = FixedChoices.defaultTabLayout
    /// The sidebar state has been read from the scene once.
    var didRestoreSidebar = false
    /// The top bar on a wide screen (`+TopBar`): its constraints, and its geometry while it shows.
    let top = TopBarLayout()
    var topGeometry: TopChromeGeometry?
    /// The corner the status items keep to (`readStatusCorner`), read before each layout pass.
    var statusCorner: CGRect?
    var lastStatusReading: StatusZoneReading?
    /// Page tabs in the window, kept as tabs change: the strip shows from the second.
    var pageTabCount = 0

    static let logger = Logger(subsystem: Signposts.subsystem, category: "duo")
}

// MARK: - Panes and the Duo layout

extension BrowserViewController {
    /// Hooks the pane slots: a touch in a pane focuses it.
    func installPanes() {
        for (index, slot) in panes.slots.enumerated() {
            slot.loadViewIfNeeded()
            slot.view.backgroundColor = .clear
            slot.onTouch = { [weak self] onControl in self?.paneTouched(index, onControl: onControl) }
        }
        panes.show([0], primaryWidth: nil)
    }

    /// The window has two panes (TabStore), shown side by side or not.
    var isSplit: Bool { session.tabs.panes.count > 1 }

    /// A split can show here now (inner screen, wide enough).
    var canSplit: Bool { duo.layout?.splitAvailable ?? false }

    /// The window's panes that are on screen: both in a shown split, else the focused one.
    var shownPanes: [Int] {
        let panes = session.tabs.panes
        return canSplit && panes.count > 1 ? Array(panes.indices) : [session.tabs.focusedPane]
    }

    /// `id` is on screen in a pane other than the focused one (a split's other pane).
    func isShownInOtherPane(_ id: TabID) -> Bool {
        let panes = session.tabs.panes
        let focused = session.tabs.focusedPane
        return shownPanes.contains { $0 != focused && panes.indices.contains($0) && panes[$0] == id }
    }

    // MARK: Layout

    /// What the layout is decided from: the root view's bounds and safe area, its size classes and
    /// the fold's reserved regions. Never the device, the screen or the orientation.
    func layoutInput() -> DuoLayoutInput {
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        let pageArea = CGRect(
            x: safe.left, y: safe.top,
            width: max(0, bounds.width - safe.left - safe.right), height: max(0, bounds.height - safe.top)
        )
        let division = view.reservedRegions(kind: .division, options: .includeInactive).first
        var occlusions = view.reservedRegions(kind: .occlusion).map(\.frame)
        #if DEBUG
        // The simulator's resizable window (`devicectl device appResize`, the stand-in for the
        // inner screen while Device Hub can't be driven) reports the outer screen's sensor regions.
        if ProcessInfo.processInfo.arguments.contains("-PlainIgnoreOcclusions") { occlusions = [] }
        #endif
        let pillFrame = pill.frame
        let row = makeTopGeometry(stripHeight: 0)
        return DuoLayoutInput(
            pageArea: pageArea,
            isRegularWidth: traitCollection.horizontalSizeClass == .regular,
            isRegularHeight: traitCollection.verticalSizeClass == .regular,
            tabLayout: duo.tabLayout,
            requestedSidebar: duo.sidebarRequest,
            paneCount: session.tabs.panes.count,
            tabCount: duo.pageTabCount,
            focusedPane: session.tabs.focusedPane,
            division: division?.frame,
            isDivisionActive: division?.isActive ?? false,
            occlusions: occlusions,
            chromeBand: chromeOnTop
                ? row.rowTop...row.rowBottom
                : min(pillFrame.minY, bounds.maxY - ChromeGeometry.pillHeight * 2)...bounds.maxY,
            sidePaneOpen: sidePaneUI.isRequested
        )
    }

    /// Decides the layout for the view's current geometry and applies what changed: the sidebar,
    /// which panes show and how wide, and the chrome's lane. Called before every layout pass.
    func updateDuoLayout() {
        guard view.bounds.width > 0 else { return }
        restoreSidebarStateIfNeeded()
        restoreSidePaneIfNeeded()
        duo.statusCorner = readStatusCorner()
        let input = layoutInput()
        let layout = DuoLayout(input)
        let previous = duo.layout
        // The row's place follows the status zone even when nothing else in the layout changed.
        applyTopBarPlacement(layout.chromeOnTop ? makeTopGeometry(stripHeight: layout.stripHeight) : nil, layout: layout)
        applySidePaneLayout(layout)
        let shown = layout.splitShown ? [0, 1] : [session.tabs.focusedPane]
        guard layout != previous || shown != panes.shown else { return }
        duo.layout = layout
        DuoUIState.logger.debug("""
            layout: area \(String(describing: input.pageArea)) fold \(String(describing: input.division)) \
            active \(input.isDivisionActive) occlusions \(String(describing: input.occlusions)) band \(String(describing: input.chromeBand)) split \(layout.splitShown) sidebar \(layout.sidebar.rawValue) \
            panes \(String(describing: layout.paneFrames)) lane \(String(describing: layout.chromeLane))
            """)
        duo.panesLeading.constant = layout.sidebarOnRight ? 0 : layout.sidebarDockWidth
        duo.panesTrailing.constant = (layout.sidebarOnRight ? -layout.sidebarDockWidth : 0) - layout.sidePaneDockWidth
        if previous?.chromeOnTop != layout.chromeOnTop { topBarModeDidChange() }
        applyStripLayout(layout)
        duo.laneLeading.constant = layout.chromeLane.lowerBound
        duo.laneWidth.constant = layout.chromeLane.upperBound - layout.chromeLane.lowerBound
        applySidebarLayout(layout)

        // Flat, the primary pane's exact width puts the split on the crease. Partly folded, the
        // arrangement itself places the panes on either side of the fold (a fixed width across
        // the fold makes it hide both).
        let primaryWidth = layout.splitShown && !input.isDivisionActive ? layout.paneFrames[0].width : nil
        panes.show(shown, primaryWidth: primaryWidth)
        updatePaneLooks()
        session.pool.defaultPaneSize = layout.focusedPaneFrame.size
        // A pane that just came on screen or left it (a fold, a split opening).
        if previous?.splitShown != layout.splitShown || previous == nil { syncPanes() }
        // The side pane left the screen with the layout (a fold to the outer screen).
        if previous?.sidePaneColumn != nil, layout.sidePaneColumn == nil { sidePaneUI.controller?.paneWillHide() }
    }

    /// The gutter and the focus ring: only while a split shows.
    func updatePaneLooks() {
        let split = duo.layout?.splitShown ?? false
        // With the side pane over the second pane, one page shows: no split look, no ring.
        let looksSplit = split && !(duo.layout?.sidePaneCoversSecondPane ?? false)
        let focused = session.tabs.focusedPane
        for (index, slot) in panes.slots.enumerated() {
            slot.setSplit(looksSplit, focused: index == focused, gutterOnLeading: index == 1, gutterOnTrailing: index == 0)
        }
        // Bar swipes and Next/Previous Tab stay in the focused pane.
        let panes = session.tabs.panes
        session.tabs.excludedFromNeighbours = split
            ? Set(panes.indices.filter { $0 != focused }.compactMap { panes[$0] })
            : []
    }

    /// Makes the other pane match the store: its tab attached when the split shows, detached when
    /// it doesn't (a fold to the outer screen keeps the pair; the hidden pane's tab is suspended).
    /// The focused pane is `show(_:)`'s.
    func syncPanes() {
        let panes = session.tabs.panes
        let focused = session.tabs.focusedPane
        let shown = shownPanes

        for index in panes.indices where index != focused {
            let wanted = shown.contains(index) ? panes[index] : nil
            guard duo.slotTabs[index] != wanted else { continue }
            if let old = duo.slotTabs[index], old != currentTab?.id, !isShownInOtherPane(old),
               let tab = session.tabs.existingTab(old) {
                session.pool.detach(tab)
            }
            duo.slotTabs[index] = nil
            guard let wanted else { continue }
            let tab = session.tabs.tab(wanted)
            session.pool.attach(tab, to: self.panes.slots[index].container)
            if let scrollView = session.pool.scrollView(for: tab) {
                // Only for `keepPageTopUnderBar`: the other callbacks act on the focused page alone.
                scrollView.delegate = self
                scrollView.hideChromeEdgeEffects()
            }
            record(wanted, inSlot: index)
            applyOtherPaneInsets(to: tab)
        }
        // A slot no pane uses any more (a closed pane).
        for index in duo.slotTabs.keys where index >= panes.count {
            duo.slotTabs[index] = nil
        }
        updatePaneLooks()
    }

    /// `id`'s web view is now in pane slot `slot` (and in no other). A tab it displaced there, on
    /// screen nowhere else, leaves the screen (detached, so the pool's tiers can reclaim it).
    func record(_ id: TabID, inSlot slot: Int) {
        if let displaced = duo.slotTabs[slot], displaced != id, displaced != currentTab?.id,
           !isShownInOtherPane(displaced), let tab = session.tabs.existingTab(displaced) {
            session.pool.detach(tab)
        }
        for (index, tab) in duo.slotTabs where tab == id && index != slot { duo.slotTabs[index] = nil }
        duo.slotTabs[slot] = id
    }

    /// `id`'s web view left the screen.
    func forgetAttachment(of id: TabID) {
        for (index, tab) in duo.slotTabs where tab == id { duo.slotTabs[index] = nil }
    }

    /// The other pane has no chrome over it, but it keeps the expanded bar's inset: switching focus
    /// then never relayouts either page. Under a top bar, which spans both panes, it follows the
    /// bar's insets instead, which never follow its resting state (`applyTopBarInsets(_:to:)`).
    func applyOtherPaneInsets(to tab: Tab) {
        // During a fold the transition's completion applies them.
        guard view.bounds.height > 0, !duo.isResizing else { return }
        if let top = duo.topGeometry {
            applyTopBarInsets(top, to: tab)
            return
        }
        setPageTopStart(0, for: session.pool.scrollView(for: tab))
        let bottom = panes.view.frame.maxY
        let geometry = ChromeGeometry(
            viewHeight: view.bounds.height, safeBottom: view.safeAreaInsets.bottom,
            hasButtonBar: !usesVerticalBar && !usesSingleRow
        )
        let expanded = geometry.expandedInset(pageBottom: bottom)
        let hidden = geometry.hiddenInset(pageBottom: bottom)
        let top = pageStatusInset
        session.pool.setInsets(
            for: tab,
            obscured: UIEdgeInsets(top: top, left: 0, bottom: expanded, right: 0),
            minimumViewport: UIEdgeInsets(top: top, left: 0, bottom: hidden, right: 0),
            maximumViewport: UIEdgeInsets(top: top, left: 0, bottom: expanded, right: 0)
        )
        session.pool.scrollView(for: tab)?.followObscuredBottom(expanded)
    }

    // MARK: Focus

    /// A touch went down in pane `index`: it becomes the focused one. A touch on an empty pane's
    /// paper (the start page) opens the search field; one on its own controls (the Search button,
    /// the shortcuts such as Private Tab, the spinnable mark) is theirs, or the field would open
    /// under the finger and take the tap from them.
    func paneTouched(_ index: Int, onControl: Bool = false) {
        guard !isShowingGallery, presentedViewController == nil, shownPanes.contains(index) else { return }
        collapseFloatingSidebar()
        if index != session.tabs.focusedPane { focusPane(index) }
        if !onControl, session.tabs.panes.indices.contains(index), session.tabs.panes[index] == nil, !isEditingAddress {
            beginAddressEditing()
        }
    }

    /// Moves the focus to pane `index`: the pill, the shared buttons and the page menu act on it.
    func focusPane(_ index: Int) {
        guard session.tabs.panes.indices.contains(index), index != session.tabs.focusedPane else { return }
        if isEditingAddress { endAddressEditing() }
        let outgoing = currentTab
        session.tabs.focusPane(index)
        if let id = session.tabs.panes[index] {
            show(session.tabs.tab(id))
        } else {
            clearPage()
        }
        focusDidChange()
        // The pane it leaves keeps its page, which may have the pill's or the hidden bar's inset:
        // it gets the other pane's expanded reserve.
        if let outgoing, outgoing !== currentTab, isShownInOtherPane(outgoing.id) { applyOtherPaneInsets(to: outgoing) }
    }

    /// The focused pane changed: the ring, the lane (the pill slides over the new pane) and the
    /// bar, which comes back expanded for the new page.
    func focusDidChange() {
        let focused = session.tabs.focusedPane
        Signposts.signposter.emitEvent(Signposts.paneFocus, "\(focused)")
        updatePaneLooks()
        duo.sidebar?.reloadTabs()
        duo.strip?.reloadTabs()
        view.setNeedsLayout()
        Motion.animate(Motion.urlFocus) { self.view.layoutIfNeeded() }
        expandChrome(animated: true)
        session.pool.defaultPaneSize = webContainer.bounds.size
    }

    /// After a pane change in the store (split, close, swap, a tab moved): the layout, the focused
    /// pane's tab and the other pane follow it.
    private func reconcilePanes(focusBefore: Int) {
        updateDuoLayout()
        view.layoutIfNeeded()
        if let id = session.tabs.selectedID {
            let tab = session.tabs.tab(id)
            if tab !== currentTab {
                show(tab)
            } else if duo.slotTabs[session.tabs.focusedPane] != id {
                // The same tab moved to the other slot: its web view changes parent, no reload.
                session.pool.attach(tab, to: webContainer)
                record(id, inSlot: session.tabs.focusedPane)
                updatePageState()
                updatePageInsets()
            }
        } else if currentTab != nil {
            clearPage()
        }
        syncPanes()
        if session.tabs.focusedPane != focusBefore { focusDidChange() }
        updateButtons()
        tabsDidChange()
    }

    // MARK: Split

    /// Opens `tab` in the other pane: the split opens when it isn't, else the other pane shows it.
    func openInOtherPane(_ tab: Tab) {
        guard canSplit else { return }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.splitOpen, id: signposter.makeSignpostID(), "tab")
        defer { signposter.endInterval(Signposts.splitOpen, interval) }
        let focusBefore = session.tabs.focusedPane
        if isSplit {
            session.tabs.show(tab.id, inPane: 1 - focusBefore)
        } else {
            session.tabs.split(showing: tab.id)
        }
        reconcilePanes(focusBefore: focusBefore)
    }

    /// Opens `url` in a new tab in the other pane (link menu). The tab is attached before it loads,
    /// so desktop or mobile is chosen from the pane it lands in.
    func openInOtherPane(_ url: URL, opener: Tab) {
        guard canSplit else { return }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.splitOpen, id: signposter.makeSignpostID(), "link")
        defer { signposter.endInterval(Signposts.splitOpen, interval) }
        let focusBefore = session.tabs.focusedPane
        let new = session.tabs.newTab(opener: opener, inBackground: true)
        if isSplit {
            session.tabs.show(new.id, inPane: 1 - focusBefore)
        } else {
            session.tabs.split(showing: new.id)
        }
        reconcilePanes(focusBefore: focusBefore)
        new.load(url)
    }

    /// Closes the focused pane; its tab stays open. The other page fills the window.
    func closeFocusedPane() {
        guard isSplit else { return }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.splitClose, id: signposter.makeSignpostID())
        defer { signposter.endInterval(Signposts.splitClose, interval) }
        let focusBefore = session.tabs.focusedPane
        session.tabs.closePane(focusBefore)
        reconcilePanes(focusBefore: focusBefore)
        // The remaining pane keeps index 0; its page needs its insets as the focused pane.
        updatePageInsets()
    }

    func swapPanes() {
        guard isSplit else { return }
        Signposts.signposter.emitEvent(Signposts.splitSwap)
        let focusBefore = session.tabs.focusedPane
        session.tabs.swapPanes()
        // Both pages change slots: drop the record so both are attached again.
        duo.slotTabs = [:]
        reconcilePanes(focusBefore: focusBefore)
        if let current = currentTab, duo.slotTabs[session.tabs.focusedPane] != current.id {
            session.pool.attach(current, to: webContainer)
            record(current.id, inSlot: session.tabs.focusedPane)
            updatePageState()
        }
        syncPanes()
        updatePageInsets()
    }

    /// The page menu's pane items: Open in Other Pane where a split can show, Swap Panes and
    /// Close Pane while one shows.
    func paneMenuItems(for tab: Tab?, rules: ControlRules) -> [UIMenuElement] {
        if rules.paneItems {
            let swap = UIAction(title: "Swap Panes", image: UIImage(systemName: "arrow.left.arrow.right")) { [weak self] _ in
                self?.swapPanes()
            }
            swap.accessibilityIdentifier = "menu.swapPanes"
            let close = UIAction(title: "Close Pane", image: UIImage(systemName: "rectangle.portrait.badge.xmark")) { [weak self] _ in
                self?.closeFocusedPane()
            }
            close.accessibilityIdentifier = "menu.closePane"
            return [swap, close]
        }
        guard rules.openInOtherPane, let tab else { return [] }
        let open = UIAction(title: "Open in Other Pane", image: UIImage(systemName: "rectangle.split.2x1")) { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            openInOtherPane(tab)
        }
        open.accessibilityIdentifier = "menu.otherPane"
        return [open]
    }

    // MARK: Fold, unfold, rotation

    /// The window is about to change size (fold, unfold, rotation). Each web view gets its final
    /// frame once: inside the transition the root view already has `size`, the layout is decided
    /// for it and laid out in one pass (the web views follow their pane by autoresizing). The page
    /// insets wait for the completion. No snapshot cover: WebKit scales its tiles, then reflows.
    /// Desktop or mobile stays what it was at navigation start.
    func windowWillResize(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        let signposter = Signposts.signposter
        if let interval = duo.resizeInterval { signposter.endInterval(Signposts.foldTransition, interval, "replaced") }
        duo.resizeInterval = signposter.beginInterval(
            Signposts.foldTransition, id: signposter.makeSignpostID(), "\(Int(size.width))x\(Int(size.height))"
        )
        DuoUIState.logger.info("viewWillTransition to \(Int(size.width))x\(Int(size.height))")
        duo.isResizing = true
        duo.resizeGeneration += 1
        let generation = duo.resizeGeneration
        tabsUI.swipe.cancel()
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            updateDuoLayout()
            view.layoutIfNeeded()
        }, completion: { [weak self] _ in
            guard let self, generation == duo.resizeGeneration else { return }
            duo.isResizing = false
            updateDuoLayout()
            syncPanes()
            updatePageInsets()
            for index in shownPanes where index != session.tabs.focusedPane {
                if let id = session.tabs.panes[index], let tab = session.tabs.existingTab(id) { applyOtherPaneInsets(to: tab) }
            }
            if let interval = duo.resizeInterval {
                signposter.endInterval(Signposts.foldTransition, interval)
                duo.resizeInterval = nil
            }
        })
    }
}
#endif
