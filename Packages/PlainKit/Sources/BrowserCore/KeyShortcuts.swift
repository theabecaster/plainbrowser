import Foundation

// The hardware keyboard's shortcuts (docs/research/gestures.md, "Keyboard"). Safari's keys, so a
// Safari user's hands already know them. Each one acts only where its control would: it asks the
// same `ControlRules` predicate as its button or menu item (docs/state-rules.md, principle 3), so
// a key never does what the screen does not offer. Pure, so the table and its rules test on macOS.

/// The modifier keys of a shortcut, without UIKit (the shell maps them to `UIKeyModifierFlags`).
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let option = KeyModifiers(rawValue: 1 << 3)
}

/// One keyboard shortcut and what it does.
public enum KeyShortcut: Sendable, Hashable {
    case newTab, newPrivateTab, closeTab, reopenClosedTab
    /// ⌘Z after a close: the system's undo, which a web view holding the keys would otherwise
    /// answer with its own (empty) undo.
    case undoCloseTab
    case openLocation, reload, stop
    /// Reload Without Cache: Safari's ⌥⌘R (Chrome's ⇧⌘R is Reader here, as in Safari).
    case reloadFromOrigin
    case back, forward
    case find, findNext, findPrevious
    case addFavorite, readLater
    case nextTab, previousTab
    /// ⌘1 to ⌘8 pick that tab of the list; ⌘9 the last one, as in Safari.
    case selectTab(Int)
    case showAllTabs
    case reader
    case zoomIn, zoomOut, actualSize
    case history
    /// Escape: closes the search field (the field's own key, not listed in the ⌘ overlay).
    case dismiss

    /// Every shortcut, in the order the ⌘ overlay lists them: tabs, the page, then the window.
    public static let all: [KeyShortcut] = [
        .newTab, .newPrivateTab, .closeTab, .reopenClosedTab, .undoCloseTab,
        .nextTab, .previousTab, .showAllTabs,
        .openLocation, .reload, .reloadFromOrigin, .stop, .back, .forward,
        .find, .findNext, .findPrevious,
        .addFavorite, .readLater, .reader,
        .zoomIn, .zoomOut, .actualSize,
        .history,
    ] + (1...9).map { KeyShortcut.selectTab($0) } + [KeyShortcut.dismiss]

    /// The keys: one or more, since Safari takes ⌃Tab and ⌘⇧] alike for the next tab.
    public var keys: [(input: String, modifiers: KeyModifiers)] {
        switch self {
        case .newTab: [("t", .command)]
        case .newPrivateTab: [("n", [.command, .shift])]
        case .closeTab: [("w", .command)]
        case .reopenClosedTab: [("t", [.command, .shift])]
        case .undoCloseTab: [("z", .command)]
        case .openLocation: [("l", .command)]
        case .reload: [("r", .command)]
        case .reloadFromOrigin: [("r", [.command, .option])]
        case .stop: [(".", .command)]
        case .back: [("[", .command)]
        case .forward: [("]", .command)]
        case .find: [("f", .command)]
        case .findNext: [("g", .command)]
        case .findPrevious: [("g", [.command, .shift])]
        case .addFavorite: [("d", .command)]
        case .readLater: [("d", [.command, .shift])]
        case .nextTab: [("\t", .control), ("]", [.command, .shift])]
        case .previousTab: [("\t", [.control, .shift]), ("[", [.command, .shift])]
        case .selectTab(let number): [("\(number)", .command)]
        case .showAllTabs: [("\\", [.command, .shift])]
        case .reader: [("r", [.command, .shift])]
        case .zoomIn: [("+", .command), ("=", .command)]
        case .zoomOut: [("-", .command)]
        case .actualSize: [("0", .command)]
        case .history: [("y", .command)]
        case .dismiss: [(KeyShortcut.escapeInput, [])]
        }
    }

    /// UIKit's `UIKeyCommand.inputEscape`, spelled here so BrowserCore needs no UIKit.
    public static let escapeInput = "UIKeyInputEscape"

    /// The name in the ⌘ overlay: the same words as the menu item it stands for.
    public var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newPrivateTab: "New Private Tab"
        case .closeTab: "Close Tab"
        case .reopenClosedTab: "Reopen Closed Tab"
        case .undoCloseTab: "Undo Close Tab"
        case .openLocation: "Open Location"
        case .reload: "Reload Page"
        case .reloadFromOrigin: "Reload Without Cache"
        case .stop: "Stop Loading"
        case .back: "Back"
        case .forward: "Forward"
        case .find: "Find on Page"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .addFavorite: "Add to Favorites"
        case .readLater: "Read Later"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .selectTab(let number): number == 9 ? "Last Tab" : "Tab \(number)"
        case .showAllTabs: "Show All Tabs"
        case .reader: "Reader"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .history: "History"
        case .dismiss: "Close"
        }
    }

    /// The key that names it, for `UIKeyCommand.propertyList`.
    public var identifier: String {
        switch self {
        case .selectTab(let number): "selectTab\(number)"
        default: "\(self)"
        }
    }

    public init?(identifier: String) {
        guard let match = Self.all.first(where: { $0.identifier == identifier }) else { return nil }
        self = match
    }

    /// Shown in the ⌘ overlay. The other keys of a shortcut (⌘⇧], ⌘=) and Escape work without a
    /// line of their own, so the overlay stays one line per action.
    public var isListed: Bool { self != .dismiss }
}

extension ControlRules {
    /// Whether `shortcut` acts now: the predicate of the control it stands for. A key that has
    /// nothing to do plays the "nothing there" bump in the shell, as a gesture does.
    ///
    /// - Parameter tabsInList: the tabs ⌘1 to ⌘9 pick from (the list on screen).
    public func allows(_ shortcut: KeyShortcut, tabsInList: Int = 0) -> Bool {
        // The search field takes its own keys (⌘L selects, Escape closes); the tab keys still work
        // over it, as in Safari.
        switch shortcut {
        case .newTab: return true
        case .newPrivateTab: return true
        case .closeTab: return menuCloseTab
        case .reopenClosedTab: return menuReopenClosedTab
        // The field undoes its own typing; the shell adds whether a close is there to undo.
        case .undoCloseTab: return !state.isEditing
        case .openLocation: return true
        case .reload: return !state.isEditing && reload == .reload
        case .reloadFromOrigin: return reloadFromOrigin
        case .stop: return !state.isEditing && reload == .stop
        case .back: return !state.isEditing && back.isEnabled
        case .forward: return !state.isEditing && forward.isEnabled
        case .find: return !state.isEditing && findOnPage
        case .findNext, .findPrevious: return state.isFindOpen
        case .addFavorite, .readLater: return !state.isEditing && favorite
        case .nextTab: return state.hasNext
        case .previousTab: return state.hasPrevious
        case .selectTab(let number): return number == 9 ? tabsInList > 0 : number <= tabsInList
        case .showAllTabs: return !state.isEditing && menuShowAllTabs
        case .reader: return !state.isEditing && reader != .hidden
        case .zoomIn, .zoomOut, .actualSize: return !state.isEditing && zoom
        case .history: return !state.isEditing
        case .dismiss: return state.isEditing
        }
    }
}
