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
        guard !duo.isDraggingSidebar else { return }
        duo.sidebarWidth?.constant = layout.sidebar.width
        sidebar.showsTitles = layout.sidebar == .expanded
        sidebar.view.isHidden = layout.sidebar == .hidden
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
        view.insertSubview(strip.view, aboveSubview: duo.sidebar?.view ?? panes.view)
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
        duo.strip = strip
        duo.top.stripTop = top
        placeStrip(layout)
        // It comes in at the bar's state: hidden while the bar is collapsed.
        if let geometry = duo.topGeometry { applyTopBarCollapse(collapseProgress, geometry: geometry) }
    }

    /// The strip's ends: `TopChromeGeometry.edgeMargin` inside its lane, from the root view's edges.
    func placeStrip(_ layout: DuoLayout) {
        guard duo.top.stripEnds.count == 2 else { return }
        let margin = TopChromeGeometry.edgeMargin
        duo.top.stripEnds[0].constant = layout.stripLane.lowerBound + margin
        duo.top.stripEnds[1].constant = layout.stripLane.upperBound - view.bounds.width - margin
    }

    /// The topmost of the page area's views (panes, strip, sidebar): the gallery goes above it.
    var pageAreaTopView: UIView {
        [panes.view, duo.sidebar?.view, duo.strip?.view].compactMap { $0 }.last ?? panes.view
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
        addChild(sidebar)
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        // Over the page (Expanded may float over it), under the strip, the chrome and the search sheet.
        view.insertSubview(sidebar.view, aboveSubview: panes.view)
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
    }

    /// The tab a split's other pane shows, when the split is on screen.
    var otherShownPaneTabID: TabID? {
        let panes = session.tabs.panes
        let focused = session.tabs.focusedPane
        return shownPanes.first { $0 != focused }.flatMap { panes[$0] }
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
        case .changed:
            // A Right sidebar widens toward the page, to the left.
            let width = drag.trackedWidth(duo.sidebarDragStart + (layout.sidebarOnRight ? -travel : travel))
            widthConstraint.constant = width
            duo.sidebar?.showsTitles = width > SidebarState.rail.width + Spacing.xl
            UIView.animate(Motion.sidebarTrack) { self.view.layoutIfNeeded() }
        case .ended:
            duo.isDraggingSidebar = false
            let width = widthConstraint.constant
            let target = drag.restingState(width: width, velocity: layout.sidebarOnRight ? -velocity : velocity)
            let flicked = abs(velocity) > 600
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
    /// Debug builds only (the app's `-PlainOpen`, `-PlainSplit`, `-PlainTabLayout`,
    /// `-PlainSidebar` launch arguments): opens pages once the session is up, optionally in a
    /// split, and sets Tab Layout and the sidebar's state (not saved), for screenshots of Duo states.
    public func debugSetUp(open pages: [URL], split: Bool, tabLayout: String?, sidebar: String?) {
        guard !pages.isEmpty || sidebar != nil || tabLayout != nil else { return }
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
            guard !pages.isEmpty else { return }
            endAddressEditing()
            for page in pages {
                let tab = session.tabs.newTab()
                show(tab)
                tab.load(page)
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
