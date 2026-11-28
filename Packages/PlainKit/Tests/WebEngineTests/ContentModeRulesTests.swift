import CoreGraphics
import Foundation
import Testing
@testable import WebEngine

/// Desktop or mobile across the fold: the rule alone. Runs on macOS with `swift test` too.
@Suite struct ContentModeRulesTests {
    typealias Rules = ContentModeRules

    @Test func widthPicksTheModeAndASiteChoiceWins() {
        let inner = CGSize(width: 951, height: 669)
        let innerPortrait = CGSize(width: 669, height: 951)
        let outer = CGSize(width: 382, height: 580)
        let splitHalf = CGSize(width: 475, height: 669)
        #expect(Rules.wantedMode(siteChoice: nil, paneSize: inner) == .desktop)
        #expect(Rules.wantedMode(siteChoice: nil, paneSize: innerPortrait) == .desktop)
        #expect(Rules.wantedMode(siteChoice: nil, paneSize: outer) == .mobile)
        #expect(Rules.wantedMode(siteChoice: nil, paneSize: splitHalf) == .mobile)
        #expect(Rules.wantedMode(siteChoice: .mobile, paneSize: inner) == .mobile)
        #expect(Rules.wantedMode(siteChoice: .desktop, paneSize: outer) == .desktop)
    }

    @Test func aPageInTheRightModeIsLeftAlone() {
        var busy = Rules.PageState()
        busy.isPlayingMedia = true
        #expect(Rules.decide(current: .desktop, wanted: .desktop, state: busy) == .none)
        #expect(Rules.decide(current: .mobile, wanted: .mobile, state: Rules.PageState()) == .none)
    }

    @Test func aQuietPageAsksThePageThenReloads() {
        let quiet = Rules.PageState()
        #expect(Rules.decide(current: .mobile, wanted: .desktop, state: quiet) == .askPage)
        #expect(Rules.decide(current: .mobile, wanted: .desktop, state: quiet, report: Rules.PageReport()) == .reload(.desktop))
        #expect(Rules.decide(current: .desktop, wanted: .mobile, state: quiet, report: Rules.PageReport()) == .reload(.mobile))
    }

    @Test func nothingIsLost() {
        func kept(_ change: (inout Rules.PageState) -> Void) -> Rules.Decision {
            var state = Rules.PageState()
            change(&state)
            return Rules.decide(current: .desktop, wanted: .mobile, state: state, report: Rules.PageReport())
        }
        #expect(kept { $0.isWebPage = false } == .keep(.notWebPage))
        #expect(kept { $0.isPDF = true } == .keep(.pdf))
        #expect(kept { $0.isFormResult = true } == .keep(.formResult))
        #expect(kept { $0.isLoading = true } == .keep(.loading))
        #expect(kept { $0.isPlayingMedia = true } == .keep(.media))
        #expect(kept { $0.isInPictureInPicture = true } == .keep(.pictureInPicture))
        #expect(kept { $0.isFullscreen = true } == .keep(.fullscreen))
        #expect(kept { $0.isCapturing = true } == .keep(.capture))
        #expect(kept { $0.isDownloading = true } == .keep(.download))
        #expect(kept { $0.isFindActive = true } == .keep(.find))
        #expect(kept { $0.isTranslated = true } == .keep(.translation))

        let quiet = Rules.PageState()
        #expect(Rules.decide(current: .desktop, wanted: .mobile, state: quiet,
                             report: Rules.PageReport(hasTypedInput: true)) == .keep(.typedInput))
        #expect(Rules.decide(current: .desktop, wanted: .mobile, state: quiet,
                             report: Rules.PageReport(isEditing: true)) == .keep(.editing))
        // A page that can't answer keeps its mode: typed text may be there.
        #expect(Rules.decide(current: .desktop, wanted: .mobile, state: quiet, report: nil) == .keep(.typedInput))
    }

    @Test func debounceKeepsOnlyTheLastChange() {
        var debounce = ContentModeDebounce()
        let fold = debounce.paneDidChange()
        let unfold = debounce.paneDidChange()
        #expect(!debounce.isCurrent(fold))
        #expect(debounce.isCurrent(unfold))
    }
}
