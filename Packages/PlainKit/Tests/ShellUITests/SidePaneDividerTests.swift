import BrowserCore
import CoreGraphics
import DesignSystem
@testable import ShellUI
import TabGalleryUI
import Testing

/// The side pane's divider on the model: which rests fit which screen, the lines that close the
/// pane or hand it the whole width, what a release does at each speed, the haptics on the way, and
/// the layout with a width and with the whole width (docs/research/resizable-pane.md).
@MainActor
struct SidePaneDividerTests {
    static let statusBar: CGFloat = 24
    static let landscape = CGRect(x: 0, y: statusBar, width: 951, height: 669 - statusBar)
    static let portrait = CGRect(x: 0, y: statusBar, width: 669, height: 951 - statusBar)
    static let fold = CGRect(x: 455.5, y: 0, width: 40, height: 669)

    func layout(
        area: CGRect = landscape, width: SidePaneWidth = .narrow, takesOver: Bool = false, tabLayout: TabLayout = .above,
        panes: Int = 1, active: Bool = false
    ) -> DuoLayout {
        DuoLayout(DuoLayoutInput(
            pageArea: area, isRegularWidth: true, isRegularHeight: true, tabLayout: tabLayout, requestedSidebar: .rail,
            paneCount: panes, tabCount: 3, division: Self.fold, isDivisionActive: active, sidePaneOpen: true,
            sidePaneWidth: width, sidePaneTakesOver: takesOver
        ))
    }

    // MARK: Rests

    @Test func innerLandscapeRestsAtNarrowAndHalf() {
        let geometry = SidePaneDividerGeometry(span: 0...951)
        #expect(geometry.rests.map(\.width) == [.narrow, .half], "two thirds would leave the page 317 pt")
        #expect(geometry.rests.map(\.paneWidth) == [285, 476])
        #expect(geometry.closeLine == 125)
        #expect(geometry.takeOverLine == 951 - 187.5)
    }

    @Test func innerPortraitRestsAtNarrowOnly() {
        let geometry = SidePaneDividerGeometry(span: 0...669)
        #expect(geometry.rests.map(\.width) == [.narrow], "half would leave the page 334 pt")
        #expect(geometry.rests[0].paneWidth == 250)
        // Half asked for shows Narrow here, and the request stays for the rotation back.
        #expect(geometry.rest(for: .half).width == .narrow)
        #expect(SidePaneDividerGeometry(span: 0...951).rest(for: .half).width == .half)
    }

    @Test func wideIPadWindowsRestAtAllThree() {
        let geometry = SidePaneDividerGeometry(span: 0...1366)
        #expect(geometry.rests.map(\.width) == [.narrow, .half, .wide])
        #expect(geometry.rests.map(\.paneWidth) == [410, 683, 911])
        // An 11-inch iPad in portrait: Narrow and Half.
        #expect(SidePaneDividerGeometry(span: 0...834).rests.map(\.width) == [.narrow, .half])
        // The narrowest window the pane shows in (640 pt, a rail beside it): Narrow alone.
        #expect(SidePaneDividerGeometry(span: 52...640).rests.map(\.width) == [.narrow])
    }

    @Test func restsKeepClearOfEachOther() {
        // 760 pt: half (380) is only 130 pt past narrow (250, since 30% is 228) and leaves 380.
        let geometry = SidePaneDividerGeometry(span: 0...760)
        #expect(geometry.rests.map(\.width) == [.narrow, .half])
        for pair in zip(geometry.rests, geometry.rests.dropFirst()) {
            #expect(pair.1.paneWidth - pair.0.paneWidth >= CGFloat(FixedChoices.sidePaneSnapSpacing))
        }
    }

    // MARK: Layout

    @Test func theLayoutTakesTheWindowsWidth() {
        let half = layout(width: .half)
        #expect(half.sidePaneColumn == CGRect(x: 475, y: Self.statusBar, width: 476, height: Self.landscape.height))
        #expect(half.paneFrames[0].width == 475)
        #expect(half.chromeLane == 0...475, "the bar stays over the page")
        #expect(half.sidePaneDivider != nil)
        #expect(layout(area: Self.portrait, width: .half).sidePaneColumn?.width == 250, "portrait shows Narrow")
    }

