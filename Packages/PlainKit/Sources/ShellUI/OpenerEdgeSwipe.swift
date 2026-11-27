#if canImport(UIKit)
import DesignSystem
import PerfSignposts
import UIKit
import WebEngine

/// The edge swipe back on a link-opened tab's first page: it closes the tab and returns to its
/// opener, as the Back button does there, so button and gesture agree (docs/state-rules.md §8,
/// notes). WebKit's own swipe back runs whenever the page has history; this one only when it has
/// none and the tab has an opener, so the two never compete.
final class OpenerEdgeSwipe: NSObject, UIGestureRecognizerDelegate {
    weak var browser: BrowserViewController?
    private let pan = UIScreenEdgePanGestureRecognizer()

    func install(on view: UIView, browser: BrowserViewController) {
        self.browser = browser
        pan.edges = .left
        pan.delegate = self
        pan.addTarget(self, action: #selector(panned(_:)))
        view.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let browser, let tab = browser.currentTab, !browser.isEditingAddress, !browser.isShowingGallery,
              browser.presentedViewController == nil else { return false }
        return browser.returnsToOpener(tab) && !tab.canGoBack && !browser.isShowingReader
    }

    @objc private func panned(_ pan: UIScreenEdgePanGestureRecognizer) {
        guard let browser, let view = pan.view else { return }
        let page = browser.webContainer
        let width = max(page.bounds.width, 1)
        let travel = max(0, pan.translation(in: view).x)
        switch pan.state {
        case .changed:
            page.transform = CGAffineTransform(translationX: travel, y: 0)
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: view).x
            let commits = pan.state == .ended && (travel > width / 3 || velocity > 600)
            guard commits, let tab = browser.currentTab else {
                Motion.animate(Motion.tabSwitch) { page.transform = .identity }
                return
            }
            Signposts.signposter.emitEvent(Signposts.navBack, "closes child tab")
            Motion.animate(Motion.tabSwitch, changes: {
                page.transform = CGAffineTransform(translationX: width, y: 0)
            }, completion: { [weak browser, weak tab] in
                page.transform = .identity
                guard let browser, let tab, tab === browser.currentTab else { return }
                browser.closeTab(tab)
            })
        default:
            break
        }
    }
}
#endif
