@testable import BrowserCore
import Foundation
import Testing

/// docs/decisions.md, "The page's address in the field": replace or edit, decided at the first change.
@Suite struct AddressFieldIntentTests {
    private let page = "https://example.com/news/today"
    private var length: Int { page.utf16.count }

    @Test func typingOverTheSelectionIsANewQuery() {
        let next = AddressFieldIntent.pageAddress.after(replacing: 0..<length, of: length, result: "w", pageAddress: page)
        #expect(next == .newQuery)
        #expect(next.opensNewTab)
    }

    @Test func pastingOverTheSelectionIsANewQuery() {
        let next = AddressFieldIntent.pageAddress.after(
            replacing: 0..<length, of: length, result: "https://other.org/", pageAddress: page
        )
        #expect(next == .newQuery)
    }

    @Test func clearingIsANewQuery() {
        #expect(AddressFieldIntent.pageAddress.after(replacing: 0..<length, of: length, result: "", pageAddress: page) == .newQuery)
        // Cleared after an edit too: what comes next is new.
        #expect(AddressFieldIntent.editAddress.after(replacing: 0..<5, of: 5, result: "", pageAddress: page) == .newQuery)
    }

    @Test func typingAtTheCaretIsAnEdit() {
        let end = AddressFieldIntent.pageAddress.after(
            replacing: length..<length, of: length, result: page + "s", pageAddress: page
        )
        #expect(end == .editAddress)
        #expect(!end.opensNewTab)
        let middle = AddressFieldIntent.pageAddress.after(
            replacing: 20..<20, of: length, result: "https://example.com/xnews/today", pageAddress: page
        )
        #expect(middle == .editAddress)
    }

    @Test func deletingPartIsAnEdit() {
        let next = AddressFieldIntent.pageAddress.after(
            replacing: (length - 5)..<length, of: length, result: "https://example.com/news/", pageAddress: page
        )
        #expect(next == .editAddress)
    }

    @Test func replacingPartOfASelectionIsAnEdit() {
        // The user selected "news" and typed over it.
        let next = AddressFieldIntent.pageAddress.after(
            replacing: 20..<24, of: length, result: "https://example.com/blog/today", pageAddress: page
        )
        #expect(next == .editAddress)
    }

    @Test func theFirstChangeDecidesForTheRest() {
        var intent = AddressFieldIntent.pageAddress.after(replacing: 0..<length, of: length, result: "e", pageAddress: page)
        // Typing on after a replace stays a new query, even at a caret.
        intent = intent.after(replacing: 1..<1, of: 1, result: "ex", pageAddress: page)
        #expect(intent == .newQuery)
        var edit = AddressFieldIntent.pageAddress.after(
            replacing: length..<length, of: length, result: page + "/", pageAddress: page
        )
        // Typing on at the caret stays an edit.
        edit = edit.after(replacing: 3..<3, of: length + 1, result: "htt" + "x" + page.dropFirst(3) + "/", pageAddress: page)
        #expect(edit == .editAddress)
        // Selecting everything after an edit and typing over it is clearing it: a new query.
        edit = edit.after(replacing: 0..<(length + 2), of: length + 2, result: "x", pageAddress: page)
        #expect(edit == .newQuery)
    }

    @Test func undoBackToTheAddressIsUntouched() {
        #expect(AddressFieldIntent.newQuery.after(replacing: 0..<1, of: 1, result: page, pageAddress: page) == .pageAddress)
        #expect(AddressFieldIntent.editAddress.after(
            replacing: length..<(length + 1), of: length + 1, result: page, pageAddress: page
        ) == .pageAddress)
    }
}
