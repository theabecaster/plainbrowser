import CoreGraphics
import Testing
@testable import ShellUI

/// The search sheet's open and close as numbers (docs/research/arc-address-expand.md).
@MainActor
struct SearchSheetGeometryTests {
    @Test func sheetTopFollowsArcOnTheDuoOuterScreen() {
        // Arc Search: 127 pt on the 678 pt outer screen.
        #expect(SearchSheetGeometry.sheetTop(height: 678, safeTop: 20) == 127)
    }

    @Test func sheetTopKeepsClearOfTheSafeArea() {
        // A tall safe area wins over the share.
        #expect(SearchSheetGeometry.sheetTop(height: 600, safeTop: 120) == 128)
        // A phone on its side: right under the safe area, so rows fit over the keyboard.
        #expect(SearchSheetGeometry.sheetTop(height: 402, safeTop: 0) == 8)
        #expect(SearchSheetGeometry.sheetTop(height: 440, safeTop: 20) == 28)
    }

    @Test func sheetTopOnPhones() {
        #expect(SearchSheetGeometry.sheetTop(height: 844, safeTop: 47) == 158)
        #expect(SearchSheetGeometry.sheetTop(height: 956, safeTop: 62) == 179)
    }

    @Test func barIsGoneAThirdOfTheWayUp() {
        #expect(SearchSheetGeometry.barAlpha(progress: 0) == 1)
        #expect(SearchSheetGeometry.barAlpha(progress: 0.35) == 0)
        #expect(SearchSheetGeometry.barAlpha(progress: 1) == 0)
        #expect(SearchSheetGeometry.barAlpha(progress: -0.2) == 1)
    }

    @Test func dragFollowsTheFingerAndStopsAtTheEnds() {
        #expect(SearchSheetGeometry.progress(start: 1, translation: 215, travel: 430) == 0.5)
        // A pull up on the open sheet has nowhere to go.
        #expect(SearchSheetGeometry.progress(start: 1, translation: -80, travel: 430) == 1)
        #expect(SearchSheetGeometry.progress(start: 1, translation: 900, travel: 430) == 0)
        // Taken mid-flight, it continues from there.
        #expect(SearchSheetGeometry.progress(start: 0.6, translation: 43, travel: 430) == 0.5)
        // No travel (the field does not move): the drag does nothing.
        #expect(SearchSheetGeometry.progress(start: 1, translation: 100, travel: 0) == 1)
    }

    @Test func releaseCollapsesPastTheThresholdOrOnAFlick() {
        #expect(SearchSheetGeometry.collapses(progress: 0.6, velocity: 0))
        #expect(!SearchSheetGeometry.collapses(progress: 0.9, velocity: 0))
        // A flick down closes from anywhere; a flick up keeps the sheet.
        #expect(SearchSheetGeometry.collapses(progress: 0.97, velocity: 900))
        #expect(!SearchSheetGeometry.collapses(progress: 0.3, velocity: -900))
    }

    @Test func fieldTransformMapsOpenToRest() {
        let open = CGRect(x: 12, y: 143, width: 358, height: 48)
        let rest = CGRect(x: 12, y: 570, width: 304, height: 48)
        let closed = SearchSheetGeometry.transform(open: open, rest: rest, progress: 0)
        let shown = CGRect(x: -open.width / 2, y: -open.height / 2, width: open.width, height: open.height)
            .applying(closed).offsetBy(dx: open.midX, dy: open.midY)
        #expect(abs(shown.minX - rest.minX) < 0.001 && abs(shown.minY - rest.minY) < 0.001)
        #expect(abs(shown.width - rest.width) < 0.001 && abs(shown.height - rest.height) < 0.001)
        #expect(SearchSheetGeometry.transform(open: open, rest: rest, progress: 1) == .identity)
        // Same size (a page on a phone): a pure move.
        let move = SearchSheetGeometry.transform(open: open, rest: open.offsetBy(dx: 0, dy: 400), progress: 0)
        #expect(move.a == 1 && move.d == 1 && move.ty == 400)
    }
}
