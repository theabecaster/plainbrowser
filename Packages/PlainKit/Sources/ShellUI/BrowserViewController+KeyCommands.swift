#if canImport(UIKit)
import BrowserCore
import DesignSystem
import GameController
import PerfSignposts
import UIKit
import WebEngine

// MARK: - Keyboard shortcuts and the system's undo

/// What the keys and the system's undo need in one window: one stored property on
/// `BrowserViewController`.
final class GestureUIState {
    /// The system's undo for a hand close ("Undo Close Tab": shake, three-finger swipe, ⌘Z). One
    /// step, the last close, as the Reopen toast (`FixedChoices.undoReopensClosedTab`).
    let closeUndo: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 1
        return manager
    }()
    /// The pinch in on a page that opens the tab overview on wide screens (`+Gestures`).
    var pinch: UIPinchGestureRecognizer?
    var pinchDelegate: PinchToOverview?
    /// The Back and Forward menus as last applied, so a pass changes them only when they change.
    var historyMenus: (back: Bool, forward: Bool) = (false, false)
}

/// The UIKit side of the shortcut table (BrowserCore `KeyShortcut`).
enum ShortcutCommands {
    /// Built once: one listed command per shortcut, the other keys of each hidden from the ⌘
    /// overlay so it reads one line per action.
    static let all: [UIKeyCommand] = KeyShortcut.all.flatMap { shortcut in
        shortcut.keys.enumerated().map { index, key in
            let command = UIKeyCommand(
                title: shortcut.title, action: #selector(BrowserViewController.performShortcut(_:)),
                input: key.input, modifierFlags: key.modifiers.uiKit, propertyList: shortcut.identifier
            )
            command.discoverabilityTitle = shortcut.title
            if index > 0 || !shortcut.isListed { command.attributes = .hidden }
            // A page's own keys (a web app's ⌘L or ⌘F) never shadow the browser's, as in Safari;
            // Escape stays the page's (fullscreen video, a web app's dialog) unless the field is open.
            command.wantsPriorityOverSystemBehavior = shortcut != .dismiss
            return command
        }
    }
}

extension KeyModifiers {
    var uiKit: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.alternate) }
        return flags
    }
}

extension BrowserViewController {
    override public var keyCommands: [UIKeyCommand]? { ShortcutCommands.all }

    /// The browser can hold the keys when nothing else does (`claimKeyFocusIfFree`), so a shortcut
    /// and the system's undo reach it after a tab closes or the field goes away.
    override public var canBecomeFirstResponder: Bool { true }

