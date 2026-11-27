#if canImport(UIKit)
import BrowserCore
import DesignSystem
import UIKit
import WebEngine

/// The top bar's constraints, made once in `layOut` and switched as a set.
final class TopBarLayout {
    /// 48 pt on the bottom row, `FixedChoices.topBarHeight` in the top bar.
    var pillHeight: NSLayoutConstraint!
    /// The toast just above the pill (bottom row), or low on the page (top bar).
    var toastOverPill: NSLayoutConstraint!
    /// The search sheet's content ends above the pill; with the pill in the top bar (the sheet is
    /// closed then) it rests on the safe area's bottom instead, so the two never conflict.
    var sheetOverPill: NSLayoutConstraint!
    var sheetLow: NSLayoutConstraint!
    var toastLow: NSLayoutConstraint!
    /// The pull indicator's top: under the top bar when it shows.
    var pullIndicatorTop: NSLayoutConstraint!
    /// The pill in the row: on the status row or under the status bar, centered on the lane, as
    /// wide as it may be.
    var pill: [NSLayoutConstraint] = []
    /// The pill between the two button capsules (only with the bar in the view).
    var pillBetweenButtons: [NSLayoutConstraint] = []
    /// The buttons spanning the row, their capsules at its ends.
    var bar: [NSLayoutConstraint] = []
    /// The strip's top under the bar, from the root view's top.
    var stripTop: NSLayoutConstraint?
    /// The row's top, from the root view's top (`TopChromeGeometry.rowTop`).
    var pillTop: NSLayoutConstraint!
    var barTop: NSLayoutConstraint!
    /// The row keeps clear of the status items' corner: its distance from each edge.
    var leadingClearance: [NSLayoutConstraint] = []
    var trailingClearance: [NSLayoutConstraint] = []
    /// The strip's leading and trailing edges from the root view's (`placeStrip`); empty without
    /// a strip.
    var stripEnds: [NSLayoutConstraint] = []
    var isPillOnTop = false
    var isBarOnTop = false
}

// MARK: - The top bar (wide screens)

/// On a wide screen (the Duo's inner screen, both size classes regular) the chrome is a top bar,
/// as Safari has it there: Back and Forward at the row's leading end, the address in the middle,
/// Tabs, Share and More at its trailing end, and the tab strip (Tab Layout: Above, two or more
/// tabs) under it. The system's vertical bar is off there, so the page gets the full width.
/// The bar floats over the page and shrinks to the address while reading. To edit the address the
/// pill still rises above the keyboard with the search sheet, as everywhere else.
extension BrowserViewController {
    /// The top bar holds the chrome now (`DuoLayout.chromeOnTop`).
    var chromeOnTop: Bool { duo.layout?.chromeOnTop ?? false }

    /// Where Plain shows a top bar the system's vertical bar stays off: both size classes regular
    /// is the Duo's inner screen (and iPad-size windows). Safari does the same there. It changes only
    /// with the window's size classes (a fold or unfold), never with the page's state.
    var wantsHorizontalBars: Bool {
        traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular
    }

