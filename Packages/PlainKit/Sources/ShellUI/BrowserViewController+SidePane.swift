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
    var closeInterval: OSSignpostIntervalState?
    /// The state was read from the scene once.
    var didRestore = false
    /// The width the divider rests at in this window, and whether the pane has the whole width.
    /// What the layout is decided from: a drag changes them when it commits
    /// (`SidePaneDividerController`), and they come back with the scene.
    var restWidth: SidePaneWidth = .narrow
    var takesOver = false
    /// The page shows although the layout has the pane take over: a drag or a settle is giving
    /// the width back.
    var revealsPage = false
    /// The divider between the page and the pane: its handle, drag, settle and keys.
    var divider: SidePaneDividerController?
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
        // The pane opens beside the page at the window's width, never over it.
        sidePaneUI.takesOver = false
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
        sidePaneUI.divider?.cancel()
        sidePaneUI.controller?.paneWillHide()
        // Closing gives the page back; the next open is beside it again.
        sidePaneUI.takesOver = false
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
        // A divider drag or settle places the pane itself (`dragColumn`), as the edge swipe does.
        let column = sidePaneUI.dragColumn ?? (sidePaneUI.isRequested ? layout.sidePaneColumn : nil)
        guard let column else {
            if !sidePaneUI.isAnimating { controller.view.isHidden = true }
            panes.slots[1].view.isHidden = false
            if panes.view.isHidden { panes.view.isHidden = false }
            sidePaneUI.divider?.place(column: nil, layout: layout)
            return
        }
        controller.view.isHidden = false
        setConstant(sidePaneUI.leading, column.minX)
        setConstant(sidePaneUI.width, column.width)
        controller.setHeaderTop(sidePaneHeaderTop(column: column, layout: layout))
        // Partly folded, a gap (the fold) lies between the page and the pane.
        controller.setSeparatorHidden(
            layout.sidePaneDockWidth > column.width + 0.5 && sidePaneUI.dragColumn == nil && !layout.sidePaneTakesOver
        )
        if sidePaneUI.isRequested { controller.setTakeOver(available: layout.sidePaneDivider != nil, active: layout.sidePaneTakesOver) }
        // A covered second pane keeps its page, out of sight (no touches, no drawing); with the
        // whole width every page does, at the frame it keeps for coming back.
        panes.slots[1].view.isHidden = sidePaneUI.isRequested && layout.sidePaneCoversSecondPane
        let hidesPages = sidePaneUI.isRequested && layout.sidePaneTakesOver && !sidePaneUI.revealsPage
        if panes.view.isHidden != hidesPages { panes.view.isHidden = hidesPages }
        sidePaneUI.divider?.place(column: sidePaneUI.isRequested ? column : nil, layout: layout)
    }

    /// Level with the top bar's row beside it; under the row where the bar is over the column (the
    /// pane with the whole width, or dragged past the page's minimum); under the status items where
    /// they sit over the column (the Duo's clock and battery in the top-trailing corner).
    func sidePaneHeaderTop(column: CGRect, layout: DuoLayout) -> CGFloat {
        let geometry = makeTopGeometry(stripHeight: 0)
        let laneEnd = duo.laneLeading.constant + duo.laneWidth.constant
        if layout.chromeOnTop, laneEnd > column.minX + 1 { return geometry.rowBottom + TopChromeGeometry.gap }
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
        swipe.delegate = sidePaneUI.gestures
        controller.view.addGestureRecognizer(swipe)
        sidePaneUI.controller = controller
        sidePaneUI.leading = leading
        sidePaneUI.width = width
        sidePaneUI.divider = SidePaneDividerController(browser: self, pane: controller)
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
        // The column it opens into (the divider may have left the constraint at another width).
        let offset = ((open ? sidePaneColumnIfOpened()?.width : nil) ?? sidePaneUI.width?.constant ?? 0) + Spacing.s
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
    /// `-PlainSidePaneWidth narrow|half|wide|full` opens it at that width (not saved).
    public func debugSidePane(_ value: String?, find: String?) {
        guard let value, let section = SidePaneSection(rawValue: value) else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let width = arguments.firstIndex(of: "-PlainSidePaneWidth").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            for _ in 0..<100 where self?.duo.layout?.sidePaneAvailable != true {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self else { return }
            if let width, let rest = SidePaneWidth(rawValue: width) { sidePaneUI.restWidth = rest }
            openSidePane(section)
            if width == "full" {
                try? await Task.sleep(for: .seconds(0.6))
                toggleSidePaneTakeOver()
            }
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
        // "open|closed:<section>[:<width>[:full]]" (the width since the divider; an older value
        // has none and opens Narrow).
        let parts = raw.split(separator: ":").map(String.init)
        if parts.count > 1, let section = SidePaneSection(rawValue: parts[1]) { sidePaneUI.section = section }
        if parts.count > 2, let width = SidePaneWidth(rawValue: parts[2]) { sidePaneUI.restWidth = width }
        guard parts.first == "open" else { return }
        sidePaneUI.isRequested = true
        sidePaneUI.takesOver = parts.count > 3 && parts[3] == "full"
        makeSidePaneIfNeeded().show(sidePaneUI.section)
    }

    func saveSidePaneState() {
        guard let scene = view.window?.windowScene else { return }
        var value = "\(sidePaneUI.isRequested ? "open" : "closed"):\(sidePaneUI.section.rawValue):\(sidePaneUI.restWidth.rawValue)"
        if sidePaneUI.isRequested, sidePaneUI.takesOver { value += ":full" }
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

    /// The divider may take a drag, a tap or a key: the pane is open beside the page (or over it)
    /// with nothing over the screen and no fold or rotation running.
    var sidePaneDividerMayAct: Bool {
        sidePaneUI.isRequested && duo.layout?.sidePaneDivider != nil && !isEditingAddress && !isShowingGallery
            && presentedViewController == nil && !sidePaneUI.isAnimating && !duo.isResizing
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
            sidePaneUI.takesOver = false
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
        // The swipe toward the edge on the pane: not while the divider is moving it.
        if gestureRecognizer is UISwipeGestureRecognizer {
            return browser?.sidePaneUI.divider?.isActive != true
        }
        return browser?.sidePaneSwipeMayBegin ?? false
    }

    /// A touch on the divider's strip is the divider's, not the pane's swipe toward the edge.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UISwipeGestureRecognizer, let browser, let divider = browser.sidePaneUI.divider else {
            return true
        }
        return !divider.strip.contains(touch.location(in: browser.view))
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
