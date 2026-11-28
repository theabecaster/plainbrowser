import BrowserCore
import CoreGraphics
import DesignSystem
import Foundation

// The side pane's divider as plain values, free of UIKit so `swift test` checks every rest, line
// and release on macOS (docs/research/resizable-pane.md). The browser feeds it the pages' span
// from `DuoLayout` and the finger's travel, and applies what it returns.

/// The width the side pane rests at in a window (kept with the scene). One width for Reader, Find
/// and History: switching what the pane shows never moves the page.
enum SidePaneWidth: String, CaseIterable, Comparable, Sendable {
    case narrow, half, wide

    /// Its share of the pages' width.
    var fraction: CGFloat {
        switch self {
        case .narrow: CGFloat(FixedChoices.sidePaneFraction)
        case .half: CGFloat(FixedChoices.sidePaneHalfFraction)
        case .wide: CGFloat(FixedChoices.sidePaneWideFraction)
        }
    }

    /// What VoiceOver and the divider's menu call it.
    var title: String {
        switch self {
        case .narrow: String(localized: "Narrow")
        case .half: String(localized: "Half")
        case .wide: String(localized: "Two Thirds")
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Where the divider can rest for one layout: the pages' span, the rests that fit it, and the two
/// lines past which letting go closes the pane or hands it the whole width.
struct SidePaneDividerGeometry: Equatable {
    /// One place the divider rests: the width it stands for and the pane's width there.
    struct Rest: Equatable {
        var width: SidePaneWidth
        var paneWidth: CGFloat
    }

    /// The pages' span (between the sidebar and the window's edge): the pane and the page share it.
    var span: ClosedRange<CGFloat>
    /// The rests that fit, narrowest first. Narrow is always one.
    var rests: [Rest]
    var minimumPane: CGFloat
    var minimumPage: CGFloat

    var width: CGFloat { span.upperBound - span.lowerBound }

    /// The pane at or under this width when the finger lifts: it closes.
    var closeLine: CGFloat { minimumPane * CGFloat(FixedChoices.sidePaneDismissShare) }
    /// The pane at or over this width (the page at or under its share of the minimum): it takes
    /// the whole width.
    var takeOverLine: CGFloat { width - minimumPage * CGFloat(FixedChoices.sidePaneDismissShare) }

    /// The rests for a span of `width` points: Narrow (at least the pane's minimum), then Half and
    /// Two Thirds where each leaves the page its minimum and sits clear of the rest before it.
    init(span: ClosedRange<CGFloat>) {
        self.span = span
        minimumPane = CGFloat(FixedChoices.sidePaneMinimumWidth)
        minimumPage = CGFloat(FixedChoices.sidePanePageMinimumWidth)
        let width = span.upperBound - span.lowerBound
        var rests = [Rest(width: .narrow, paneWidth: max(minimumPane, (width * SidePaneWidth.narrow.fraction).rounded()))]
        for candidate in [SidePaneWidth.half, .wide] {
            let pane = (width * candidate.fraction).rounded()
            guard pane >= minimumPane, width - pane >= minimumPage,
                  pane - (rests.last?.paneWidth ?? 0) >= CGFloat(FixedChoices.sidePaneSnapSpacing) else { continue }
            rests.append(Rest(width: candidate, paneWidth: pane))
        }
        self.rests = rests
    }

    /// One rest only, at `paneWidth` (a split: the pane holds the second pane's place).
    init(span: ClosedRange<CGFloat>, onlyRest paneWidth: CGFloat) {
        self.init(span: span)
        rests = [Rest(width: .narrow, paneWidth: paneWidth)]
    }

    /// The rest a request shows as here: itself where it fits, else the widest that does below it
    /// (Half asked for in the inner screen's portrait shows Narrow, and comes back on rotation).
    func rest(for request: SidePaneWidth) -> Rest {
        rests.last { $0.width <= request } ?? rests[0]
    }

    /// The divider's x for a pane `paneWidth` wide.
    func dividerX(paneWidth: CGFloat) -> CGFloat { span.upperBound - paneWidth }

    /// The pane's width for a divider at `x`, kept inside the span.
    func paneWidth(dividerX x: CGFloat) -> CGFloat {
        min(width, max(0, span.upperBound - x))
    }
}

/// Where the divider goes when the finger lifts.
enum SidePaneDividerOutcome: Equatable {
    case rest(SidePaneWidth)
    case close
    case takeOver

    /// Whether it ends at the edge (the pane closed or full width).
    var isDismissal: Bool { self == .close || self == .takeOver }
}

/// One drag of the divider: the pane's width under the finger, the haptics it calls for on the
/// way (a tick at each rest it passes, the threshold where closing or taking over arms, a tick
/// where either disarms) and where it settles on release (docs/ui-reference.md, "Haptics").
struct SidePaneDividerDrag {
    let geometry: SidePaneDividerGeometry
    /// The pane's width when the finger came down (the full width when it had taken over).
    let startWidth: CGFloat
    private(set) var paneWidth: CGFloat
    /// The finger is past the close line or the take-over line: letting go there does it.
    private var close: ThresholdLatch
    private var takeOver: ThresholdLatch
    /// Which side of each rest the divider is on (-1 narrower, 1 wider), 0 while it sits on the
    /// rest it started from: leaving that rest is not passing it. Changes only past the hysteresis.
    private var sides: [Int]

    init(geometry: SidePaneDividerGeometry, startWidth: CGFloat) {
        self.geometry = geometry
        self.startWidth = startWidth
        paneWidth = startWidth
        let hysteresis = FixedChoices.hapticThresholdHysteresis
        // Both latches take a value that grows toward their outcome.
        close = ThresholdLatch(threshold: -geometry.closeLine, hysteresis: hysteresis)
        takeOver = ThresholdLatch(threshold: geometry.takeOverLine, hysteresis: hysteresis)
        close.sync(-startWidth)
        takeOver.sync(startWidth)
        let tickHysteresis = CGFloat(FixedChoices.sidePaneSnapTickHysteresis)
        sides = geometry.rests.map { rest in
            abs(startWidth - rest.paneWidth) < tickHysteresis ? 0 : (startWidth > rest.paneWidth ? 1 : -1)
        }
    }

    var isCloseArmed: Bool { close.isArmed }
    var isTakeOverArmed: Bool { takeOver.isArmed }

    /// The finger moved the divider by `travel` points (positive toward the trailing edge, which
    /// narrows the pane). Returns the haptic this frame calls for, if any: a line crossed wins over
    /// a rest passed in the same frame, and the 60 ms gate keeps two frames' worth apart anyway.
    mutating func move(travel: CGFloat) -> Haptic? {
        paneWidth = min(geometry.width, max(0, startWidth - travel))
        let lines = close.update(-paneWidth) ?? takeOver.update(paneWidth)
        let tick = updateRests()
        // Past a line the rests are behind the finger: only the line speaks.
        return lines ?? (close.isArmed || takeOver.isArmed ? nil : tick)
    }

    private mutating func updateRests() -> Haptic? {
        let hysteresis = CGFloat(FixedChoices.sidePaneSnapTickHysteresis)
        var passed = false
        for (index, rest) in geometry.rests.enumerated() {
            // Only once clear of the rest, so a finger resting on it never chatters.
            let side = paneWidth >= rest.paneWidth + hysteresis ? 1 : paneWidth <= rest.paneWidth - hysteresis ? -1 : sides[index]
            if side != sides[index] {
                if sides[index] != 0 { passed = true }
                sides[index] = side
            }
        }
        return passed ? .selection : nil
    }

    /// Where the divider settles when the finger lifts moving at `velocity` points per second
    /// (positive widens the pane):
    /// - past a line (armed): closes or takes over;
    /// - a fast release outward beyond the last rest: closes or takes over without the line;
    /// - a flick: the next rest in its direction;
    /// - else the rest nearest where the release would carry it.
    func outcome(velocity: CGFloat) -> SidePaneDividerOutcome {
        if close.isArmed { return .close }
        if takeOver.isArmed { return .takeOver }
        let rests = geometry.rests
        guard let first = rests.first, let last = rests.last else { return .close }
        let dismissFlick = CGFloat(FixedChoices.sidePaneDividerDismissFlick)
        if velocity <= -dismissFlick, paneWidth < first.paneWidth - 0.5 { return .close }
        if velocity >= dismissFlick, paneWidth > last.paneWidth + 0.5 { return .takeOver }
        if abs(velocity) >= CGFloat(FixedChoices.sidePaneDividerFlick) {
            let next = velocity > 0
                ? rests.first { $0.paneWidth > paneWidth + 0.5 } ?? last
                : rests.last { $0.paneWidth < paneWidth - 0.5 } ?? first
            return .rest(next.width)
        }
        let projected = paneWidth + velocity * CGFloat(FixedChoices.sidePaneProjection)
        let nearest = rests.min { abs($0.paneWidth - projected) < abs($1.paneWidth - projected) } ?? first
        return .rest(nearest.width)
    }

    /// The haptic the release plays: nothing when a line was announced while the finger was down
    /// or the divider settles on a rest (the ticks on the way said it); a tap for a flick that
    /// closes or takes over without having armed (rule 3: one haptic per outcome).
    func releaseHaptic(for outcome: SidePaneDividerOutcome) -> Haptic? {
        guard outcome.isDismissal, !close.isArmed, !takeOver.isArmed else { return nil }
        return .tap
    }
}

/// The divider's steps for VoiceOver's adjust and the keyboard: Narrow, the rests that fit, then
/// the whole width. Neither closes the pane (its × and Hide Side Pane do).
enum SidePaneDividerStep {
    /// The state one step wider (`wider`) or narrower than `current` (`takesOver` for the whole
    /// width), nil at the end.
    static func step(
        from current: SidePaneWidth, takesOver: Bool, wider: Bool, geometry: SidePaneDividerGeometry
    ) -> (width: SidePaneWidth, takesOver: Bool)? {
        let shown = geometry.rest(for: current).width
        let widths = geometry.rests.map(\.width)
        guard let index = widths.firstIndex(of: shown) else { return nil }
        if wider {
            if takesOver { return nil }
            return index + 1 < widths.count ? (widths[index + 1], false) : (shown, true)
        }
        if takesOver { return (shown, false) }
        return index > 0 ? (widths[index - 1], false) : nil
    }
}
