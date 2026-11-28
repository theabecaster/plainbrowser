import Foundation

/// What the focused field means while it opened on a page's address (docs/decisions.md, "The
/// page's address in the field"). The field opens with the address, all selected, and the first
/// change decides: one that replaces the whole address (typing over the selection, a paste over
/// it, dictation, or clearing) is a new query, which opens a new tab; one that changes part of it
/// (the caret was put in the address first) edits this page, which loads in the same tab. Later,
/// a change over the whole text counts as clearing it: a new query again.
public enum AddressFieldIntent: Equatable, Sendable {
    /// The field holds the page's address as it opened. Copy shows inside it; Return loads it
    /// again in the same tab.
    case pageAddress
    /// A new query replaced the address: a submit searches or opens in a new tab.
    case newQuery
    /// Part of the address changed: a submit loads in the same tab.
    case editAddress

    /// The intent after one change to the field's text.
    /// - Parameters:
    ///   - range: the span the change replaced, in UTF-16 units of the text before it.
    ///   - length: the text's length before the change, in UTF-16 units.
    ///   - result: the text after the change.
    ///   - pageAddress: the page's address as the field opened with it.
    public func after(replacing range: Range<Int>, of length: Int, result: String, pageAddress: String) -> Self {
        // Cleared, by the clear button or by deleting everything: what comes next is new.
        if result.isEmpty { return .newQuery }
        // Back to the address exactly (an undo): untouched again, Copy comes back.
        if result == pageAddress { return .pageAddress }
        // Over the whole text (it was all selected: Plain's selection on opening, or the user's
        // later) it is a new query, as clearing it would be.
        if range.lowerBound <= 0, range.upperBound >= length { return .newQuery }
        // Anywhere else the caret was put in the text: the first such change on the address is an
        // edit; a query or an edit stays what it is.
        return self == .pageAddress ? .editAddress : self
    }

    /// Whether a submit opens a new tab (the page stays as it was).
    public var opensNewTab: Bool { self == .newQuery }
}
