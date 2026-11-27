#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import UIKit
import WebEngine

/// The side pane's state in one window: whether the user opened it, what it shows, its
/// constraints and the edge swipe. One stored property on `BrowserViewController`.
final class SidePaneUIState {
    var controller: SidePaneController?
    /// The user opened it (More, the edge swipe, History, Find on Page). It shows where the layout
    /// allows (`DuoLayout.sidePaneColumn`), and comes back there after a fold.
    var isRequested = false
    var section: SidePaneSection = .reader
    var leading: NSLayoutConstraint?
    var width: NSLayoutConstraint?
    /// The open and close spring is running: layout passes leave the pane's transform to it.
    var isAnimating = false
    /// The edge swipe that opens it, and the column it is dragging the pane into.
    let edgePan = UIScreenEdgePanGestureRecognizer()
    var dragColumn: CGRect?
    var gestures: SidePaneGestures?
    var openInterval: OSSignpostIntervalState?
    /// The state was read from the scene once.
    var didRestore = false
}

// MARK: - The side pane (Reader, Find, History next to the page)

/// On a wide screen (the top bar's screens: the Duo's inner screen) the side pane shows the page's
/// article, Find's matches or History in a column beside the page: 30% of the pages' width, at
/// least 250 pt, on the trailing side. In a split it takes the second pane's place; partly folded
/// the page and the pane take one side of the fold each. More's Show Side Pane, a swipe in from the
/// trailing edge, History and Find on Page open it; its close button, a swipe toward the edge and
/// More's Hide Side Pane close it. Opening narrows the page once, inside the pane's spring.
extension BrowserViewController {
    /// The side pane is open and on screen.
    var isSidePaneShown: Bool { sidePaneUI.isRequested && duo.layout?.sidePaneColumn != nil }

    /// Sets up the edge swipe. Called once from `viewDidLoad`.
    func installSidePane() {
        let gestures = SidePaneGestures(browser: self)
        sidePaneUI.gestures = gestures
        let pan = sidePaneUI.edgePan
        pan.edges = .right
        pan.delegate = gestures
        pan.addTarget(gestures, action: #selector(SidePaneGestures.edgePanned(_:)))
        view.addGestureRecognizer(pan)
        // The reader check reports after a load: the pane's Reader may have an article now.
        session.reader.onAvailability = { [weak self] webView, _ in
            guard let self, let tab = currentTab, session.pool.webView(for: tab) === webView else { return }
            sidePanePageDidChange()
        }
    }

    /// Opens the pane on `section` (or what it showed last), animated.
    func openSidePane(_ section: SidePaneSection? = nil, focus: Bool = false) {
        guard duo.layout?.sidePaneAvailable == true else { return Haptic.nothingThere.play() }
        let controller = makeSidePaneIfNeeded()
        if sidePaneUI.isRequested {
            showSidePaneSection(section ?? sidePaneUI.section)
            if focus { controller.focusSection() }
            return
        }
        if let section { sidePaneUI.section = section }
        let signposter = Signposts.signposter
        sidePaneUI.openInterval = signposter.beginInterval(
            Signposts.sidePaneOpen, id: signposter.makeSignpostID(), "\(self.sidePaneUI.section.rawValue)"
        )
        controller.show(sidePaneUI.section)
        // In a split the pane takes the second pane's place: the first is the page it serves.
        if isSplit, session.tabs.focusedPane != 0 { focusPane(0) }
        setSidePane(open: true, flicked: false)
        if focus { controller.focusSection() }
    }

    /// Closes the pane; the page gets its width back inside the same spring.
    func closeSidePane(animated: Bool, flicked: Bool = false) {
        guard sidePaneUI.isRequested else { return }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.sidePaneClose, id: signposter.makeSignpostID())
        sidePaneUI.controller?.paneWillHide()
        setSidePane(open: false, flicked: flicked, animated: animated) {
            signposter.endInterval(Signposts.sidePaneClose, interval)
        }
    }

    func toggleSidePane() {
        sidePaneUI.isRequested ? closeSidePane(animated: true) : openSidePane()
    }