    /// Makes the top bar's constraints, inactive. Called once from `layOut`.
    func makeTopBarConstraints() {
        let top = duo.top
        let safe = view.safeAreaLayoutGuide
        let lane = duo.chromeLane
        let margin = TopChromeGeometry.edgeMargin
        let gap = ChromeGeometry.gap
        top.pillHeight = pill.heightAnchor.constraint(equalToConstant: ChromeGeometry.pillHeight)
        top.toastOverPill = tabsUI.toast.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -Spacing.s)
        top.toastLow = tabsUI.toast.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -Spacing.s)
        top.sheetOverPill = sheet.content.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -Spacing.s)
        top.sheetLow = sheet.content.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -Spacing.s)
        top.pullIndicatorTop = pullIndicator.topAnchor.constraint(equalTo: panes.view.topAnchor, constant: Spacing.s)

        // As wide as the room between the capsules allows (up to its cap), then as near the
        // lane's center as that leaves it: beside the status corner the row is lopsided, and a
        // centered pill would shrink to a stub.
        let centered = pill.centerXAnchor.constraint(equalTo: lane.centerXAnchor)
        centered.priority = .defaultHigh - 1
        let fill = pill.widthAnchor.constraint(equalTo: lane.widthAnchor)
        fill.priority = .defaultHigh
        // The row's top and its clearance from the status corner are constants set before each
        // layout pass (`applyTopBarPlacement`).
        top.pillTop = pill.topAnchor.constraint(equalTo: view.topAnchor)
        let pillClearLeading = pill.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor)
        let pillClearTrailing = pill.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor)
        top.pill = [
            top.pillTop,
            centered,
            fill,
            pill.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(FixedChoices.topBarPillMaxWidth)),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: lane.leadingAnchor, constant: margin),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: lane.trailingAnchor, constant: -margin),
            pillClearLeading,
            pillClearTrailing,
        ]
        top.pillBetweenButtons = [
            pill.leadingAnchor.constraint(
                greaterThanOrEqualTo: buttonBar.leadingAnchor, constant: ButtonBar.splitLeadingWidth + gap
            ),
            pill.trailingAnchor.constraint(
                lessThanOrEqualTo: buttonBar.trailingAnchor, constant: -(ButtonBar.splitTrailingWidth + gap)
            ),
        ]
        // The capsules sit at the lane's ends unless the status corner is in the way; then the
        // one on its side stops short of it.
        let barLeading = buttonBar.leadingAnchor.constraint(equalTo: lane.leadingAnchor, constant: margin)
        barLeading.priority = .defaultHigh
        let barTrailing = buttonBar.trailingAnchor.constraint(equalTo: lane.trailingAnchor, constant: -margin)
        barTrailing.priority = .defaultHigh
        let barClearLeading = buttonBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor)
        let barClearTrailing = buttonBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor)
        top.barTop = buttonBar.topAnchor.constraint(equalTo: view.topAnchor)
        top.bar = [
            top.barTop,
            buttonBar.heightAnchor.constraint(equalToConstant: TopChromeGeometry.rowHeight),
            barLeading,
            barTrailing,
            buttonBar.leadingAnchor.constraint(greaterThanOrEqualTo: lane.leadingAnchor, constant: margin),
            buttonBar.trailingAnchor.constraint(lessThanOrEqualTo: lane.trailingAnchor, constant: -margin),
            barClearLeading,
            barClearTrailing,
        ]
        top.leadingClearance = [pillClearLeading, barClearLeading]
        top.trailingClearance = [pillClearTrailing, barClearTrailing]
    }

    // MARK: The status zone

    /// The corner the status items keep to, from the safe area and its corner-adaptive guide and
    /// the camera they wrap (`StatusCorner.read`); nil under a full-width status bar. Read before
    /// each layout pass where a top bar may show; never from the device or the screen.
    func readStatusCorner() -> CGRect? {
        guard wantsHorizontalBars else { return nil }
        #if DEBUG
        // Captures on the simulator, whose status bar spans the width: the device's corner.
        if let forced = Self.debugStatusCorner {
            duo.statusCornerSource = "forced"
            return forced
        }
        #endif
        let safe = view.safeAreaInsets
        let adapted = view.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
        let found = StatusCorner.read(
            width: view.bounds.width, safeTop: safe.top, safeLeft: safe.left, safeRight: safe.right,
            adaptedTop: adapted.top, adaptedLeft: adapted.left, adaptedRight: adapted.right,
            occlusions: view.reservedRegions(kind: .occlusion, options: .includeInactive).map(\.frame)
        )
        duo.statusCornerSource = found?.source.rawValue ?? "none"
        let reading = StatusZoneReading(size: view.bounds.size, safe: safe, adapted: adapted)
        if reading != duo.lastStatusReading {
            duo.lastStatusReading = reading
            logStatusZone(safe: safe, adapted: adapted, corner: found?.rect)
        }
        return found?.rect
    }

    /// The top bar's geometry for the current bounds, safe area and status corner.
    func makeTopGeometry(stripHeight: CGFloat) -> TopChromeGeometry {
        TopChromeGeometry(
            width: view.bounds.width, safeTop: view.safeAreaInsets.top, corner: duo.statusCorner,
            stripHeight: stripHeight
        )
    }

    /// Places the row, the strip and the sidebar for `geometry`. Constants only, set before the
    /// layout pass that uses them.
    func applyTopBarPlacement(_ geometry: TopChromeGeometry?, layout: DuoLayout) {
        let top = duo.top
        placeSidebarRows(geometry, layout: layout)
        guard let geometry else { return }
        Self.set(top.pillTop, geometry.rowTop)
        Self.set(top.barTop, geometry.rowTop)
        Self.set(top.stripTop, geometry.stripTop)
        let clearance = geometry.rowClearance
        for constraint in top.leadingClearance { Self.set(constraint, clearance.leading) }
        for constraint in top.trailingClearance { Self.set(constraint, -clearance.trailing) }
    }

    /// The rail's first row sits on the top bar's row where the status zone beside it is empty
    /// (the status items keep to the other corner); else its rows start under the safe area.
    func placeSidebarRows(_ geometry: TopChromeGeometry?, layout: DuoLayout) {
        guard let sidebar = duo.sidebar else { return }
        var center: CGFloat?
        if let geometry, let corner = geometry.corner {
            let cornerOnTrailing = corner.midX > geometry.width / 2
            if cornerOnTrailing != layout.sidebarOnRight { center = geometry.rowTop + TopChromeGeometry.rowHeight / 2 }
        }
        sidebar.setFirstRowCenter(center)
    }

    private static func set(_ constraint: NSLayoutConstraint?, _ constant: CGFloat) {
        guard let constraint, constraint.constant != constant else { return }
        constraint.constant = constant
    }

    #if DEBUG
    /// `-PlainStatusCorner x,y,width,height` (Debug builds): a status corner for the simulator,
    /// whose status bar spans the width.
    static let debugStatusCorner: CGRect? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-PlainStatusCorner"), index + 1 < arguments.count else { return nil }
        let values = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }()
    #endif

    /// Logs the safe area, both corner-adaptive guides and the occlusion regions (none of them
    /// private) when the bounds or the guides change, so the device's numbers can be read back
    /// from the console (`duo` category). Not per layout pass.
    private func logStatusZone(safe: UIEdgeInsets, adapted: UIEdgeInsets, corner: CGRect?) {
        let vertical = view.edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
        let margins = view.edgeInsets(for: .margins(cornerAdaptation: .horizontal))
        let occlusions = view.reservedRegions(kind: .occlusion, options: .includeInactive).map(\.frame)
        DuoUIState.logger.debug("""
            status zone: bounds \(String(describing: self.view.bounds.size), privacy: .public) \
            safe \(String(describing: safe), privacy: .public) horizontal \(String(describing: adapted), privacy: .public) \
            vertical \(String(describing: vertical), privacy: .public) margins \(String(describing: margins), privacy: .public) \
            occlusions \(String(describing: occlusions), privacy: .public) corner \(String(describing: corner), privacy: .public)
            """)
    }

    /// Logs where the top bar's pieces ended up (`duo` category, notice level, so it is kept on the
    /// device): the status corner and what it was read from, the row, and the laid-out frames of
    /// the Back/Forward and Tabs/Share/More capsules (their glass, the button bar's ends), the
    /// address pill and the strip, untransformed, with how far the trailing capsule ends before
    /// the corner. Called after a layout pass that changed the geometry (a rotation, a fold, the
    /// strip coming or going), never per frame.
    func logTopChrome(_ geometry: TopChromeGeometry) {
        func frame(_ view: UIView?) -> String {
            guard let view, view.superview != nil else { return "none" }
            let rect = CGRect(
                x: view.center.x - view.bounds.width / 2, y: view.center.y - view.bounds.height / 2,
                width: view.bounds.width, height: view.bounds.height
            )
            return String(format: "%.1f,%.1f %.1fx%.1f", rect.minX, rect.minY, rect.width, rect.height)
        }
        let bar = frame(buttonBar)
        let leading = buttonBar.center.x - buttonBar.bounds.width / 2
        let trailing = leading + buttonBar.bounds.width
        let toCorner = geometry.corner.map { String(format: "%.1f", $0.minX - trailing) } ?? "-"
        DuoUIState.logger.notice("""
            top chrome: width \(geometry.width, format: .fixed(precision: 1)) safeTop \(geometry.safeTop, format: .fixed(precision: 1)) \
            corner \(String(describing: geometry.corner), privacy: .public) from \(self.duo.statusCornerSource, privacy: .public) \
            row \(geometry.rowTop, format: .fixed(precision: 1))-\(geometry.rowBottom, format: .fixed(precision: 1)) \
            buttons \(bar, privacy: .public) (capsules \(leading, format: .fixed(precision: 1))…\(trailing, format: .fixed(precision: 1)), \
            \(toCorner, privacy: .public) pt before the corner) pill \(frame(self.pill), privacy: .public) \
            strip \(frame(self.duo.strip?.view), privacy: .public) stripTop \(geometry.stripTop, format: .fixed(precision: 1)) \
            pageTop \(geometry.expandedInset, format: .fixed(precision: 1))
            """)
    }

    /// Puts the pill and the buttons in the top bar, or gives them back to the bottom row. The
    /// caller (`updatePillRestConstraint`) owns the bottom row's constraints.
    func setTopBarConstraints(pill pillOnTop: Bool, bar barOnTop: Bool) {
        let top = duo.top
        if top.isPillOnTop != pillOnTop {
            top.isPillOnTop = pillOnTop
            if pillOnTop {
                NSLayoutConstraint.deactivate([top.toastOverPill, top.sheetOverPill])
                NSLayoutConstraint.activate(top.pill + [top.toastLow, top.sheetLow])
            } else {
                NSLayoutConstraint.deactivate(top.pill + [top.toastLow, top.sheetLow])
                NSLayoutConstraint.activate([top.toastOverPill, top.sheetOverPill])
            }
            top.pillHeight.constant = pillOnTop ? TopChromeGeometry.rowHeight : ChromeGeometry.pillHeight
        }
        if top.isBarOnTop != barOnTop {
            top.isBarOnTop = barOnTop
            barOnTop ? NSLayoutConstraint.activate(top.bar) : NSLayoutConstraint.deactivate(top.bar)
        }
        let between = pillOnTop && barOnTop
        if top.pillBetweenButtons.first?.isActive != between {
            between ? NSLayoutConstraint.activate(top.pillBetweenButtons) : NSLayoutConstraint.deactivate(top.pillBetweenButtons)
        }
    }

    /// The layout switched between the top bar and the bottom row (a fold, an unfold, a rotation
    /// into or out of a wide window): the system's vertical bar, the buttons and the pill follow.
    func topBarModeDidChange() {
        setNeedsUpdateOfVerticalBarConfiguration()
        updatePillRestConstraint()
        // Forward dims instead of hiding in the top bar's fixed slots.
        updateButtons()
        // The geometry stays until the next layout pass compares it (`viewDidLayoutSubviews`),
        // which then places the chrome for the new mode. The buttons' rise is the top bar's alone.
        if !chromeOnTop {
            buttonBar.transform = .identity
        }
    }

    // MARK: Collapse and insets

    /// Places the top bar for collapse `progress` with transform and alpha only: the pill shrinks
    /// up under the status bar, the buttons and the strip rise and fade.
    func applyTopBarCollapse(_ progress: CGFloat, geometry: TopChromeGeometry) {
        let editing = isEditingAddress
        if editing {
            // The pill is above the keyboard: only the bar's buttons stay hidden at the top.
            pill.transform = .identity
            pill.isCompact = false
        } else {
            let move = geometry.pillTransform(progress: progress)
            pill.transform = CGAffineTransform(translationX: 0, y: move.translationY).scaledBy(x: move.scale, y: move.scale)
            pill.isCompact = progress > 0
        }
        // Reading on, the tucked address rises off the top edge as its text fades (docs/state-rules.md,
        // "Chrome while reading"); the top bar is clear of the home-indicator zone, so it may go.
        pill.alpha = editing ? 1 : ChromeGeometry.pillAlpha(progress: progress)
        let isGone = !editing && progress >= ChromeRest.hidden.progress
        if pill.accessibilityElementsHidden != isGone { pill.accessibilityElementsHidden = isGone }
        let alpha = ChromeGeometry.barAlpha(progress: progress)
        buttonBar.transform = CGAffineTransform(translationX: 0, y: geometry.buttonsTranslation(progress: progress))
        if !editing { buttonBar.alpha = alpha }
        if let strip = duo.strip?.view {
            strip.transform = CGAffineTransform(translationX: 0, y: geometry.stripTranslation(progress: progress))
            strip.alpha = alpha
            // A hidden strip takes no taps meant for the page under it.
            strip.isUserInteractionEnabled = alpha > 0.5
        }
    }

    /// The page's insets under the top bar. They never follow the bar's resting state: the
    /// obscured top is the status items' strip in every state (`TopChromeGeometry.obscuredInset`),
    /// so a collapse or a reveal changes nothing in the page and nothing in it can jump. The
    /// viewport insets span that to the expanded bar, so CSS `svh`/`lvh` stay put. They change
    /// only with the layout (a fold, a rotation, the strip coming or going).
    func applyTopBarInsets(_ geometry: TopChromeGeometry) {
        if let tab = currentTab { applyTopBarInsets(geometry, to: tab) }
        let insets = topBarInsets(geometry)
        engineUI.reader.setInsets(obscured: insets.obscured, minimumViewport: insets.minimum, maximumViewport: insets.maximum)
        setPageTopStart(geometry.expandedInset, for: engineUI.reader.webView?.scrollView)
        engineUI.reader.webView?.scrollView.showStatusEdgeEffect(false)
        engineUI.reader.webView?.scrollView.followObscuredBottom(pageBottomInset)
        duo.top.pullIndicatorTop.constant = geometry.expandedInset + Spacing.s
        for slot in self.panes.slots { slot.setRingTopInset(geometry.expandedInset) }
        // A split's other pane follows a change of the bar's height (the strip coming or going).
        let panes = session.tabs.panes
        for index in shownPanes where index != session.tabs.focusedPane {
            if let id = panes[index], let tab = session.tabs.existingTab(id) {
                applyTopBarInsets(geometry, to: tab)
            }
        }
    }

    /// `tab`'s page insets under the top bar, the focused page's or a split's other pane's: the one
    /// bar spans both panes, so both get the same, and a focus switch relayouts neither.
    func applyTopBarInsets(_ geometry: TopChromeGeometry, to tab: Tab) {
        let insets = topBarInsets(geometry)
        session.pool.setInsets(for: tab, obscured: insets.obscured, minimumViewport: insets.minimum, maximumViewport: insets.maximum)
        let scrollView = session.pool.scrollView(for: tab)
        setPageTopStart(geometry.expandedInset, for: scrollView)
        scrollView?.showStatusEdgeEffect(false)
        // Nothing of Plain's rests at the bottom; the page and its fixed footers stop above the home indicator.
        scrollView?.followObscuredBottom(pageBottomInset)
    }

    private func topBarInsets(_ geometry: TopChromeGeometry) -> (obscured: UIEdgeInsets, minimum: UIEdgeInsets, maximum: UIEdgeInsets) {
        (UIEdgeInsets(top: geometry.obscuredInset, left: 0, bottom: pageBottomInset, right: 0),
         UIEdgeInsets(top: geometry.obscuredInset, left: 0, bottom: pageBottomInset, right: 0),
         UIEdgeInsets(top: geometry.expandedInset, left: 0, bottom: pageBottomInset, right: 0))
    }

    /// Where a page's top rests: under the expanded top bar, so its first lines show below it and
    /// slide under it as the page scrolls. `obscuredContentInsets` alone leaves the scroll range
    /// alone, so the top bar sets the scroll view's top inset too. It is the expanded bar's height
    /// whatever the bar's state, so a collapse or expand never moves the page; it changes only with
    /// the layout (an unfold, the strip coming or going), and a page resting at its top stays at
    /// its top. 0 under a bottom pill.
    ///
    /// Under a top bar the page runs to the root view's top, through the status zone, so the
    /// scroll view leaves the safe area out of its insets (it would push the page under the whole
    /// zone, 81 pt on the Duo's inner screen, below the row that sits in it): the inset is
    /// measured from the top edge, and the bottom follows `pageBottomInset`.
    func setPageTopStart(_ inset: CGFloat, for scrollView: UIScrollView?) {
        guard let scrollView else { return }
        let behavior: UIScrollView.ContentInsetAdjustmentBehavior = inset > 0 ? .never : .automatic
        guard scrollView.contentInset.top != inset || scrollView.contentInsetAdjustmentBehavior != behavior else { return }
        let wasAtTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 0.5
        scrollView.contentInsetAdjustmentBehavior = behavior
        scrollView.contentInset.top = inset
        scrollView.verticalScrollIndicatorInsets.top = inset
        if wasAtTop { scrollView.contentOffset.y = -scrollView.adjustedContentInset.top }
    }

    /// Under a top bar nothing of Plain's rests at the bottom: the page's end stops above the home
    /// indicator (the scroll view leaves the safe area out, `setPageTopStart`).
    var pageBottomInset: CGFloat { view.safeAreaInsets.bottom }

    // MARK: The strip's tab count

    /// The strip shows from the second tab: the layout reads the count kept here, updated when the
    /// tabs change rather than on every layout pass.
    func updatePageTabCount() {
        let count = session.tabs.otherTabCount(besides: nil)
        guard count != duo.pageTabCount else { return }
        let crossed = (count > 1) != (duo.pageTabCount > 1)
        duo.pageTabCount = count
        guard crossed, duo.layout?.tabLayout == .above, view.window != nil else { return }
        view.setNeedsLayout()
        Motion.animate(Motion.quick) { self.view.layoutIfNeeded() }
    }
}

/// What the status corner was last read from, to log only changes.
struct StatusZoneReading: Equatable {
    var size: CGSize
    var safe: UIEdgeInsets
    var adapted: UIEdgeInsets
}
#endif
