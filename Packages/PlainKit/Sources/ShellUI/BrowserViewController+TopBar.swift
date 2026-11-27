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
    /// The pill in the row: under the status bar, centered on the lane, as wide as it may be.
    var pill: [NSLayoutConstraint] = []
    /// The pill between the two button capsules (only with the bar in the view).
    var pillBetweenButtons: [NSLayoutConstraint] = []
    /// The buttons spanning the row, their capsules at its ends.
    var bar: [NSLayoutConstraint] = []
    /// The strip's top under the bar.
    var stripTop: NSLayoutConstraint?
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

        let centered = pill.centerXAnchor.constraint(equalTo: lane.centerXAnchor)
        centered.priority = .defaultHigh
        let fill = pill.widthAnchor.constraint(equalTo: lane.widthAnchor)
        fill.priority = .defaultLow
        top.pill = [
            pill.topAnchor.constraint(equalTo: safe.topAnchor, constant: TopChromeGeometry.topGap),
            centered,
            fill,
            pill.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(FixedChoices.topBarPillMaxWidth)),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: lane.leadingAnchor, constant: margin),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: lane.trailingAnchor, constant: -margin),
        ]
        top.pillBetweenButtons = [
            pill.leadingAnchor.constraint(
                greaterThanOrEqualTo: buttonBar.leadingAnchor, constant: ButtonBar.splitLeadingWidth + gap
            ),
            pill.trailingAnchor.constraint(
                lessThanOrEqualTo: buttonBar.trailingAnchor, constant: -(ButtonBar.splitTrailingWidth + gap)
            ),
        ]
        top.bar = [
            buttonBar.topAnchor.constraint(equalTo: safe.topAnchor, constant: TopChromeGeometry.topGap),
            buttonBar.heightAnchor.constraint(equalToConstant: TopChromeGeometry.rowHeight),
            buttonBar.leadingAnchor.constraint(equalTo: lane.leadingAnchor, constant: margin),
            buttonBar.trailingAnchor.constraint(equalTo: lane.trailingAnchor, constant: -margin),
        ]
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
    func applyTopBarInsets(_ geometry: TopChromeGeometry, collapsed: Bool) {
        let obscured = UIEdgeInsets(top: geometry.obscuredInset(collapsed: collapsed), left: 0, bottom: 0, right: 0)
        let minimum = UIEdgeInsets(top: geometry.collapsedInset, left: 0, bottom: 0, right: 0)
        let maximum = UIEdgeInsets(top: geometry.expandedInset, left: 0, bottom: 0, right: 0)
        if let tab = currentTab {
            session.pool.setInsets(for: tab, obscured: obscured, minimumViewport: minimum, maximumViewport: maximum)
            setPageTopStart(geometry.expandedInset, for: session.pool.scrollView(for: tab))
        }
        engineUI.reader.setInsets(obscured: obscured, minimumViewport: minimum, maximumViewport: maximum)
        setPageTopStart(geometry.expandedInset, for: engineUI.reader.webView?.scrollView)
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
            obscured: UIEdgeInsets(top: geometry.expandedInset, left: 0, bottom: 0, right: 0),
            minimumViewport: UIEdgeInsets(top: geometry.collapsedInset, left: 0, bottom: 0, right: 0),
            maximumViewport: UIEdgeInsets(top: geometry.expandedInset, left: 0, bottom: 0, right: 0)
        )
        setPageTopStart(geometry.expandedInset, for: session.pool.scrollView(for: tab))
    }

    /// Where a page's top rests: under the expanded top bar, so its first lines show below it and
    /// slide under it as the page scrolls. `obscuredContentInsets` alone leaves the scroll range
    /// alone, so the top bar sets the scroll view's top inset too. It is the expanded bar's height
    /// whatever the bar's state, so a collapse or expand never moves the page; it changes only with
    /// the layout (an unfold, the strip coming or going), and a page resting at its top stays at
    /// its top. 0 under a bottom pill.
    func setPageTopStart(_ inset: CGFloat, for scrollView: UIScrollView?) {
        guard let scrollView, scrollView.contentInset.top != inset else { return }
        let wasAtTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 0.5
        scrollView.contentInset.top = inset
        scrollView.verticalScrollIndicatorInsets.top = inset
        if wasAtTop { scrollView.contentOffset.y = -scrollView.adjustedContentInset.top }
    }

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
#endif
