import CoreGraphics
import Foundation

// The shell's chrome rules as plain values, free of UIKit so `swift test` checks them on macOS.
// The view controller feeds them view geometry and scroll offsets and applies what they return.

/// The bar's three resting states (docs/state-rules.md, "Chrome while reading").
///
/// As a collapse progress: 0 expanded, 1 the pill, 2 hidden. Between expanded and the pill the bar
/// follows the finger 1:1; from the pill to hidden, and back, it springs.
enum ChromeRest: Equatable {
    /// The pill and the button bar (or the pill alone beside a vertical bar).
    case expanded
    /// The small pill low in the home-indicator zone. Taps only.
    case pill
    /// Nothing on screen: the page has the screen. A tap on the bottom edge brings the bar back.
    case hidden

    var progress: CGFloat {
        switch self {
        case .expanded: 0
        case .pill: 1
        case .hidden: 2
        }
    }

    /// The rest a snap to `progress` ends in.
    init(progress: CGFloat) {
        self = progress >= 2 ? .hidden : progress >= 1 ? .pill : .expanded
    }
}

/// Where the bottom chrome sits, expanded and collapsed, in the root view's coordinates.
///
/// The page never relayouts while the toolbar moves (docs/plan.md, engine rule 4): the bar moves by
/// transform and alpha, and the web view's bottom `obscuredContentInsets` follows the bar's resting
/// state, changed once when a snap ends (`PageInsetState`). `setMinimumViewportInset` gets the
/// hidden and expanded sizes, so CSS `svh`/`lvh` stay stable while the bar moves.
struct ChromeGeometry: Equatable {
    /// The root view's height.
    var viewHeight: CGFloat
    /// The root view's bottom safe-area inset (home indicator), without the keyboard.
    var safeBottom: CGFloat
    /// Whether the bottom button bar shows under the pill (iPhones without a vertical bar).
    var hasButtonBar: Bool

    static let pillHeight: CGFloat = 48
    static let barHeight: CGFloat = 48
    /// Between the pill and the button bar.
    static let gap: CGFloat = 6
    /// How close the pill and bar glass come before they merge: under `gap`, so at rest they stay
    /// two shapes and only flow together while they pass each other in a collapse.
    static let glassMergeSpacing: CGFloat = 4
    /// Above the bottom edge when there is no home indicator (iPhone SE).
    static let edgeMargin: CGFloat = 8
    /// The collapsed pill's size relative to the expanded one.
    static let compactScale: CGFloat = 0.75
    /// How far above the bottom edge the collapsed pill ends on a phone with a home indicator.
    /// It sits clear above the indicator, which is about 13 pt from the edge.
    static let collapsedLiftOverIndicator: CGFloat = 18
    /// The shortest bottom-edge strip that brings a hidden bar back, where there is no home
    /// indicator (iPhone SE). With one, the strip is the home-indicator zone itself.
    static let revealEdgeMinimum: CGFloat = 16
    /// How far past the bottom edge the hidden pill's top ends: the spring's slow tail then runs
    /// off screen, and no sliver of glass lingers at the edge (glass ignores the fade).
    static let hiddenClearance: CGFloat = 12

    /// The bottom of the resting chrome: the button bar's bottom, or the pill's.
    var restBottom: CGFloat {
        viewHeight - max(safeBottom, Self.edgeMargin)
    }

    /// The bottom of the expanded, resting pill.
    var pillRestBottom: CGFloat {
        hasButtonBar ? restBottom - Self.barHeight - Self.gap : restBottom
    }

    /// The top of the expanded chrome (the pill's top).
    var expandedTop: CGFloat { pillRestBottom - Self.pillHeight }

    /// The bottom of the collapsed pill: low in the home-indicator zone, like Safari's compact bar.
    var collapsedBottom: CGFloat {
        safeBottom > 0 ? viewHeight - Self.collapsedLiftOverIndicator : restBottom
    }

    /// The top of the collapsed pill.
    var collapsedTop: CGFloat { collapsedBottom - Self.pillHeight * Self.compactScale }

