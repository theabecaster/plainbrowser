import CoreGraphics
import Foundation

/// When the page on screen changes between desktop and mobile after its pane changed size (a fold,
/// an unfold, a split or the side pane opening), and when it waits for the next navigation
/// instead (docs/decisions.md, "Desktop or mobile across the fold"). Pure, so it tests without a
/// web view.
nonisolated enum ContentModeRules {
    /// The mode a page wants now: the site's remembered choice always wins, otherwise the pane's
    /// size picks (`NavigationRules.contentMode(forPaneSize:)`).
    static func wantedMode(siteChoice: ContentMode?, paneSize: CGSize) -> ContentMode {
        siteChoice ?? NavigationRules.contentMode(forPaneSize: paneSize)
    }

    /// Why a page keeps the mode it has until its next navigation.
    enum KeepReason: String, Sendable, Equatable {
        /// Not an http(s) page (an error page, `about:blank`): there is nothing to switch.
        case notWebPage
        /// A PDF looks the same in both modes.
        case pdf
        /// The page came from a form submission: reloading would send it again.
        case formResult
        /// The page has not finished its own load; it is checked again when it has.
        case loading
        case media
        case pictureInPicture
        case fullscreen
        case capture
        case download
        case find
        case translation
        /// Text typed into a field, a changed choice or checkbox: a reload would lose it.
        case typedInput
        /// A field or an editable area has the keyboard focus.
        case editing
    }

    /// What the page is doing now, from the engine's own state (no page script needed).
    struct PageState: Equatable, Sendable {
        var isWebPage = true
        var isPDF = false
        var isFormResult = false
        var isLoading = false
        var isPlayingMedia = false
        var isInPictureInPicture = false
        var isFullscreen = false
        var isCapturing = false
        var isDownloading = false
        var isFindActive = false
        var isTranslated = false
    }

    /// What the page script says about the page (`ContentModeScripts.probe`).
    struct PageReport: Equatable, Sendable {
        var hasTypedInput = false
        var isEditing = false
    }

    enum Decision: Equatable, Sendable {
        /// The page already has the mode it wants.
        case none
        /// The page keeps its mode for now; its next navigation gets the wanted one.
        case keep(KeepReason)
        /// The page's own state allows a switch; ask the page script before reloading.
        case askPage
        /// Reload in `mode`, holding the page's picture until the new one is painted.
        case reload(ContentMode)
    }

    /// The first step, from the engine's state alone: most folds end here without a page script.
    static func decide(current: ContentMode, wanted: ContentMode, state: PageState) -> Decision {
        guard current != wanted else { return .none }
        if let reason = keepReason(for: state) { return .keep(reason) }
        return .askPage
    }

    /// The second step, once the page script answered. A page that could not answer (a frozen
    /// process, a timeout) keeps its mode: losing typed text is worse than a page in the wrong
    /// mode until the next navigation.
    static func decide(current: ContentMode, wanted: ContentMode, state: PageState, report: PageReport?) -> Decision {
        let first = decide(current: current, wanted: wanted, state: state)
        guard first == .askPage else { return first }
        guard let report else { return .keep(.typedInput) }
        if report.isEditing { return .keep(.editing) }
        if report.hasTypedInput { return .keep(.typedInput) }
        return .reload(wanted)
    }

    private static func keepReason(for state: PageState) -> KeepReason? {
        if !state.isWebPage { return .notWebPage }
        if state.isPDF { return .pdf }
        if state.isFormResult { return .formResult }
        if state.isLoading { return .loading }
        if state.isFullscreen { return .fullscreen }
        if state.isInPictureInPicture { return .pictureInPicture }
        if state.isPlayingMedia { return .media }
        if state.isCapturing { return .capture }
        if state.isDownloading { return .download }
        if state.isFindActive { return .find }
        if state.isTranslated { return .translation }
        return nil
    }
}

/// Coalesces the pane changes of one gesture (a fold, then a quick unfold; a rotation's several
/// layout passes) into one check, `settle` after the last of them. Pure timing, testable with
/// any clock reading.
nonisolated struct ContentModeDebounce: Sendable {
    private(set) var generation = 0

    /// A pane changed: any check scheduled before is void. Returns the generation the new check
    /// must still match when it runs.
    mutating func paneDidChange() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ scheduled: Int) -> Bool {
        scheduled == generation
    }
}
