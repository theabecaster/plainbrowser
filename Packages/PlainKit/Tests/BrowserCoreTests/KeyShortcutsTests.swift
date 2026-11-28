import Foundation
@testable import BrowserCore
import Testing

/// The keyboard shortcuts (docs/research/gestures.md, "Keyboard"): Safari's keys, each acting only
/// where its control would (docs/state-rules.md, principle 3).
@Suite struct KeyShortcutsTests {
    static func page(canGoBack: Bool = false, canGoForward: Bool = false, hasNext: Bool = false, listCount: Int = 1) -> ChromeState {
        var state = ChromeState()
        state.hasTab = true
        state.hasPage = true
        state.isRecordable = true
        state.isWebPage = true
        state.canGoBack = canGoBack
        state.canGoForward = canGoForward
        state.hasNext = hasNext
        state.listCount = listCount
        state.closableInList = listCount
        return state
    }

    @Test func everyKeyIsUniqueAndNamed() {
        var seen = Set<String>()
        for shortcut in KeyShortcut.all {
            #expect(!shortcut.title.isEmpty)
            #expect(KeyShortcut(identifier: shortcut.identifier) == shortcut)
            for key in shortcut.keys {
                let id = "\(key.input)|\(key.modifiers.rawValue)"
                #expect(!seen.contains(id), "\(shortcut) reuses \(key.input)")
                seen.insert(id)
            }
        }
    }

    @Test func safariKeysAreThere() {
        func has(_ shortcut: KeyShortcut, _ input: String, _ modifiers: KeyModifiers) -> Bool {
            shortcut.keys.contains { $0.input == input && $0.modifiers == modifiers }
        }
        #expect(has(.newTab, "t", .command))
        #expect(has(.newPrivateTab, "n", [.command, .shift]))
        #expect(has(.closeTab, "w", .command))
        #expect(has(.reopenClosedTab, "t", [.command, .shift]))
        #expect(has(.openLocation, "l", .command))
        #expect(has(.reload, "r", .command))
        #expect(has(.back, "[", .command))
        #expect(has(.forward, "]", .command))
        #expect(has(.find, "f", .command))
        #expect(has(.findNext, "g", .command))
        #expect(has(.findPrevious, "g", [.command, .shift]))
        #expect(has(.addFavorite, "d", .command))
        #expect(has(.nextTab, "\t", .control))
        #expect(has(.previousTab, "\t", [.control, .shift]))
        #expect(has(.showAllTabs, "\\", [.command, .shift]))
        #expect(has(.selectTab(1), "1", .command))
        #expect(has(.selectTab(9), "9", .command))
        // Only the first key of each line shows in the ⌘ overlay; Escape never.
        #expect(!KeyShortcut.dismiss.isListed)
    }

    @Test func keysFollowTheirControls() {
        let start = ControlRules(ChromeState())
        // Nothing to close, reload or go back to on the start screen; a new tab always.
        #expect(start.allows(.newTab))
        #expect(!start.allows(.closeTab))
        #expect(!start.allows(.reload))
        #expect(!start.allows(.back))
        #expect(!start.allows(.addFavorite))

        let page = ControlRules(Self.page())
        #expect(page.allows(.closeTab))
        #expect(page.allows(.reload))
        #expect(!page.allows(.stop))
        #expect(!page.allows(.back), "Back is dimmed, so ⌘[ does nothing")
        #expect(!page.allows(.forward))
        #expect(page.allows(.find))
        #expect(!page.allows(.findNext), "⌘G only while the find bar is open")
        #expect(page.allows(.addFavorite))
        #expect(!page.allows(.nextTab))
        #expect(page.allows(.showAllTabs), "one page tab: its card, as the swipe up")

        let history = ControlRules(Self.page(canGoBack: true, canGoForward: true, hasNext: true, listCount: 3))
        #expect(history.allows(.back))
        #expect(history.allows(.forward))
        #expect(history.allows(.nextTab))
        #expect(!history.allows(.previousTab))

        var loading = Self.page()
        loading.condition = .loading
        #expect(ControlRules(loading).allows(.stop))
        #expect(!ControlRules(loading).allows(.reload))

        var finding = Self.page()
        finding.isFindOpen = true
        #expect(ControlRules(finding).allows(.findNext))
        #expect(ControlRules(finding).allows(.findPrevious))
    }

    @Test func numberKeysPickFromTheListAndNineIsTheLast() {
        let rules = ControlRules(Self.page(listCount: 3))
        #expect(rules.allows(.selectTab(1), tabsInList: 3))
        #expect(rules.allows(.selectTab(3), tabsInList: 3))
        #expect(!rules.allows(.selectTab(4), tabsInList: 3))
        #expect(rules.allows(.selectTab(9), tabsInList: 3))
        #expect(!rules.allows(.selectTab(9), tabsInList: 0))
    }

    @Test func theFieldKeepsItsKeys() {
        var editing = Self.page()
        editing.isEditing = true
        let rules = ControlRules(editing)
        #expect(rules.allows(.dismiss))
        #expect(rules.allows(.openLocation), "⌘L selects the field's text")
        #expect(rules.allows(.newTab))
        #expect(!rules.allows(.reload))
        #expect(!rules.allows(.back))
        #expect(!rules.allows(.find))
        #expect(!ControlRules(Self.page()).allows(.dismiss), "Escape stays the page's")
    }

    @Test func closeAllTabsNeedsTwoItCanClose() {
        #expect(!ControlRules(Self.page(listCount: 1)).menuCloseAllTabs)
        #expect(ControlRules(Self.page(listCount: 2)).menuCloseAllTabs)
        var pinned = Self.page(listCount: 3)
        pinned.closableInList = 1
        #expect(!ControlRules(pinned).menuCloseAllTabs, "pinned tabs stay, so one closable tab is Close Tab's job")
    }
}