    /// The top of the strip a hidden bar leaves along the bottom edge: the home-indicator zone,
    /// where a tap brings the bar back. The page scrolls under it, and the page's inset covers
    /// only it, so a fixed footer rests just above the indicator.
    var hiddenTop: CGFloat { viewHeight - max(safeBottom, Self.revealEdgeMinimum) }

    /// The pill's vertical translation and scale at collapse `progress` (0 expanded, 1 the pill,
    /// 2 hidden), for a transform about its center. Past 1 it sinks below the bottom edge.
    func pillTransform(progress: CGFloat) -> (translationY: CGFloat, scale: CGFloat) {
        let p = min(max(progress, 0), 1)
        let scale = 1 - (1 - Self.compactScale) * p
        let bottom = pillRestBottom + (collapsedBottom - pillRestBottom) * p
        let restCenter = pillRestBottom - Self.pillHeight / 2
        let sink = (viewHeight - collapsedTop + Self.hiddenClearance) * min(max(progress - 1, 0), 1)
        return (bottom - Self.pillHeight * scale / 2 - restCenter + sink, scale)
    }

    /// The pill's opacity: whole down to the pill, then fading as it sinks away.
    static func pillAlpha(progress: CGFloat) -> CGFloat {
        1 - min(max(progress - 1, 0), 1)
    }

    /// The button bar's drop at `progress`: it leaves past the bottom edge.
    func barTranslation(progress: CGFloat) -> CGFloat {
        let p = min(max(progress, 0), 1)
        return (viewHeight - restBottom + Self.barHeight) * p
    }

    /// The bar's opacity at `progress`: gone by 60% of the way, so it never covers the pill.
    static func barAlpha(progress: CGFloat) -> CGFloat {
        max(0, 1 - progress / 0.6)
    }

    /// The hidden chrome's height over the page: the edge strip only. The smallest bottom inset
    /// the page sees.
    func hiddenInset(pageBottom: CGFloat) -> CGFloat {
        max(0, min(pageBottom - hiddenTop, collapsedInset(pageBottom: pageBottom)))
    }

    /// The collapsed pill's height over the page, measured up from `pageBottom` (the web view's
    /// bottom in the same coordinates).
    func collapsedInset(pageBottom: CGFloat) -> CGFloat {
        max(0, pageBottom - collapsedTop)
    }

    /// The expanded chrome's height over the page: the largest bottom inset the page sees, never
    /// equal to the collapsed one (WebKit wants the maximum viewport inset strictly larger).
    func expandedInset(pageBottom: CGFloat) -> CGFloat {
        max(pageBottom - expandedTop, collapsedInset(pageBottom: pageBottom) + 1)
    }

    /// The page's obscured bottom inset for the bar resting at `rest`, so the resting bar never
    /// covers fixed page footers or the page's last lines.
    func obscuredInset(pageBottom: CGFloat, rest: ChromeRest) -> CGFloat {
        switch rest {
        case .expanded: expandedInset(pageBottom: pageBottom)
        case .pill: collapsedInset(pageBottom: pageBottom)
        case .hidden: hiddenInset(pageBottom: pageBottom)
        }
    }
}

/// Tracks the toolbar from the page's scroll: expanded to the pill 1:1 with the finger, hidden
/// once the reader keeps going, and back on a clear move up (docs/state-rules.md, "Chrome while
/// reading").
struct ChromeCollapse: Equatable {
    /// What a scroll sample asks of the bar.
    enum Step: Equatable {
        /// Nothing changed.
        case none
        /// `progress` moved with the finger (between expanded and the pill).
        case moved
        /// Hide the bar: spring to `ChromeRest.hidden`.
        case hide
        /// Bring the whole bar back: spring to `ChromeRest.expanded`.
        case reveal
    }