    /// The system's undo asks the responder chain: the field and a page's form keep their own
    /// (typing is undone there), everything else gets the last tab close.
    override public var undoManager: UndoManager? { gestureUI.closeUndo }

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(performShortcut(_:)) {
            guard let command = sender as? UIKeyCommand, let id = command.propertyList as? String,
                  let shortcut = KeyShortcut(identifier: id) else { return false }
            return allowsShortcut(shortcut)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// The tab list ⌘1 to ⌘9 pick from: the on-screen tab's own list, its page tabs and itself.
    private var shortcutTabList: [TabID] {
        guard let tab = currentTab else { return [] }
        let tabs = session.tabs
        return tabs.entries(private: tab.isPrivate).filter { $0.id == tab.id || !tabs.isEmpty($0.id) }.map(\.id)
    }

    /// The rule for `shortcut` now. A sheet over the browser owns the keys; over the gallery only
    /// opening a tab, the overview key and Escape (back to the page) act.
    func allowsShortcut(_ shortcut: KeyShortcut) -> Bool {
        guard presentedViewController == nil else { return false }
        if isShowingGallery {
            switch shortcut {
            case .newTab, .newPrivateTab, .showAllTabs, .dismiss: return true
            default: return false
            }
        }
        let rules = currentRules()
        // Escape closes the field; the side pane's own close is its button.
        return rules.allows(shortcut, tabsInList: shortcutTabList.count)
    }

    @objc func performShortcut(_ command: UIKeyCommand) {
        guard let id = command.propertyList as? String, let shortcut = KeyShortcut(identifier: id),
              allowsShortcut(shortcut) else { return }
        Signposts.signposter.emitEvent(Signposts.keyShortcut, "\(id, privacy: .public)")
        perform(shortcut)
    }

    /// Does what the control the shortcut stands for does, through the same path.
    func perform(_ shortcut: KeyShortcut) {
        switch shortcut {
        case .newTab:
            // The list on screen, as the bar swipe's New Tab card: ⌘T in a private tab stays private.
            openNewTab(private: currentTab?.isPrivate ?? false)
        case .newPrivateTab:
            openNewTab(private: true)
        case .closeTab:
            guard let tab = currentTab else { return }
            closeTab(tab, offerReopen: true)
        case .reopenClosedTab:
            reopenLastClosed(source: "key")
        case .openLocation:
            if isEditingAddress {
                pill.textField.selectAll(nil)
            } else {
                // The pill's own door, straight to the field even from a collapsed bar.
                expandChrome(animated: false)
                pillTapped()
            }
        case .reload:
            reloadPage()
        case .stop:
            currentTab?.stopLoading()
        case .back:
            goBack()
        case .forward:
            goForward()
        case .find:
            findOnPage()
        case .findNext, .findPrevious:
            let page = engineUI.reader.webView ?? currentTab.flatMap { session.pool.webView(for: $0) }
            if shortcut == .findNext { page?.findInteraction?.findNext() } else { page?.findInteraction?.findPrevious() }
        case .addFavorite:
            guard let url = pageAddress else { return }
            setFavorite(true, url: url, title: currentTab?.title)
            tabsUI.toast.show(String(localized: "Added to Favorites"))
        case .readLater:
            guard let tab = currentTab, let url = pageAddress else { return }
            saveForLater(tab, url: url)
        case .nextTab:
            tabsUI.swipe.switchTab(side: 1)
        case .previousTab:
            tabsUI.swipe.switchTab(side: -1)
        case .selectTab(let number):
            let list = shortcutTabList
            guard let id = number == 9 ? list.last : list[safe: number - 1], id != currentTab?.id else { return }
            sideTabsSelect(id)
        case .showAllTabs:
            if isShowingGallery { tabsButtonTapped() } else { presentGallery(source: "key") }
        case .reader:
            isShowingReader ? closeReader(animated: true) : openReader()
        case .zoomIn:
            currentTab?.zoomIn()
        case .zoomOut:
            currentTab?.zoomOut()
        case .actualSize:
            currentTab?.resetZoom()
        case .history:
            showHistory()
        case .dismiss:
            if isEditingAddress {
                endAddressEditing()
            } else if isShowingGallery {
                tabsButtonTapped()
            }
        }
    }

    // MARK: Key focus

    /// Gives the keys a home when nothing holds them: the page (so Space, the arrows and ⌘↑ ⌘↓
    /// scroll it, which WebKit does itself) while a hardware keyboard is attached, else the
    /// browser (so the system's undo finds the last close). Never takes them from a field, a
    /// page's form or a sheet. Runs on the next turn, after UIKit has settled who has them.
    func claimKeyFocusIfFree() {
        DispatchQueue.main.async { [weak self] in
            guard let self, view.window?.isKeyWindow == true, presentedViewController == nil,
                  !isEditingAddress, KeyFocusProbe.current() == nil else { return }
            if GCKeyboard.coalesced != nil, !isShowingGallery, let tab = currentTab, !session.tabs.isEmpty(tab.id),
               let page = engineUI.reader.webView ?? session.pool.webView(for: tab), page.window != nil,
               page.becomeFirstResponder() {
                return
            }
            becomeFirstResponder()
        }
    }

    // MARK: Undo Close Tab

    /// A hand close that made a batch: the system's undo brings exactly that batch back, as the
    /// Reopen toast does.
    func registerUndoClose(_ batch: UUID) {
        guard FixedChoices.undoReopensClosedTab else { return }
        let undo = gestureUI.closeUndo
        undo.removeAllActions()
        undo.registerUndo(withTarget: self) { browser in
            MainActor.assumeIsolated { browser.undoClose(batch) }
        }
        undo.setActionName(String(localized: "Close Tab"))
        claimKeyFocusIfFree()
    }

    private func undoClose(_ batch: UUID) {
        Signposts.signposter.emitEvent(Signposts.undoCloseTab)
        if isShowingGallery { dismissGalleryFading() }
        guard !session.tabs.reopenClosed(batch).isEmpty, let tab = session.tabs.selected else {
            return Haptic.nothingThere.play()
        }
        tabsUI.toast.hide(animated: true)
        endAddressEditing()
        show(tab)
    }
}

/// Finds the first responder, if any, with an action sent to it (UIKit has no public getter).
@MainActor
enum KeyFocusProbe {
    fileprivate static var found: UIResponder?

    /// The first responder, or nil when nothing holds the keys (a window counts as nothing).
    static func current() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.plainReportKeyFocus(_:)), to: nil, from: nil, for: nil)
        defer { found = nil }
        return found is UIWindow ? nil : found
    }
}

extension UIResponder {
    @objc fileprivate func plainReportKeyFocus(_ sender: Any?) {
        KeyFocusProbe.found = self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