    /// The segmented control (or History, Find on Page) picked `section`.
    func showSidePaneSection(_ section: SidePaneSection) {
        if sidePaneUI.section != section {
            Signposts.signposter.emitEvent(Signposts.sidePaneSection, "\(section.rawValue)")
            sidePaneUI.controller?.paneWillHide()
        }
        sidePaneUI.section = section
        sidePaneUI.controller?.show(section)
        saveSidePaneState()
    }

    /// The focused page changed: the pane's section follows it.
    func sidePanePageDidChange() {
        guard isSidePaneShown else { return }
        sidePaneUI.controller?.pageDidChange()
    }

    /// The page menu's item: Show or Hide Side Pane where the pane can show.
    func sidePaneMenuItems(_ rules: ControlRules) -> [UIMenuElement] {
        switch rules.sidePane {
        case .hidden:
            return []
        case .show:
            let show = UIAction(title: "Show Side Pane", image: UIImage(systemName: "sidebar.trailing")) { [weak self] _ in
                self?.openSidePane()
            }
            show.accessibilityIdentifier = "menu.sidePane"
            return [show]
        case .hide:
            let hide = UIAction(title: "Hide Side Pane", image: UIImage(systemName: "sidebar.trailing")) { [weak self] _ in
                self?.closeSidePane(animated: true)
            }
            hide.accessibilityIdentifier = "menu.sidePane"
            return [hide]
        }
    }

    // MARK: Layout

    /// Places the pane in its column (or out of sight), under the top bar's row and clear of the
    /// status corner. Called on every Duo layout pass, before the guard that skips unchanged
    /// layouts, since the row and the corner move on their own.
    func applySidePaneLayout(_ layout: DuoLayout) {
        guard let controller = sidePaneUI.controller else { return }
        let column = (sidePaneUI.isRequested ? layout.sidePaneColumn : nil) ?? sidePaneUI.dragColumn
        guard let column else {
            if !sidePaneUI.isAnimating { controller.view.isHidden = true }
            panes.slots[1].view.isHidden = false
            return
        }
        controller.view.isHidden = false
        setConstant(sidePaneUI.leading, column.minX)
        setConstant(sidePaneUI.width, column.width)
        controller.setHeaderTop(sidePaneHeaderTop(column: column))
        // Partly folded, a gap (the fold) lies between the page and the pane.
        controller.setSeparatorHidden(layout.sidePaneDockWidth > column.width + 0.5)
        // A covered second pane keeps its page, out of sight (no touches, no drawing).
        panes.slots[1].view.isHidden = sidePaneUI.isRequested && layout.sidePaneCoversSecondPane
    }

    /// Level with the top bar's row, or under the status items where they sit over the column
    /// (the Duo's clock and battery in the top-trailing corner).
    private func sidePaneHeaderTop(column: CGRect) -> CGFloat {
        let geometry = makeTopGeometry(stripHeight: 0)
        if let corner = geometry.corner, corner.maxX > column.minX, corner.minX < column.maxX {
            return max(geometry.rowBottom, corner.maxY) + TopChromeGeometry.gap
        }
        return geometry.rowTop
    }

    private func setConstant(_ constraint: NSLayoutConstraint?, _ value: CGFloat) {
        guard let constraint, constraint.constant != value else { return }
        constraint.constant = value
    }