    /// 0 expanded, 1 the pill, 2 hidden (`ChromeRest.progress`).
    private(set) var progress: CGFloat = 0
    /// Where the bar rests, or where the snap running now takes it.
    private(set) var rest = ChromeRest.expanded
    /// Scroll distance that takes the bar from expanded to the pill.
    let distance: CGFloat
    /// Further downward travel past the pill, in one drag or over several, before the bar hides.
    let hideDistance: CGFloat
    /// Downward page travel since the bar was last expanded; moves up take it back.
    private(set) var downTravel: CGFloat = 0
    /// Upward travel in the current drag while the bar is hidden.
    private var upTravel: CGFloat = 0
    private var lastOffset: CGFloat?

    init(distance: CGFloat = 56, hideDistance: CGFloat = 120) {
        self.distance = distance
        self.hideDistance = hideDistance
    }

    /// Upward travel in one drag that brings a hidden bar back: a deliberate move, not a nudge to
    /// reread a line or a finger's jitter (Firefox uses 20 pt, Chrome 10 pt).
    static let revealDistance: CGFloat = 24
    /// An upward drag at least this fast (points per millisecond) brings it back sooner, after
    /// `revealMinimumTravel`.
    static let revealVelocity: CGFloat = 0.3
    static let revealMinimumTravel: CGFloat = 8

    /// The downward travel since the bar was expanded at which it hides.
    var hideTravel: CGFloat { distance + hideDistance }

    /// Feeds a new content offset and returns what the bar should do.
    ///
    /// - Parameters:
    ///   - top: the offset at the page's top; `bottom` the largest offset at rest.
    ///   - pageEnd: the offset where the page's end reaches the screen's bottom edge
    ///     (`contentSize.height - bounds.height`). Arriving there brings the bar back, and the bar
    ///     does not collapse in the last `distance` before it: the reader is done, the bar is next.
    ///   - tracking: the finger is on the page. Coasting never moves the bar 1:1.
    ///   - snapping: a snap or a hide is moving the bar; only hide and reveal decisions apply.
    ///   - velocity: the finger's speed in points per millisecond, positive down the page.
    ///   - canHide: the state and the page allow the hidden bar (`ControlRules.chromeMayHide`, a
    ///     page long enough).
    @discardableResult
    mutating func scrolled(
        to offset: CGFloat, top: CGFloat, bottom: CGFloat, pageEnd: CGFloat = .greatestFiniteMagnitude,
        tracking: Bool = true, snapping: Bool = false, velocity: CGFloat = 0, canHide: Bool = false
    ) -> Step {
        let last = lastOffset
        lastOffset = offset
        if offset <= top {
            // At the top (or pulling past it) the bar is always out.
            if rest != .expanded, snapping || !tracking || progress > 1 { return .reveal }
            guard tracking, !snapping, progress != 0 else { return .none }
            progress = 0
            downTravel = 0
            return .moved
        }
        guard let last else { return .none }
        let delta = offset - last
        // Arriving at the page's end brings the bar back.
        if last < pageEnd, offset >= pageEnd, rest != .expanded || progress > 0 { return .reveal }
        // The bottom's rubber band must not move the bar.
        guard offset < bottom else { return .none }

        if rest == .hidden {
            guard tracking else { return .none }
            upTravel = delta < 0 ? upTravel - delta : 0
            let fast = -velocity >= Self.revealVelocity && upTravel >= Self.revealMinimumTravel
            return upTravel >= Self.revealDistance || fast ? .reveal : .none
        }

        // Close to the end the bar stays as it is: collapsing there would only bring it back.
        let nearEnd = offset >= pageEnd - distance
        if delta < 0 || !nearEnd, tracking || rest == .pill {
            downTravel = max(0, downTravel + delta)
        }
        if canHide, !nearEnd, delta > 0, downTravel >= hideTravel { return .hide }
        guard tracking, !snapping, delta < 0 || !nearEnd else { return .none }
        let before = progress
        progress = min(max(progress + delta / distance, 0), 1)
        if progress == 0 { downTravel = 0 }
        return progress != before ? .moved : .none
    }

    /// Forgets the last offset, so the next scroll starts fresh (a new drag, a finished snap).
    mutating func resetTracking() {
        lastOffset = nil
        upTravel = 0
    }

