#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import TabGalleryUI
import UIKit
import WebEngine

// MARK: - Side tabs

extension BrowserViewController {
    /// The sidebar follows the layout: on screen where side tabs are available and chosen, at the
    /// layout's width unless a finger is resizing it.
    func applySidebarLayout(_ layout: DuoLayout) {
        guard layout.showsSidebar else {
            removeSidebar()
            return
        }
        let sidebar = installSidebarIfNeeded()
        sidebar.floats = layout.sidebarFloats
        guard !duo.isDraggingSidebar else { return }
        duo.sidebarWidth?.constant = layout.sidebar.width
        sidebar.showsTitles = layout.sidebar == .expanded
        sidebar.view.isHidden = layout.sidebar == .hidden
    }

    @discardableResult
    private func installSidebarIfNeeded() -> SideTabsViewController {
        if let sidebar = duo.sidebar { return sidebar }
        let source = SideTabs(tabs: session.tabs)
        source.host = self
        let sidebar = SideTabsViewController(dataSource: source)
        sidebar.onResize = { [weak self] phase, travel, velocity in
            self?.sidebarResized(phase, travel: travel, velocity: velocity)
        }
        addChild(sidebar)
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        // Over the page (Expanded may float over it), under the chrome and the search sheet.
        view.insertSubview(sidebar.view, aboveSubview: panes.view)
        let width = sidebar.view.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            sidebar.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            sidebar.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
        duo.sideTabs = nil
        duo.sidebarWidth = nil
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
            let width = drag.trackedWidth(duo.sidebarDragStart + travel)
            widthConstraint.constant = width
            duo.sidebar?.showsTitles = width > SidebarState.rail.width + Spacing.xl
            UIView.animate(Motion.sidebarTrack) { self.view.layoutIfNeeded() }
        case .ended:
            duo.isDraggingSidebar = false
            let width = widthConstraint.constant
            let target = drag.restingState(width: width, velocity: velocity)
            let flicked = abs(velocity) > 600
            setSidebar(target, flicked: flicked)
        }
    }

    // MARK: Settings and per-window state

    /// The settings changed (read at launch, or saved in Settings): side tabs follow Tab Layout.
    func settingsDidChange() {
        let layout = data.tabLayout ?? FixedChoices.defaultTabLayout
        guard layout != duo.tabLayout else { return }
        duo.tabLayout = layout
        view.setNeedsLayout()
    }

    /// The sidebar's state is per window: it comes back with the scene.
    func restoreSidebarStateIfNeeded() {
        guard !duo.didRestoreSidebar, let scene = view.window?.windowScene else { return }
        duo.didRestoreSidebar = true
        if let raw = scene.session.userInfo?[Self.sidebarStateKey] as? String, let state = SidebarState(rawValue: raw) {
            duo.sidebarRequest = state
            if state != .hidden { duo.lastShownSidebar = state }
        }
    }

    private func saveSidebarState() {
        guard let scene = view.window?.windowScene else { return }
        var info = scene.session.userInfo ?? [:]
        info[Self.sidebarStateKey] = duo.sidebarRequest.rawValue
        scene.session.userInfo = info
    }

    private static let sidebarStateKey = "plain.sidebarState"

    #if DEBUG
    /// Debug builds only (the app's `-PlainOpen`, `-PlainSplit`, `-PlainSidebar` launch
    /// arguments): opens pages once the session is up, optionally in a split, and shows side tabs
    /// in a state, for screenshots of Duo states.
    public func debugSetUp(open pages: [URL], split: Bool, sidebar: String?) {
        guard !pages.isEmpty || sidebar != nil else { return }
        Task { [weak self] in
            // After launch's restore, so the pages are not merged into it.
            try? await Task.sleep(for: .seconds(1.5))
            // And after the saved settings, so Tab Layout does not undo the sidebar below.
            for _ in 0..<50 where self?.data.tabLayout == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self else { return }
            if let sidebar, let state = SidebarState(rawValue: sidebar) {
                duo.tabLayout = .sideTabs
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
            if split, let current = currentTab { openInOtherPane(current) }
        }
    }
    #endif
}
#endif