    private func makeSidePaneIfNeeded() -> SidePaneController {
        if let controller = sidePaneUI.controller { return controller }
        let controller = SidePaneController()
        controller.browser = self
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        // Over the pages, the sidebar and the strip; under the chrome, the toast and the search sheet.
        view.insertSubview(controller.view, aboveSubview: duo.strip?.view ?? duo.sidebar?.view ?? panes.view)
        let leading = controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let width = controller.view.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            leading, width,
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        controller.view.isHidden = true
        let swipe = UISwipeGestureRecognizer(target: sidePaneUI.gestures, action: #selector(SidePaneGestures.paneSwiped(_:)))
        swipe.direction = .right
        controller.view.addGestureRecognizer(swipe)
        sidePaneUI.controller = controller
        sidePaneUI.leading = leading
        sidePaneUI.width = width
        return controller
    }

    /// Opens or closes the pane: the layout is decided for the new state and laid out once inside
    /// the spring (each web view gets one new frame), the pane slides in from or out to the
    /// trailing edge, and the page insets follow in the completion.
    func setSidePane(open: Bool, flicked: Bool, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard let controller = sidePaneUI.controller else { return }
        sidePaneUI.isRequested = open
        sidePaneUI.isAnimating = true
        saveSidePaneState()
        let offset = (sidePaneUI.width?.constant ?? 0) + Spacing.s
        if open {
            controller.view.isHidden = false
            if sidePaneUI.dragColumn == nil { controller.view.transform = CGAffineTransform(translationX: offset, y: 0) }
        }
        sidePaneUI.dragColumn = nil
        let changes = { [self] in
            updateDuoLayout()
            view.layoutIfNeeded()
            let width = sidePaneUI.width?.constant ?? offset
            controller.view.transform = open ? .identity : CGAffineTransform(translationX: width + Spacing.s, y: 0)
        }
        let done = { [weak self] in
            guard let self else { return }
            sidePaneUI.isAnimating = false
            if !sidePaneUI.isRequested {
                controller.view.isHidden = true
                controller.view.transform = .identity
            }
            updateDuoLayout()
            updatePageInsets()
            updateButtons()
            if open { sidePaneUI.controller?.pageDidChange() }
            if let interval = sidePaneUI.openInterval {
                Signposts.signposter.endInterval(Signposts.sidePaneOpen, interval)
                sidePaneUI.openInterval = nil
            }
            completion?()
        }
        guard animated else {
            changes()
            done()
            return
        }
        Motion.animate(Motion.sidebarSettle(flicked: flicked), changes: changes, completion: done)
    }

    #if DEBUG
    /// `-PlainSidePane reader|find|history` (and `-PlainFind <text>` for Find), Debug builds: the
    /// pane open after launch's pages have loaded, for captures of states a test reaches by touch.
    public func debugSidePane(_ value: String?, find: String?) {
        guard let value, let section = SidePaneSection(rawValue: value) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            for _ in 0..<100 where self?.duo.layout?.sidePaneAvailable != true {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self else { return }
            openSidePane(section)
            if let find, section == .find {
                try? await Task.sleep(for: .seconds(0.6))
                sidePaneUI.controller?.debugFind(find)
            }
        }
    }
    #endif

    // MARK: Per window

    /// The pane's state comes back with the window (`SceneState`).
    func restoreSidePaneIfNeeded() {
        guard !sidePaneUI.didRestore, let scene = view.window?.windowScene else { return }
        sidePaneUI.didRestore = true
        guard let raw = SceneState.string(forKey: Self.sidePaneKey, in: scene.session) else { return }
        let parts = raw.split(separator: ":").map(String.init)
        if let name = parts.last, let section = SidePaneSection(rawValue: name) { sidePaneUI.section = section }
        guard parts.first == "open" else { return }
        sidePaneUI.isRequested = true
        makeSidePaneIfNeeded().show(sidePaneUI.section)
    }

    private func saveSidePaneState() {
        guard let scene = view.window?.windowScene else { return }
        let value = "\(sidePaneUI.isRequested ? "open" : "closed"):\(sidePaneUI.section.rawValue)"
        SceneState.set(value, forKey: Self.sidePaneKey, in: scene.session)
    }

    private static let sidePaneKey = "plain.sidePane"

    // MARK: The edge swipe

    /// The swipe in from the trailing edge may begin: the pane can show and is closed, and nothing
    /// else holds the screen.
    var sidePaneSwipeMayBegin: Bool {
        duo.layout?.sidePaneAvailable == true && !sidePaneUI.isRequested && !isEditingAddress && !isShowingGallery
            && presentedViewController == nil && !sidePaneUI.isAnimating
    }

    /// The column the pane would take if it opened now.
    func sidePaneColumnIfOpened() -> CGRect? {
        guard duo.layout != nil else { return nil }
        var input = layoutInput()
        input.sidePaneOpen = true
        return DuoLayout(input).sidePaneColumn
    }

    func sidePaneEdgePanChanged(_ pan: UIScreenEdgePanGestureRecognizer) {
        let travel = max(0, -pan.translation(in: view).x)
        switch pan.state {
        case .began:
            guard let column = sidePaneColumnIfOpened() else { return }
            let controller = makeSidePaneIfNeeded()
            controller.show(sidePaneUI.section)
            sidePaneUI.dragColumn = column
            if let layout = duo.layout { applySidePaneLayout(layout) }
            view.layoutIfNeeded()
            controller.view.transform = CGAffineTransform(translationX: column.width + Spacing.s - travel, y: 0)
        case .changed:
            guard let column = sidePaneUI.dragColumn, let controller = sidePaneUI.controller else { return }
            // Past the column it moves at a quarter of the finger's speed.
            let reach = column.width + Spacing.s
            let moved = travel <= reach ? travel : reach + (travel - reach) * CGFloat(FixedChoices.sidePaneOverdragFactor)
            controller.view.transform = CGAffineTransform(translationX: reach - moved, y: 0)
        case .ended, .cancelled, .failed:
            guard let column = sidePaneUI.dragColumn, let controller = sidePaneUI.controller else { return }
            let velocity = -pan.velocity(in: view).x
            let flick = CGFloat(FixedChoices.sidePaneFlickVelocity)
            let opens = pan.state == .ended && velocity > -flick / 2
                && (travel > column.width * CGFloat(FixedChoices.sidePaneOpenFraction) || velocity > flick)
            if opens {
                let signposter = Signposts.signposter
                sidePaneUI.openInterval = signposter.beginInterval(
                    Signposts.sidePaneOpen, id: signposter.makeSignpostID(), "swipe \(self.sidePaneUI.section.rawValue)"
                )
                if isSplit, session.tabs.focusedPane != 0 { focusPane(0) }
                setSidePane(open: true, flicked: velocity > flick)
            } else {
                sidePaneUI.isAnimating = true
                Motion.animate(Motion.sidebarSettle(flicked: false), changes: {
                    controller.view.transform = CGAffineTransform(translationX: column.width + Spacing.s, y: 0)
                }, completion: { [weak self] in
                    guard let self else { return }
                    sidePaneUI.isAnimating = false
                    sidePaneUI.dragColumn = nil
                    // The swipe built the section to show it: it lets go of what it holds.
                    controller.paneWillHide()
                    controller.view.transform = .identity
                    if let layout = duo.layout { applySidePaneLayout(layout) }
                })
            }
        default:
            break
        }
    }
}

/// The side pane's gestures: the swipe in from the trailing edge opens it, a swipe toward the edge
/// on the pane closes it. The edge swipe takes the trailing edge from WebKit's swipe forward where
/// the pane can open (the top bar's Forward button stays); elsewhere it never begins and WebKit's
/// swipe works as before.
final class SidePaneGestures: NSObject, UIGestureRecognizerDelegate {
    private weak var browser: BrowserViewController?

    init(browser: BrowserViewController) {
        self.browser = browser
    }

    @objc func edgePanned(_ pan: UIScreenEdgePanGestureRecognizer) {
        browser?.sidePaneEdgePanChanged(pan)
    }

    @objc func paneSwiped(_ swipe: UISwipeGestureRecognizer) {
        guard swipe.state == .ended else { return }
        browser?.closeSidePane(animated: true, flicked: true)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        browser?.sidePaneSwipeMayBegin ?? false
    }

    /// WebKit's own edge swipe (forward, from the right edge) waits for this one to fail.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        guard let browser, let edge = other as? UIScreenEdgePanGestureRecognizer, edge !== gestureRecognizer,
              edge.edges.contains(.right), let view = edge.view else { return false }
        return view.isDescendant(of: browser.view)
    }
}
#endif
