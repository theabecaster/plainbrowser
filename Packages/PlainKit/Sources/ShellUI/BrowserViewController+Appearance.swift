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

    /// Site Settings' "Page Appearance": the same menu as the control in the pill (Dark, Light,
    /// Off), on every web page (`ControlRules.pageAppearanceMenu`, §4).
    func darkPagesMenuItems(for tab: Tab, shown: Bool) -> [UIMenuElement] {
        guard shown, let menu = pageAppearanceMenu(for: tab, source: "menu") else { return [] }
        menu.accessibilityIdentifier = "menu.pageAppearance"
        return [menu]
    }
}
#endif
