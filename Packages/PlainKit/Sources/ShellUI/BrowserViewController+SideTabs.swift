#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import TabGalleryUI
import UIKit
import WebEngine

// MARK: - Tab Layout: the sidebar (Left, Right) and the strip (Above)

extension BrowserViewController {
    /// The sidebar follows the layout: on screen where Left or Right is in effect, on that side,
    /// at the layout's width unless a finger is resizing it.
    func applySidebarLayout(_ layout: DuoLayout) {
        guard layout.showsSidebar else {
            removeSidebar()
            return
        }
        let sidebar = installSidebarIfNeeded()
        placeSidebarRows(layout.chromeOnTop ? makeTopGeometry(stripHeight: layout.stripHeight) : nil, layout: layout)
        sidebar.floats = layout.sidebarFloats
        sidebar.isOnRight = layout.sidebarOnRight
        // The outgoing edge lets go first, so the two never pin the sidebar together.
        let (pin, unpin) = layout.sidebarOnRight
            ? (duo.sidebarTrailing, duo.sidebarLeading) : (duo.sidebarLeading, duo.sidebarTrailing)
        unpin?.isActive = false
        pin?.isActive = true
        sidebar.canShowTitles = layout.widestSidebar == .expanded
        guard !duo.isDraggingSidebar else { return }
        duo.sidebarWidth?.constant = layout.sidebar.width
        // The rows' selection mark and titles follow the width (inside a spring, with it).
        sidebar.visibleWidth = layout.sidebar.width
        sidebar.showsTitles = layout.sidebar == .expanded
        sidebar.view.isHidden = layout.sidebar == .hidden
        // Open over the bar (the inner screen's portrait): above the chrome before it widens. It
        // goes back under once it rests narrower (`setSidebar`'s completion), never mid-spring.
        let isDrawer = layout.sidebarFloats && layout.expandedSidebarCoversChrome
        if isDrawer { raiseSidebarOverChrome(true) } else if duo.sidebarInterval == nil { raiseSidebarOverChrome(false) }
        // The page and the bar dim under the drawer (inside a spring, with it).
        duo.sidebarScrim?.alpha = isDrawer ? 1 : 0
    }

    @objc func sidebarScrimTapped() {
        collapseFloatingSidebar()
    }

