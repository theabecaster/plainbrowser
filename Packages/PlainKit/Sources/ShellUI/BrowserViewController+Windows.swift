#if canImport(UIKit)
import BrowserCore
import DesignSystem
import UIKit
import WebEngine

// MARK: - Windows (Open in New Window, New Window, switching)

/// Each window is a scene with its own tabs and panes in the app's one tab store (`AppTabs`), its
/// own web view pool, and the app's per-site stores. New windows exist where the system allows
/// them: the Duo's inner screen and iPad-size windows (`Windows.canOpenNew`).
extension BrowserViewController {
    /// A new window can open from here now.
    var canOpenNewWindow: Bool { Windows.canOpenNew(in: traitCollection) }

    /// Opens `url` in a new window, in a private tab when `isPrivate`; nil opens the window on
    /// search. A refusal from the system (the outer screen, too many windows) plays the "nothing
    /// there" haptic and says so.
    func openNewWindow(_ url: URL?, isPrivate: Bool) {
        guard canOpenNewWindow else { return Haptic.nothingThere.play() }
        Windows.openNew(url: url, isPrivate: isPrivate) { [weak self] in
            Haptic.nothingThere.play()
            self?.showToastWhenFree { [weak self] in self?.tabsUI.toast.show("A new window can't open here") }
        }
    }

    /// The page a new window was made for, in a tab of its own here (a private one when asked).
    public func openInThisWindow(_ url: URL, isPrivate: Bool) {
        if isShowingGallery { dismissGalleryFading() }
        endAddressEditing()
        let tab: Tab
        if let current = currentTab, current.isPrivate == isPrivate, session.tabs.isEmpty(current.id) {
            tab = current
        } else {
            tab = session.tabs.newTab(isPrivate: isPrivate)
            show(tab)
        }
        tab.load(url)
    }

    /// The tabs menu's window items: New Window where one can open, and the app's other windows,
    /// each by the page it shows, to bring it forward.
    func windowMenuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if canOpenNewWindow {
            let newWindow = UIAction(title: "New Window", image: UIImage(systemName: "macwindow.badge.plus")) { [weak self] _ in
                self?.openNewWindow(nil, isPrivate: false)
            }
            newWindow.accessibilityIdentifier = "menu.newWindow"
            items.append(newWindow)
        }
        let store = session.tabs.store
        for (index, other) in Windows.others(than: session.tabs.windowID).enumerated() {
            let selected = store.selectedTabID(in: other.window).flatMap { store.tabs[$0] }
            let count = store.tabs(in: other.window).count
            let title = selected?.title.flatMap { $0.isEmpty ? nil : $0 }
                ?? selected?.url?.host().map(Self.siteName) ?? String(localized: "Start Page")
            let subtitle = count == 1 ? String(localized: "1 tab") : String(localized: "\(count) tabs")
            let action = UIAction(title: title, subtitle: subtitle, image: UIImage(systemName: "macwindow")) { [weak self] _ in
                Windows.activate(other.session) { [weak self] in
                    Haptic.nothingThere.play()
                    self?.tabsUI.toast.show("That window is gone")
                }
            }
            action.accessibilityIdentifier = "menu.window.\(index)"
            items.append(action)
        }
        return items
    }

    /// The link menu's Open in New Window applies where a new window can open.
    public func canOpenInNewWindow(from tab: Tab) -> Bool { canOpenNewWindow }
}
#endif