    /// A snap or a hide starts toward `rest`: hide and reveal decisions follow it from now.
    mutating func head(to rest: ChromeRest) {
        self.rest = rest
        upTravel = 0
        if rest == .expanded { downTravel = 0 }
    }

    /// The value on screen in a snap's frame. The scroll tracking is left alone.
    mutating func place(at value: CGFloat) {
        progress = min(max(value, 0), 2)
    }

    /// Sets the progress outright (a snap's end, a drag taking over mid-snap, or expanding for a
    /// new page). The next scroll starts fresh from it.
    mutating func settle(at value: CGFloat) {
        progress = min(max(value, 0), 2)
        rest = ChromeRest(progress: progress)
        if progress == 0 { downTravel = 0 }
        resetTracking()
    }

    /// Where the bar should settle when the finger lifts.
    ///
    /// - Parameters:
    ///   - velocity: the release velocity in points per millisecond, positive down the page.
    ///   - coast: how far down the page will still travel after the release (the scroll view's
    ///     target offset less the current one). A flick that carries the reader past the hide
    ///     travel goes straight to hidden, in one motion.
    ///   - canHide: as in `scrolled`. `coastReachesEnd`: the coast ends near the page's end, where
    ///     the bar comes back anyway. `atEnd`: the finger lifts near the end already, where the bar
    ///     is out (a flick against the end must not collapse it).
    func settleTarget(
        velocity: CGFloat = 0, coast: CGFloat = 0, canHide: Bool = false, coastReachesEnd: Bool = false,
        atEnd: Bool = false
    ) -> ChromeRest {
        if atEnd { return .expanded }
        if rest == .hidden { return velocity < -Self.clearVelocity ? .expanded : .hidden }
        if canHide, !coastReachesEnd, velocity > 0, downTravel + max(coast, 0) >= hideTravel { return .hidden }
        if velocity > Self.clearVelocity { return .pill }
        if velocity < -Self.clearVelocity { return .expanded }
        return progress >= 0.5 ? .pill : .expanded
    }

    /// A release faster than this (points per millisecond) picks the snap's direction.
    static let clearVelocity: CGFloat = 0.2
    /// The fastest the snap starts (progress per second): a hard flick still eases into place
    /// instead of slamming into the end.
    static let maxSnapVelocity: CGFloat = 8

    /// The snap's starting velocity in progress per second, from the scroll's release velocity
    /// (points per millisecond, positive scrolling down the page): the bar keeps the speed it had
    /// under the finger, where it followed the scroll 1:1 over `distance`. Only velocity toward
    /// `target` carries over.
    func snapVelocity(scrollVelocity: CGFloat, toward target: CGFloat) -> CGFloat {
        let perSecond = scrollVelocity * 1000 / distance
        let towardTarget = (target - progress) * perSecond >= 0 ? perSecond : 0
        return min(max(towardTarget, -Self.maxSnapVelocity), Self.maxSnapVelocity)
    }

    /// True while the bar is between expanded and the pill.
    var isMidway: Bool { progress > 0 && progress < 1 }
}

/// When the page's bottom inset may follow the bar's resting state (docs/plan.md, engine rule 4).
///
/// The inset changes once per motion, to the expanded, pill or hidden chrome, never per frame.
/// A bar that comes back (the inset grows) moves it as the motion starts, so a fixed page footer
/// rises with the bar instead of jumping into place after it; a bar that goes away (the inset
/// shrinks) moves it when the bar rests, so the footer never sits under a bar still on screen.
/// While the page is pulled past its top or bottom the change waits, because WebKit clamps the
/// overscroll on any inset change and the bounce would jump.
struct PageInsetState: Equatable {
    /// The resting state the page's inset shows. The bar starts out.
    private(set) var rest = ChromeRest.expanded
    /// A resting state waiting for the bounce to end.
    private(set) var pending: ChromeRest?

    /// The bar came to rest.
    mutating func barRested(_ rest: ChromeRest) {
        pending = rest == self.rest ? nil : rest
    }

