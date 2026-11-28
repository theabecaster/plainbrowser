#if canImport(UIKit)
import BrowserCore
import PerfSignposts
import UIKit
import WebEngine

// Settings > Appearance and dark pages: the windows take the setting, the web views follow the
// colors the window shows, and Site Settings offers the per-site Dark Pages item (the rest of
// Dark Pages is in `+DarkPages`).
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

    /// Site Settings' "Dark Pages", checked while Plain darkens the page; a tap is the indicator's
    /// (`toggleDarkPages`). `item` is the state rules' answer (`ControlRules.darkPages`, §4).
    func darkPagesMenuItems(for tab: Tab, item: DarkPagesItem) -> [UIMenuElement] {
        guard item != .hidden else { return [] }
        let action = UIAction(
            title: String(localized: "Dark Pages"), image: UIImage(systemName: "circle.lefthalf.filled"),
            state: item == .on ? .on : .off
        ) { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            self.toggleDarkPages(for: tab, source: "menu")
        }
        action.accessibilityIdentifier = "menu.darkPages"
        return [action]
    }
}
#endif
