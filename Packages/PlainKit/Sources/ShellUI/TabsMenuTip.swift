#if canImport(UIKit)
import BrowserCore
import Foundation
import TipKit
import UIKit

/// The one-time hint that the tabs slot has a long-press menu (docs/state-rules.md §3, "Teaching
/// the long press"). Every item in that menu is also in More, so the long press is a shortcut;
/// the tip teaches it once, to someone who already uses the Tabs button, then never again.
struct TabsMenuTip: Tip {
    /// The gallery opened from a tap on the Tabs button.
    static let galleryOpenedByTap = Tips.Event(id: "galleryOpenedByTap")

    var title: Text { Text("Touch and Hold for More") }
    var message: Text? { Text("New private tab, closed tabs and archived tabs are a long press on Tabs away.") }
    var image: Image? { Image(systemName: "hand.tap") }

    var rules: [Rule] {
        [#Rule(Self.galleryOpenedByTap) { $0.donations.count >= 2 }]
    }

    var options: [any TipOption] { [MaxDisplayCount(1)] }

    /// The menu opened: the tip has done its job, or was never needed.
    static func menuOpened() {
        TabsMenuTip().invalidate(reason: .actionPerformed)
    }

    /// Tips stay off under UI tests and perf runs (any `-Plain…` launch argument), where a popover
    /// would cover the buttons the tests tap.
    static var isEnabled: Bool {
        !ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-Plain") }
    }
}

/// Shows `TabsMenuTip` over the tabs slot when TipKit says it should, waiting while the search
/// field, the gallery or a sheet is up.
final class TabsTipPresenter {
    private var task: Task<Void, Never>?
    private var wantsToShow = false
    private weak var popover: UIViewController?

    /// Starts listening, once, after launch.
    func start(in browser: BrowserViewController) {
        guard task == nil, TabsMenuTip.isEnabled else { return }
        try? Tips.configure()
        task = Task { [weak self, weak browser] in
            for await shouldDisplay in TabsMenuTip().shouldDisplayUpdates {
                guard let self, let browser else { return }
                wantsToShow = shouldDisplay
                if shouldDisplay {
                    showIfPossible(in: browser)
                } else {
                    popover?.dismiss(animated: true)
                }
            }
        }
    }

    /// The gallery opened from a tap on Tabs: one step toward the tip.
    func galleryOpenedByTap() {
        guard task != nil else { return }
        Task { await TabsMenuTip.galleryOpenedByTap.donate() }
    }

    /// Call when the screen settles (the gallery or a sheet closed, the buttons changed).
    func showIfPossible(in browser: BrowserViewController) {
        guard wantsToShow, popover == nil, browser.presentedViewController == nil, !browser.isShowingGallery,
              !browser.isEditingAddress, browser.rules.tabsSlot == .tabs, browser.view.window != nil else { return }
        let source: any UIPopoverPresentationControllerSourceItem = browser.usesVerticalBar
            ? (browser.barItems[.tabs] ?? browser.buttonBar.button(.tabs))
            : browser.buttonBar.button(.tabs)
        let controller = TipUIPopoverViewController(TabsMenuTip(), sourceItem: source)
        popover = controller
        browser.present(controller, animated: true)
    }
}
#endif