    /// The expanded sidebar opens over the top bar where the bar has no room beside it
    /// (`DuoLayout.expandedSidebarCoversChrome`): it then sits above the chrome, so its rows take
    /// the touches there. Otherwise it sits just over the pages, under the strip and the chrome.
    func raiseSidebarOverChrome(_ raised: Bool) {
        guard let sidebar = duo.sidebar, duo.isSidebarOverChrome != raised else { return }
        duo.isSidebarOverChrome = raised
        if raised {
            // A scrim between the drawer and what it covers: the page and the bar dim, take no
            // touches, and a tap there closes the drawer.
            let scrim = UIView(frame: view.bounds)
            scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scrim.backgroundColor = Palette.drawerScrim
            scrim.alpha = 0
            scrim.accessibilityIdentifier = "sideTabs.scrim"
            scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(sidebarScrimTapped)))
            view.insertSubview(scrim, aboveSubview: chromeGlass)
            view.insertSubview(sidebar.view, aboveSubview: scrim)
            duo.sidebarScrim = scrim
            // VoiceOver stays in the drawer while it covers the page and the bar; Hide Titles
            // (its last row) and the escape gesture close it.
            sidebar.view.accessibilityViewIsModal = true
            UIAccessibility.post(notification: .screenChanged, argument: sidebar.view)
        } else {
            duo.sidebarScrim?.removeFromSuperview()
            duo.sidebarScrim = nil
            sidebar.view.accessibilityViewIsModal = false
            view.insertSubview(sidebar.view, aboveSubview: duo.top.band)
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    /// The strip follows the layout: under the top bar, across the pages, where Above is in effect
    /// and there are two or more tabs. It floats over the pages and hides with the bar.
    func applyStripLayout(_ layout: DuoLayout) {
        guard layout.showsStrip else {
            if let strip = duo.strip {
                strip.willMove(toParent: nil)
                strip.view.removeFromSuperview()
                strip.removeFromParent()
                duo.strip = nil
                duo.top.stripTop = nil
                duo.top.stripEnds = []
            }
            return
        }
        guard duo.strip == nil else { return }
        let source = duo.sideTabs ?? SideTabs(tabs: session.tabs)
        source.host = self
        duo.sideTabs = source
        let strip = TabStripViewController(dataSource: source)
        addChild(strip)
        strip.view.translatesAutoresizingMaskIntoConstraints = false
        // Over the pages and the sidebar, under the chrome and the search sheet.
        view.insertSubview(strip.view, aboveSubview: (duo.isSidebarOverChrome ? nil : duo.sidebar?.view) ?? duo.top.band)
        // Under the row, from the root view's top (`applyTopBarPlacement` keeps it there).
        let geometry = makeTopGeometry(stripHeight: layout.stripHeight)
        let top = strip.view.topAnchor.constraint(equalTo: view.topAnchor, constant: geometry.stripTop)
        // Across its whole lane, under the status items too (`TopChromeGeometry.stripTop` starts
        // it below them): the screen's margin at each end, never stopping at the status corner
        // or the camera beside the row (`DuoLayout.stripLane`). Constants set by `placeStrip`.
        let ends = [
            strip.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]
        NSLayoutConstraint.activate(ends + [
            top,
            strip.view.heightAnchor.constraint(equalToConstant: layout.stripHeight),
        ])
        duo.top.stripEnds = ends
        strip.didMove(toParent: self)
        strip.onPreferredWidthChange = { [weak self] in self?.stripWidthDidChange() }
        duo.strip = strip
        strip.setPrivate(pill.isPrivateTint)
        duo.top.stripTop = top
        placeStrip(layout)
        // It comes in at the bar's state: hidden while the bar is collapsed.
        if let geometry = duo.topGeometry { applyTopBarCollapse(collapseProgress, geometry: geometry) }
    }

    /// The strip's ends, from the root view's edges: from its lane's leading margin, as wide as
    /// its tabs, at most the lane (`TopChromeGeometry.stripFrame(lane:contentWidth:)`).
    func placeStrip(_ layout: DuoLayout) {
        guard duo.top.stripEnds.count == 2 else { return }
        let frame = stripRestFrame(layout)
        duo.top.stripEnds[0].constant = frame.minX
        duo.top.stripEnds[1].constant = frame.maxX - view.bounds.width
    }

    /// Where the strip rests in `layout`.
    func stripRestFrame(_ layout: DuoLayout) -> CGRect {
        makeTopGeometry(stripHeight: layout.stripHeight)
            .stripFrame(lane: layout.stripLane, contentWidth: duo.strip?.preferredWidth)
    }

    /// A tab opened or closed in the strip: the bar grows or shrinks to its tabs in one spring
    /// (one layout pass, its frame animated by the system), its leading end in place.
    private func stripWidthDidChange() {
        guard let layout = duo.layout, let strip = duo.strip else { return }
        let before = duo.top.stripEnds.last?.constant
        placeStrip(layout)
        guard duo.top.stripEnds.last?.constant != before else { return }
        view.setNeedsLayout()
        // Off screen the constraints are enough: the next layout pass uses them.
        guard strip.view.window != nil else { return }
        Motion.animate(Motion.sidebarSettle(flicked: false), crossfading: strip.view) { self.view.layoutIfNeeded() }
    }

    /// The topmost of the page area's views (panes, strip, sidebar): the gallery goes above it.
    var pageAreaTopView: UIView {
        // A sidebar raised over the chrome is no part of the page area's stack.
        [panes.view, duo.top.band as UIView, duo.isSidebarOverChrome ? nil : duo.sidebar?.view, duo.strip?.view]
            .compactMap { $0 }.last ?? panes.view
    }

    @discardableResult
    private func installSidebarIfNeeded() -> SideTabsViewController {
        if let sidebar = duo.sidebar { return sidebar }
        let source = duo.sideTabs ?? SideTabs(tabs: session.tabs)
        source.host = self
        let sidebar = SideTabsViewController(dataSource: source)
        sidebar.onResize = { [weak self] phase, travel, velocity in
            self?.sidebarResized(phase, travel: travel, velocity: velocity)
        }
        sidebar.onToggleTitles = { [weak self] in
            guard let self, let layout = duo.layout else { return }
            Haptic.selection.play()
            setSidebar(layout.sidebar == .expanded ? .rail : .expanded, flicked: false)
        }
        addChild(sidebar)
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        // Over the page (Expanded may float over it), under the strip, the chrome and the search sheet.
        // Over the top band: an expanded sidebar floats over the pages' top (its New Tab row).
        view.insertSubview(sidebar.view, aboveSubview: duo.top.band)
        let safe = view.safeAreaLayoutGuide
        let width = sidebar.view.widthAnchor.constraint(equalToConstant: 0)
        // Right sits inside the system's vertical bar, which is on the trailing edge too.
        duo.sidebarLeading = sidebar.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor)
        duo.sidebarTrailing = sidebar.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        NSLayoutConstraint.activate([
            // From the top edge, so no strip of the root view's paper sits above the column; its
            // tabs start under the safe area (`SideTabsViewController`).
            sidebar.view.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            width,
        ])
        sidebar.didMove(toParent: self)
        sidebar.setPrivate(pill.isPrivateTint)
        duo.sidebar = sidebar
        duo.sideTabs = source
        duo.sidebarWidth = width
        return sidebar
    }

    private func removeSidebar() {
        guard let sidebar = duo.sidebar else { return }
        sidebar.willMove(toParent: nil)
        sidebar.view.removeFromSuperview()
        sidebar.removeFromParent()
        duo.sidebar = nil
        duo.sidebarWidth = nil
        duo.sidebarLeading = nil
        duo.sidebarTrailing = nil
        duo.isDraggingSidebar = false
        duo.isSidebarOverChrome = false
        duo.sidebarScrim?.removeFromSuperview()
        duo.sidebarScrim = nil
    }

    /// The tab a split's other pane shows, when the split is on screen.
    var otherShownPaneTabID: TabID? {
        let panes = session.tabs.panes
        let focused = session.tabs.focusedPane
        return shownPanes.first { $0 != focused }.flatMap { panes[$0] }
    }

    // MARK: Private mode

    /// The window is in private mode (docs/decisions.md, "Private as a clear mode on wide
    /// screens"): the tab on screen is private, or, on a split's empty pane, the other pane's is.
    /// One window, one mode: the strip, the sidebar, New Tab and the chrome all follow it, and
    /// each window has its own (it is read from the window's own panes).
    var showsPrivateMode: Bool {
        if let currentTab { return currentTab.isPrivate }
        let panes = session.tabs.panes
        let focused = session.tabs.focusedPane
        return panes.indices.contains { index in
            index != focused && panes[index].map { session.tabs.store.tabs[$0]?.isPrivate == true } == true
        }
    }

    /// The Private | Tabs switch (the strip's end, the sidebar's head): the list's tab seen last
    /// comes on screen, else a new empty tab of that kind with the search field (the private one
    /// over its own start screen). The tabs of the mode left stay open, as on the phone, until
    /// closed.
    func showTabMode(private isPrivate: Bool) {
        guard isPrivate != showsPrivateMode else { return }
        Signposts.signposter.emitEvent(Signposts.privateMode, "\(isPrivate ? "enter" : "leave")")
        if isEditingAddress { endAddressEditing() }
        if let id = session.tabs.mostRecent(private: isPrivate) {
            show(session.tabs.tab(id))
        } else {
            openNewTab(private: isPrivate)
            // The mode was asked for: closing the field untouched stays in it, on its start
            // screen, rather than going back to the page of the other mode.
            tabsUI.newTabReturn = nil
        }
        collapseFloatingSidebar()
    }

    /// A split shows one mode (docs/decisions.md, "Private as a clear mode on wide screens"): a
    /// tab of the other kind coming into the focused pane first closes the other pane. Its tab
    /// stays open in its own list; the window shows the one pane. Nothing happens outside a
    /// split, or when the other pane is empty or of `tab`'s kind.
    func endSplitOfOtherMode(before tab: Tab) {
        let panes = session.tabs.panes
        guard panes.count > 1 else { return }
        let focused = session.tabs.focusedPane
        guard let other = panes.indices.first(where: { $0 != focused }), let otherID = panes[other], otherID != tab.id,
              let entry = session.tabs.store.tabs[otherID], entry.isPrivate != tab.isPrivate else { return }
        Signposts.signposter.emitEvent(Signposts.privateMode, "split ended")
        // Its page leaves the screen: the pool may reclaim it.
        if otherID != currentTab?.id, let otherTab = session.tabs.existingTab(otherID) {
            session.pool.detach(otherTab)
            forgetAttachment(of: otherID)
        }
        session.tabs.closePane(other, touching: false)
        // Only the panes' layout here: the `show` this runs in puts `tab` on screen once. The
        // outgoing tab leaves the screen there too, so it is not moved to the remaining slot.
        updateDuoLayout()
        syncPanes()
        if session.tabs.focusedPane != focused { focusDidChange() }
    }

    /// A row tapped: the tab shows in the focused pane (or its pane gets the focus). A floating
    /// sidebar steps back to the rail so the page is in view.
    func sideTabsSelect(_ id: TabID) {
        if isEditingAddress { endAddressEditing() }
        let tab = session.tabs.tab(id)
        let focusBefore = session.tabs.focusedPane
        show(tab)
        if session.tabs.focusedPane != focusBefore { updatePaneLooks() }
        collapseFloatingSidebar()
    }

    // MARK: States

    /// The Tabs button with side tabs on: hides the sidebar, or brings it back as it was. Returns
    /// false where side tabs don't show (the button opens the gallery).
    func toggleSidebar() -> Bool {
        guard let layout = duo.layout, layout.showsSidebar else { return false }
        let target: SidebarState = layout.sidebar == .hidden ? duo.lastShownSidebar : .hidden
        setSidebar(target, flicked: false)
        return true
    }

    /// Expanded floating over the page goes back to the rail (a tab picked, the page touched).
    func collapseFloatingSidebar() {
        guard duo.layout?.sidebarFloats == true, !duo.isDraggingSidebar else { return }
        setSidebar(.rail, flicked: false)
    }

    /// Springs the sidebar to `state` (the layout may limit it), then lets the panes follow. The
    /// pages resize once, inside the spring, when the docked width changes.
    func setSidebar(_ state: SidebarState, flicked: Bool) {
        duo.sidebarRequest = state
        if state != .hidden { duo.lastShownSidebar = state }
        saveSidebarState()
        let signposter = Signposts.signposter
        if let interval = duo.sidebarInterval { signposter.endInterval(Signposts.sidebarState, interval, "replaced") }
        let interval = signposter.beginInterval(Signposts.sidebarState, id: signposter.makeSignpostID(), "\(state.rawValue)")
        duo.sidebarInterval = interval
        duo.sidebar?.view.isHidden = false
        view.setNeedsLayout()
        Motion.animate(Motion.sidebarSettle(flicked: flicked), crossfading: view, changes: {
            self.updateDuoLayout()
            // Back to the resting width even when the state did not change (a short drag).
            if let layout = self.duo.layout { self.applySidebarLayout(layout) }
            self.duo.sidebar?.view.isHidden = false
            self.view.layoutIfNeeded()
        }, completion: { [weak self] in
            guard let self, duo.sidebarInterval === interval else { return }
            duo.sidebarInterval = nil
            duo.sidebar?.view.isHidden = duo.layout?.sidebar == .hidden
            // At rest narrower than Expanded, it is back under the chrome.
            if duo.layout?.sidebarFloats != true { raiseSidebarOverChrome(false) }
            let rested = duo.layout?.sidebar.rawValue ?? "hidden"
            signposter.endInterval(Signposts.sidebarState, interval, "\(rested)")
        })
    }

    /// A horizontal drag on the sidebar: its edge follows the finger between Hidden and the widest
    /// state allowed now (rubber-banding past it), then springs to the nearest state, flicks
    /// carrying it on. The pages keep their width while the finger moves.
    private func sidebarResized(_ phase: SideTabsViewController.ResizePhase, travel: CGFloat, velocity: CGFloat) {
        guard let layout = duo.layout, let widthConstraint = duo.sidebarWidth else { return }
        let drag = SidebarDrag(widest: layout.widestSidebar)
        switch phase {
        case .began:
            duo.isDraggingSidebar = true
            duo.sidebarDragStart = widthConstraint.constant
            duo.dragShowsTitles = layout.sidebar == .expanded
            Haptic.selection.prepare()
            // Where it will open over the bar, it is over it from the first point of the drag.
            if layout.expandedSidebarCoversChrome, layout.widestSidebar == .expanded { raiseSidebarOverChrome(true) }
        case .changed:
            // A Right sidebar widens toward the page, to the left.
            let width = drag.trackedWidth(duo.sidebarDragStart + (layout.sidebarOnRight ? -travel : travel))
            widthConstraint.constant = width
            let rail = SidebarState.rail.width
            let open = min(max((width - rail) / (SidebarState.expanded.width - rail), 0), 1)
            // One tick as the titles come in or go, not a chatter at the edge: they count as
            // showing past `sidebarTitlesTickOn` of the way and as gone under `...TickOff`.
            let flips = duo.dragShowsTitles
                ? open < CGFloat(FixedChoices.sidebarTitlesTick.off) : open > CGFloat(FixedChoices.sidebarTitlesTick.on)
            if flips {
                duo.dragShowsTitles.toggle()
                Haptic.selection.play()
            }
            UIView.animate(Motion.sidebarTrack) {
                self.duo.sidebarScrim?.alpha = open
                self.duo.sidebar?.visibleWidth = width
                self.view.layoutIfNeeded()
            }
        case .ended:
            duo.isDraggingSidebar = false
            let width = widthConstraint.constant
            let target = drag.restingState(width: width, velocity: layout.sidebarOnRight ? -velocity : velocity)
            let flicked = abs(velocity) > 600
            // A flick that carries the titles in or out past where the finger left them.
            if (target == .expanded) != duo.dragShowsTitles, target != .hidden || duo.dragShowsTitles {
                duo.dragShowsTitles = target == .expanded
                Haptic.selection.play()
            }
            setSidebar(target, flicked: flicked)
        }
    }

    // MARK: Settings and per-window state

    /// The settings changed (read at launch, or saved in Settings): side tabs follow Tab Layout.
    func settingsDidChange() {
        applyAppearance()
        applyDarkPagesSetting()
        let layout = data.tabLayout ?? FixedChoices.defaultTabLayout
        guard layout != duo.tabLayout else { return }
        duo.tabLayout = layout
        view.setNeedsLayout()
    }

    /// The sidebar's state is per window: it comes back with the scene.
    func restoreSidebarStateIfNeeded() {
        guard !duo.didRestoreSidebar, let scene = view.window?.windowScene else { return }
        duo.didRestoreSidebar = true
        if let raw = SceneState.string(forKey: Self.sidebarStateKey, in: scene.session),
           let state = SidebarState(rawValue: raw) {
            duo.sidebarRequest = state
            if state != .hidden { duo.lastShownSidebar = state }
        }
    }

    private func saveSidebarState() {
        guard let scene = view.window?.windowScene else { return }
        SceneState.set(duo.sidebarRequest.rawValue, forKey: Self.sidebarStateKey, in: scene.session)
    }

    private static let sidebarStateKey = "plain.sidebarState"

    #if DEBUG
    /// Debug builds only (`-PlainSidebarWalk <seconds>`): after `delay`, walks the tab list through
    /// its motions with pauses, for a screen recording of the inner screen (XCUITest can't drive
    /// it there): titles in and out, a tab picked, a tab opened and closed, the sidebar hidden
    /// and back.
    public func debugSidebarWalk(after delay: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            func pause() async { try? await Task.sleep(for: .seconds(1.6)) }
            guard let self else { return }
            // With one tab: the list comes in with the second and leaves with it, twice.
            if session.tabs.otherTabCount(besides: nil) == 1 {
                for _ in 0..<2 {
                    let added = session.tabs.newTab()
                    show(added)
                    added.load(URL(string: "https://example.org")!)
                    tabsDidChange()
                    await pause()
                    await pause()
                    galleryCloseTab(added.id)
                    tabsDidChange()
                    await pause()
                }
                return
            }
            if duo.layout?.showsSidebar == true {
                setSidebar(.expanded, flicked: false)
                await pause()
                setSidebar(.rail, flicked: false)
                await pause()
            }
            let tabs = session.tabs.galleryItems(private: false)
            if tabs.count > 1 {
                sideTabsSelect(tabs[1].id)
                tabsDidChange()
                await pause()
                sideTabsSelect(tabs[0].id)
                tabsDidChange()
                await pause()
            }
            let added = session.tabs.newTab()
            show(added)
            added.load(URL(string: "https://example.org")!)
            await pause()
            await pause()
            galleryCloseTab(added.id)
            tabsDidChange()
            await pause()
            if toggleSidebar() {
                await pause()
                _ = toggleSidebar()
            }
        }
    }

    /// Debug builds only (the app's `-PlainOpen`, `-PlainOpenPrivate`, `-PlainSplit`,
    /// `-PlainTabLayout`, `-PlainSidebar` launch arguments): opens pages once the session is up
    /// (then private ones), optionally in a split, and sets Tab Layout and the sidebar's state
    /// (not saved), for screenshots of Duo states. More than four pages open one at a time, each
    /// waiting for the one before to finish, so every tab has its title and its site's icon.
    public func debugSetUp(open pages: [URL], privatePages: [URL] = [], split: Bool, tabLayout: String?, sidebar: String?) {
        guard !pages.isEmpty || !privatePages.isEmpty || sidebar != nil || tabLayout != nil else { return }
        Task { [weak self] in
            // After launch's restore, so the pages are not merged into it.
            try? await Task.sleep(for: .seconds(1.5))
            // And after the saved settings, so Tab Layout does not undo the sidebar below.
            for _ in 0..<50 where self?.data.tabLayout == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self else { return }
            if let tabLayout, let layout = TabLayout(rawValue: tabLayout) {
                duo.tabLayout = layout
                view.setNeedsLayout()
            }
            if let sidebar, let state = SidebarState(rawValue: sidebar) {
                duo.sidebarRequest = state
                if state != .hidden { duo.lastShownSidebar = state }
                view.setNeedsLayout()
            }
            // A capture of a layout shows the page, not the search field a launch may open.
            endAddressEditing()
            guard !pages.isEmpty || !privatePages.isEmpty else { return }
            let paced = pages.count + privatePages.count > 4
            for (page, isPrivate) in pages.map({ ($0, false) }) + privatePages.map({ ($0, true) }) {
                let tab = session.tabs.newTab(isPrivate: isPrivate)
                show(tab)
                tab.load(page)
                guard paced else { continue }
                try? await Task.sleep(for: .milliseconds(400))
                for _ in 0..<50 where tab.isLoading {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            guard split else { return }
            // A window made wide after launch (a resizable window standing in for the inner
            // screen) splits once it can.
            for _ in 0..<300 where !canSplit {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let current = currentTab { openInOtherPane(current) }
        }
    }

    /// Debug builds only (`-PlainPrivate`): an empty private tab once the session is up, or
    /// `pages` in private tabs, for screenshots of private states where the UI can't be driven
    /// (a resizable window standing in for the Duo's inner screen).
    public func debugOpenPrivate(_ pages: [URL]) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            endAddressEditing()
            if pages.isEmpty { show(session.tabs.newTab(isPrivate: true)) }
            for page in pages {
                let tab = session.tabs.newTab(isPrivate: true)
                show(tab)
                tab.load(page)
            }
        }
    }
    #endif
}
#endif
