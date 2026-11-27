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
    /// The panes start at the root view's top under a top bar (the page runs under the status zone
    /// and the floating bar), and under the status bar otherwise (`DuoUIState.panesTop`).
    var panesTopEdge: NSLayoutConstraint!
    /// The strip's distance from the leading and trailing edges, past the status corner where it
    /// starts beside it (`TopChromeGeometry.stripClearance`); empty without a strip.
    var stripClearance: [NSLayoutConstraint] = []
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
        let margin = Spacing.m
        let gap = ChromeGeometry.gap
        top.pillHeight = pill.heightAnchor.constraint(equalToConstant: ChromeGeometry.pillHeight)
        top.toastOverPill = tabsUI.toast.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -Spacing.s)
        top.toastLow = tabsUI.toast.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -Spacing.s)
        top.sheetOverPill = sheet.content.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -Spacing.s)
        top.sheetLow = sheet.content.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -Spacing.s)
        top.pullIndicatorTop = pullIndicator.topAnchor.constraint(equalTo: panes.view.topAnchor, constant: Spacing.s)
        top.panesTopEdge = panes.view.topAnchor.constraint(equalTo: view.topAnchor)

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

    /// The corner the status items keep to, from the safe area and its corner-adaptive guide, or
    /// else the camera they wrap (`StatusCorner`); nil under a full-width status bar. Read before
    /// each layout pass where a top bar may show; never from the device or the screen.
    func readStatusCorner() -> CGRect? {
        guard wantsHorizontalBars else { return nil }
        #if DEBUG
        // Captures on the simulator, whose status bar spans the width: the device's corner.
        if let forced = Self.debugStatusCorner { return forced }
        #endif
        let safe = view.safeAreaInsets
        let adapted = view.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
        // The corner-adaptive guide first; else the camera the status items wrap, where the safe
        // area's top is there to clear it.
        let corner = StatusCorner.rect(
            width: view.bounds.width, safeTop: safe.top, safeLeft: safe.left, safeRight: safe.right,
            adaptedTop: adapted.top, adaptedLeft: adapted.left, adaptedRight: adapted.right
        ) ?? StatusCorner.rect(
            aroundOcclusions: view.reservedRegions(kind: .occlusion, options: .includeInactive).map(\.frame),
            width: view.bounds.width, safeTop: safe.top
        )
        let reading = StatusZoneReading(size: view.bounds.size, safe: safe, adapted: adapted)
        if reading != duo.lastStatusReading {
            duo.lastStatusReading = reading
            logStatusZone(safe: safe, adapted: adapted, corner: corner)
        }
        return corner
    }

    /// The top bar's geometry for the current bounds, safe area and status corner.
    func makeTopGeometry(stripHeight: CGFloat) -> TopChromeGeometry {
        TopChromeGeometry(
            width: view.bounds.width, safeTop: view.safeAreaInsets.top, corner: duo.statusCorner,
            stripHeight: stripHeight
        )
    }

    /// Places the row, the strip and the sidebar for `geometry`, and moves the panes to the root
    /// view's top under a top bar. Constants only, set before the layout pass that uses them.
    func applyTopBarPlacement(_ geometry: TopChromeGeometry?, layout: DuoLayout) {
        let top = duo.top
        let onTop = geometry != nil
        if top.panesTopEdge.isActive != onTop {
            // The outgoing one lets go first, so the two never pin the panes together.
            if onTop {
                duo.panesTop.isActive = false
                top.panesTopEdge.isActive = true
            } else {
                top.panesTopEdge.isActive = false
                duo.panesTop.isActive = true
            }
        }
        guard let geometry else { return }
        Self.set(top.pillTop, geometry.rowTop)
        Self.set(top.barTop, geometry.rowTop)
        Self.set(top.stripTop, geometry.stripTop)
        let clearance = geometry.rowClearance
        for constraint in top.leadingClearance { Self.set(constraint, clearance.leading) }
        for constraint in top.trailingClearance { Self.set(constraint, -clearance.trailing) }
        if top.stripClearance.count == 2 {
            let strip = geometry.stripClearance
            Self.set(top.stripClearance[0], strip.leading)
            Self.set(top.stripClearance[1], -strip.trailing)
        }
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
        // The page's text fades under whichever edge the chrome is on.
        let edge: UIRectEdge = pillOnTop || barOnTop ? .top : .bottom
        for effect in pageEdgeEffects where effect.edge != edge { effect.edge = edge }
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

    /// The page's top inset follows the bar's resting state; the viewport insets span collapsed to
    /// expanded, so CSS `svh`/`lvh` stay put while the bar moves.
    func applyTopBarInsets(_ geometry: TopChromeGeometry, rest: ChromeRest) {
        let obscured = UIEdgeInsets(top: geometry.obscuredInset(rest: rest), left: 0, bottom: pageBottomInset, right: 0)
        let minimum = UIEdgeInsets(top: geometry.hiddenInset, left: 0, bottom: pageBottomInset, right: 0)
        let maximum = UIEdgeInsets(top: geometry.expandedInset, left: 0, bottom: pageBottomInset, right: 0)
        if let tab = currentTab {
            session.pool.setInsets(for: tab, obscured: obscured, minimumViewport: minimum, maximumViewport: maximum)
            setPageTopStart(geometry.expandedInset, for: session.pool.scrollView(for: tab))
            // Nothing of Plain's rests at the bottom; the page and its fixed footers stop above the home indicator.
            session.pool.scrollView(for: tab)?.followObscuredBottom(pageBottomInset)
        }
        engineUI.reader.setInsets(obscured: obscured, minimumViewport: minimum, maximumViewport: maximum)
        setPageTopStart(geometry.expandedInset, for: engineUI.reader.webView?.scrollView)
        engineUI.reader.webView?.scrollView.followObscuredBottom(pageBottomInset)
        duo.top.pullIndicatorTop.constant = geometry.expandedInset + Spacing.s
        for slot in self.panes.slots { slot.setRingTopInset(geometry.expandedInset) }
        // A split's other pane follows a change of the bar's height (the strip coming or going).
        let panes = session.tabs.panes
        for index in shownPanes where index != session.tabs.focusedPane {
            if let id = panes[index], let tab = session.tabs.existingTab(id) { applyOtherPaneTopInsets(to: tab, geometry: geometry) }
        }
    }

    /// The other pane of a split under the top bar: the expanded bar's inset, so a focus switch
    /// never relayouts either page.
    func applyOtherPaneTopInsets(to tab: Tab, geometry: TopChromeGeometry) {
        session.pool.setInsets(
            for: tab,
            obscured: UIEdgeInsets(top: geometry.expandedInset, left: 0, bottom: pageBottomInset, right: 0),
            minimumViewport: UIEdgeInsets(top: geometry.hiddenInset, left: 0, bottom: pageBottomInset, right: 0),
            maximumViewport: UIEdgeInsets(top: geometry.expandedInset, left: 0, bottom: pageBottomInset, right: 0)
        )
        setPageTopStart(geometry.expandedInset, for: session.pool.scrollView(for: tab))
        session.pool.scrollView(for: tab)?.followObscuredBottom(pageBottomInset)
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