    /// The bar is on the move again: a change still waiting for a bounce is stale.
    mutating func barMoved() {
        pending = nil
    }

    /// A snap starts toward `rest`. Coming back (more chrome than the page's inset shows), the
    /// inset follows now; going away, it waits for the bar to rest (`barRested`).
    mutating func barHeading(to rest: ChromeRest) {
        pending = rest.progress < self.rest.progress ? rest : nil
    }

    /// Applies a waiting change when the page is within its scroll range: `offset` is the content
    /// offset, `top` and `bottom` the smallest and largest offsets at rest. Returns true when the
    /// inset should change now.
    mutating func applyIfSettled(offset: CGFloat, top: CGFloat, bottom: CGFloat) -> Bool {
        guard let pending else { return false }
        // A page shorter than the screen rests at its top.
        let isOverscrolled = offset < top - 0.5 || offset > max(bottom, top) + 0.5
        guard !isOverscrolled else { return false }
        rest = pending
        self.pending = nil
        return true
    }
}


/// Pull to refresh's threshold logic (docs/plan.md, motion table: arms at 80 pt, selection haptic
/// at arm).
struct PullToRefreshTracker: Equatable {
    enum Change: Equatable {
        case armed
        case disarmed
    }

    static let threshold: CGFloat = 80
    /// An armed pull disarms only this far back under the threshold, so a finger resting on the
    /// line never chatters between the two haptics (haptics plan, rule 4).
    static let disarmHysteresis: CGFloat = 10
    private(set) var isArmed = false

    /// Feeds how far past the top the page is pulled. Returns the arm state's change, if any.
    mutating func pulled(_ distance: CGFloat) -> Change? {
        if !isArmed, distance >= Self.threshold {
            isArmed = true
            return .armed
        }
        if isArmed, distance < Self.threshold - Self.disarmHysteresis {
            isArmed = false
            return .disarmed
        }
        return nil
    }

    /// The finger lifted. Returns true when the page should reload.
    mutating func released() -> Bool {
        defer { isArmed = false }
        return isArmed
    }
}

/// Try Again on an error page, watched until its load ends: one that fails again gets the warning
/// haptic (haptics plan, §4.7), since the same sentence coming back is no answer by itself. The
/// watch is for one tab and one address: another tab on screen, a load that ends without failing,
/// or a failure of another address (a new one typed meanwhile) ends it silently.
struct RetryWatch: Equatable {
    private(set) var tab: UUID?
    private var address: URL?
    private var failures = 0
    private var started = false

    /// Try Again was tapped on `tab`'s error page, loading `address` again; `failures` is the
    /// tab's failed-load count then.
    mutating func begin(_ tab: UUID, address: URL?, failures: Int) {
        self.tab = tab
        self.address = address
        self.failures = failures
        started = false
    }

    /// The on-screen tab's state changed (`tab` nil: none on screen). true once, when the retried
    /// address failed again. A failure is told by the count, not the loading state, which one
    /// observation can miss when a load fails at once.
    mutating func update(tab id: UUID?, isLoading: Bool, failures: Int, failedAddress: URL?) -> Bool {
        guard let tab else { return false }
        guard id == tab else {
            self.tab = nil
            return false
        }
        if failures != self.failures {
            self.tab = nil
            return failedAddress == address
        }
        if isLoading {
            started = true
        } else if started {
            // It loaded.
            self.tab = nil
        }
        return false
    }
}

/// What brought a collapsed or hidden bar back, for the `toolbar.reveal` signpost.
enum ChromeRevealReason: String {
    case scrollUp = "scroll up"
    case pageTop = "page top"
    case pageEnd = "page end"
    case edgeTap = "edge tap"
    /// A tap on the collapsed top band (the Duo's inner screen).
    case bandTap = "band tap"
    case statusBar = "status bar"
    case keyboard
    case find
    case alert
    case newTab = "new tab"
    case shortPage = "short page"
    case state
    case accessibility
}