    @Test func takingOverKeepsThePagesFrameOutOfSight() {
        let full = layout(width: .half, takesOver: true)
        #expect(full.sidePaneTakesOver)
        #expect(full.sidePaneColumn == Self.landscape, "the pane has the pages' whole span")
        #expect(full.paneFrames[0].width == 475, "the page keeps its frame for coming back: no relayout")
        #expect(full.sidePaneDockWidth == 476)
        #expect(full.chromeLane == 0...951, "the bar spans the pane")
    }

    @Test func takingOverBesideARail() {
        let full = layout(takesOver: true, tabLayout: .left)
        #expect(full.sidePaneColumn?.minX == SidebarState.rail.width, "the rail stays")
        #expect(full.sidePaneColumn?.maxX == 951)
    }

    @Test func aSplitRestsOnTheSplitLine() {
        let split = layout(width: .narrow, panes: 2)
        #expect(split.sidePaneCoversSecondPane)
        #expect(split.sidePaneDivider?.rests.count == 1)
        #expect(split.sidePaneDivider?.rests.first?.paneWidth == split.paneFrames[1].width)
        let full = layout(panes: 2, active: false)
        #expect(full.sidePaneDividerTakesOverPossible)
        #expect(layout(takesOver: true, panes: 2).sidePaneColumn == Self.landscape)
    }

    @Test func bookPoseHasNoDivider() {
        let book = layout(width: .half, takesOver: true, active: true)
        #expect(book.sidePaneDivider == nil, "the fold divides the page from the pane")
        #expect(!book.sidePaneTakesOver, "and the pane keeps its side of it")
        #expect(book.sidePaneColumn?.minX == Self.fold.maxX)
    }

    // MARK: Releases

    func drag(from width: CGFloat = 285, by travel: CGFloat, span: ClosedRange<CGFloat> = 0...951) -> SidePaneDividerDrag {
        var drag = SidePaneDividerDrag(geometry: SidePaneDividerGeometry(span: span), startWidth: width)
        // In steps, as a finger moves.
        let steps = 20
        for step in 1...steps { _ = drag.move(travel: travel * CGFloat(step) / CGFloat(steps)) }
        return drag
    }

    @Test func aSlowReleaseSettlesOnTheNearestRest() {
        #expect(drag(by: -60).outcome(velocity: 0) == .rest(.narrow), "60 pt wider stays Narrow")
        #expect(drag(by: -130).outcome(velocity: 0) == .rest(.half), "past the middle goes to Half")
        #expect(drag(by: 100).outcome(velocity: 0) == .rest(.narrow), "185 pt wide springs back")
        // The projection carries a slow push a little further.
        #expect(drag(by: -70).outcome(velocity: 300) == .rest(.half))
    }

    @Test func aFlickGoesToTheNextRest() {
        #expect(drag(by: -20).outcome(velocity: 800) == .rest(.half))
        #expect(drag(from: 476, by: 20).outcome(velocity: -800) == .rest(.narrow))
        // From Half outward fast, but not past the last rest: it stays at the last rest...
        #expect(drag(from: 476, by: 0).outcome(velocity: 800) == .rest(.half))
        // ...and past it, it takes the whole width.
        #expect(drag(from: 476, by: -30).outcome(velocity: 800) == .takeOver)
        // From Narrow toward the edge fast: it closes.
        #expect(drag(by: 30).outcome(velocity: -800) == .close)
        #expect(drag(by: 30).outcome(velocity: -550) == .rest(.narrow), "a flick under 600 pt/s only goes to a rest")
    }

    @Test func pastTheLinesLettingGoClosesOrTakesOver() {
        let closing = drag(by: 170)
        #expect(closing.isCloseArmed)
        #expect(closing.outcome(velocity: 0) == .close)
        #expect(closing.outcome(velocity: 900) == .close, "armed, a throw back does not undo it: the latch does")
        let taking = drag(by: -600)
        #expect(taking.isTakeOverArmed)
        #expect(taking.outcome(velocity: 0) == .takeOver)
    }

