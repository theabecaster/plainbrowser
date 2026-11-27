#if canImport(UIKit)
import BrowserCore
import PerfSignposts
import UIKit
import WebEngine

// Settings > Appearance and dark pages: the windows take the setting, the web views follow the
// colors the window shows, and the page menu offers the per-site dark pages switch.
extension BrowserViewController {
    /// Puts the saved Appearance on every window once Settings are read, and after each change.
    func applyAppearance() {
        guard let appearance = data.appearance else { return }
        AppAppearance.apply(appearance)
    }

    /// Keeps the pool's web views on the colors this window shows, so pages off screen (a
    /// background tab, the next tab of a swipe) are already right when they come on screen.
    func observeAppearance() {
        session.pool.interfaceStyle = traitCollection.userInterfaceStyle
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: BrowserViewController, _) in
            controller.session.pool.interfaceStyle = controller.traitCollection.userInterfaceStyle
        }
    }

    /// "Turn Off Dark Pages for This Site" while Plain darkens the page, "Turn On" while the user
    /// has it off here; `item` is the state rules' answer (`ControlRules.darkPages`, §4).
    func darkPagesMenuItems(for tab: Tab, item: DarkPagesItem) -> [UIMenuElement] {
        let off: Bool
        switch item {
        case .turnOff: off = false
        case .turnOn: off = true
        case .hidden: return []
        }
        let item = UIAction(
            title: off ? "Turn On Dark Pages for This Site" : "Turn Off Dark Pages for This Site",
            image: UIImage(systemName: off ? "moon" : "sun.max")
        ) { [weak tab] _ in
            tab?.setDarkPagesOff(!off)
        }
        item.accessibilityIdentifier = "menu.darkPages"
        return [item]
    }
}
#endif
