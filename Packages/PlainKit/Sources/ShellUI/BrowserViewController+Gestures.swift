#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit
import WebEngine

// MARK: - Safari's other gestures: history lists, pinch to the overview, Close All, VoiceOver

/// The page's history from a long press on Back or Forward, the tabs button's Close All Tabs, the
/// pinch in to the tab overview on wide screens, and the bar's gestures as VoiceOver actions
/// (docs/research/gestures.md). Each follows the rule of the control it stands for.
extension BrowserViewController {
    /// Called once from `viewDidLoad`, after the buttons are built.
    func installGestures() {
        let delegate = PinchToOverview(browser: self)
        let pinch = UIPinchGestureRecognizer(target: delegate, action: #selector(PinchToOverview.pinched(_:)))
        pinch.delegate = delegate
        // It only watches: WebKit's own pinch zoom gets every touch, as before.
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesEnded = false
        panes.view.addGestureRecognizer(pinch)
        gestureUI.pinch = pinch
        gestureUI.pinchDelegate = delegate
    }

    /// Applies what changed with the rules: the history menus and the bar's VoiceOver actions.
    /// From `updateButtons`; each assignment happens only on a change.
    func updateGestureMenus() {
        updateHistoryMenus()
        updatePillAccessibilityActions()
    }

    // MARK: Back and Forward: the history list

    /// A long press on Back or Forward lists the pages it can reach, as in Safari. Only while the
    /// page has history that way: Back to an opener or out of the reader has no list.
    private func updateHistoryMenus() {
        let tab = currentTab
        let back = tab?.canGoBack == true && rules.back.isEnabled
        let forward = tab?.canGoForward == true && rules.forward.isEnabled
        guard back != gestureUI.historyMenus.back || forward != gestureUI.historyMenus.forward else { return }
        gestureUI.historyMenus = (back, forward)
        for (kind, hasList) in [(PageButton.back, back), (.forward, forward)] {
            let menu = hasList ? historyMenu(forward: kind == .forward) : nil
            buttonBar.button(kind).menu = menu
            barItems[kind]?.menu = menu
        }
    }

    /// Built when it opens, from the tab on screen then: nearest page first, which UIKit puts next
    /// to the finger.
    private func historyMenu(forward: Bool) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self, let tab = currentTab else { return completion([]) }
                Signposts.signposter.emitEvent(Signposts.historyMenu, "\(forward ? "forward" : "back", privacy: .public)")
                completion(tab.historySteps(forward: forward).map { historyAction($0, in: tab) })
            },
        ])
    }

    private func historyAction(_ step: HistoryStep, in tab: Tab) -> UIAction {
        let host = step.url.host().map(Self.siteName)
        let title = step.title.isEmpty ? host ?? step.url.absoluteString : step.title
        let action = UIAction(title: title, subtitle: step.title.isEmpty ? nil : host) { [weak self, weak tab] _ in
            guard let self, let tab, tab === currentTab else { return }
            Signposts.signposter.emitEvent(Signposts.historyJump, "\(step.offset)")
            if isShowingReader { closeReader(animated: false) }
            dropLaunchCover(animated: true)
            tab.go(toHistoryOffset: step.offset)
        }
        action.accessibilityIdentifier = "history.\(step.offset)"
        return action
    }

    // MARK: Close All Tabs from the tabs button

    /// The tabs menu's Close All Tabs: asks first (it closes a lot, docs/ui-reference.md,
    /// "Confirmations"), with the count it closes, as Safari's tabs button and the gallery do.
    func closeAllTabsAction(_ rules: ControlRules) -> UIAction? {
        guard rules.menuCloseAllTabs else { return nil }
        let count = rules.state.closableInList
        let action = UIAction(
            title: String(localized: "Close All \(count) Tabs"), image: UIImage(systemName: "xmark.square"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmCloseAllTabs(count: count)
        }
        action.accessibilityIdentifier = "menu.closeAllTabs"
        return action
    }

    private func confirmCloseAllTabs(count: Int) {
        guard let tab = currentTab, presentedViewController == nil else { return }
        let isPrivate = tab.isPrivate
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let close = UIAlertAction(title: String(localized: "Close All \(count) Tabs"), style: .destructive) { [weak self] _ in
            self?.closeAllTabs(private: isPrivate)
        }
        close.accessibilityIdentifier = "confirm.closeAllTabs"
        sheet.addAction(close)
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            if usesVerticalBar, let item = barItems[.tabs] {
                popover.sourceItem = item
            } else {
                popover.sourceItem = buttonBar.button(.tabs)
            }
        }
        present(sheet, animated: true)
    }

    /// Closes the on-screen tab's list (pinned tabs stay), then shows what is left: a pinned tab,
    /// the regular tabs after the private ones, or the search field. Reopen and the system's undo
    /// bring the batch back.
    private func closeAllTabs(private isPrivate: Bool) {
        let before = session.tabs.lastClosedBatchID
        galleryCloseAll(private: isPrivate, profile: session.tabs.activeProfile)
        if currentTab == nil {
            if isPrivate, let regular = session.tabs.mostRecent(private: false) {
                show(session.tabs.tab(regular))
            } else {
                beginAddressEditing()
            }
        }
        if let batch = session.tabs.lastClosedBatchID, batch != before {
            offerReopen(batch, message: String(localized: "Tabs closed"))
        }
        updateButtons()
    }

    // MARK: Pinch in: the tab overview

    /// A pinch in may open the overview: on a wide screen (the top bar's: the Duo's inner screen,
    /// as Safari on iPad), with the page at its smallest zoom so WebKit's own zoom keeps every
    /// other pinch, and wherever Show All Tabs would open it.
    var pinchMayOpenOverview: Bool {
        guard chromeOnTop, !isEditingAddress, !isShowingGallery, presentedViewController == nil,
              currentRules().menuShowAllTabs, let scroll = pageScrollView else { return false }
        return scroll.zoomScale <= scroll.minimumZoomScale * 1.01
    }

    func pinchOpensOverview() {
        guard pinchMayOpenOverview else { return }
        Signposts.signposter.emitEvent(Signposts.pinchToOverview)
        // The page is back at its size before its card takes its picture.
        if let scroll = pageScrollView { scroll.setZoomScale(scroll.minimumZoomScale, animated: false) }
        presentGallery(source: "pinch")
    }

    // MARK: VoiceOver and Switch Control

    /// The bar's gestures as actions on the pill (swipe for Previous and Next Tab, up for the
    /// overview, past the last tab for New Tab), with the same rules as the gestures.
    private func updatePillAccessibilityActions() {
        let rules = self.rules
        var names: [String] = []
        if rules.acceptsBarGestures, rules.barSwipeSwitchesTabs {
            if rules.state.hasPrevious { names.append("Previous Tab") }
            if rules.state.hasNext { names.append("Next Tab") }
            if rules.offersNewTabCard { names.append("New Tab") }
        }
        if rules.menuShowAllTabs { names.append("Show All Tabs") }
        guard names != (pill.accessibilityCustomActions ?? []).map(\.name) else { return }
        pill.accessibilityCustomActions = names.map { name in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let self else { return false }
                switch name {
                case "Previous Tab": tabsUI.swipe.switchTab(side: -1)
                case "Next Tab": tabsUI.swipe.switchTab(side: 1)
                case "New Tab": openNewTabFromSwipe()
                default: presentGallery(source: "accessibility")
                }
                return true
            }
        }
    }

    /// The two-finger scrub (VoiceOver's Escape) closes the search field or the overview.
    override public func accessibilityPerformEscape() -> Bool {
        if isEditingAddress {
            endAddressEditing()
            return true
        }
        if isShowingGallery {
            tabsButtonTapped()
            return true
        }
        return false
    }
}

/// Watches two fingers on the page for the pinch in to the overview. It never takes touches from
/// WebKit: it recognizes alongside every other gesture and decides only when the fingers lift.
final class PinchToOverview: NSObject, UIGestureRecognizerDelegate {
    private weak var browser: BrowserViewController?

    init(browser: BrowserViewController) {
        self.browser = browser
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        browser?.pinchMayOpenOverview ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
        guard pinch.state == .ended, pinch.scale < CGFloat(FixedChoices.pinchToOverviewScale) else { return }
        browser?.pinchOpensOverview()
    }
}
#endif