    @Test func fromTheWholeWidthTheDragGivesThePageBack() {
        let back = drag(from: 951, by: 500)
        #expect(!back.isTakeOverArmed)
        #expect(back.outcome(velocity: 0) == .rest(.half))
        let stays = drag(from: 951, by: 100)
        #expect(stays.isTakeOverArmed, "still past the line")
        #expect(stays.outcome(velocity: 0) == .takeOver)
    }

    // MARK: Haptics

    @Test func ticksAtEachRestAndTheThresholdAtEachLine() {
        var drag = SidePaneDividerDrag(geometry: SidePaneDividerGeometry(span: 0...951), startWidth: 285)
        var played: [Haptic] = []
        for travel in stride(from: 0, through: -700, by: -5) {
            if let haptic = drag.move(travel: CGFloat(travel)) { played.append(haptic) }
        }
        #expect(played == [.selection, .threshold], "a tick passing Half, then the take-over line")
        for travel in stride(from: -700, through: 0, by: 5) {
            if let haptic = drag.move(travel: CGFloat(travel)) { played.append(haptic) }
        }
        #expect(played == [.selection, .threshold, .selection, .selection],
                "back: the line disarms (a tick), then Half; it stops on Narrow without passing it")
        #expect(drag.releaseHaptic(for: .rest(.narrow)) == nil, "settling on a rest is silent")
    }

    @Test func aFingerRestingOnARestNeverChatters() {
        var drag = SidePaneDividerDrag(geometry: SidePaneDividerGeometry(span: 0...951), startWidth: 285)
        var played: [Haptic] = []
        // Hover around Half (476): 191 pt of travel, 2 pt either way.
        for travel in [-189, -191, -193, -190, -192, -189, -193] {
            if let haptic = drag.move(travel: CGFloat(travel)) { played.append(haptic) }
        }
        #expect(played.isEmpty)
        if let haptic = drag.move(travel: -200) { played.append(haptic) }
        #expect(played == [.selection])
    }

    @Test func leavingTheStartingRestIsNotPassingIt() {
        var drag = SidePaneDividerDrag(geometry: SidePaneDividerGeometry(span: 0...951), startWidth: 285)
        var played: [Haptic] = []
        for travel in stride(from: 0, through: 150, by: 5) {
            if let haptic = drag.move(travel: CGFloat(travel)) { played.append(haptic) }
        }
        #expect(played == [], "narrower than Narrow, short of the close line: silent")
        for travel in stride(from: 150, through: -40, by: -5) {
            if let haptic = drag.move(travel: CGFloat(travel)) { played.append(haptic) }
        }
        #expect(played == [.selection], "back over Narrow from the other side: one tick")
    }

    @Test func aFlickThatClosesWithoutArmingTaps() {
        let flick = drag(by: 30)
        #expect(flick.releaseHaptic(for: .close) == .tap)
        #expect(drag(by: 170).releaseHaptic(for: .close) == nil, "the threshold already spoke")
    }

    // MARK: Steps (VoiceOver, keys)

    @Test func stepsGoThroughTheRestsThenTheWholeWidth() {
        let geometry = SidePaneDividerGeometry(span: 0...951)
        let wider = SidePaneDividerStep.step(from: .narrow, takesOver: false, wider: true, geometry: geometry)
        #expect(wider?.width == .half && wider?.takesOver == false)
        let full = SidePaneDividerStep.step(from: .half, takesOver: false, wider: true, geometry: geometry)
        #expect(full?.width == .half && full?.takesOver == true)
        #expect(SidePaneDividerStep.step(from: .half, takesOver: true, wider: true, geometry: geometry) == nil)
        let back = SidePaneDividerStep.step(from: .half, takesOver: true, wider: false, geometry: geometry)
        #expect(back?.width == .half && back?.takesOver == false)
        #expect(SidePaneDividerStep.step(from: .narrow, takesOver: false, wider: false, geometry: geometry) == nil,
                "stepping never closes the pane")
    }
}

extension DuoLayout {
    /// A divider that can hand the pane the whole width.
    fileprivate var sidePaneDividerTakesOverPossible: Bool { sidePaneDivider != nil }
}
