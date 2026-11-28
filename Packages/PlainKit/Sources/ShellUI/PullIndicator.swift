#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import UIKit

/// The pull-to-refresh indicator: an arrow that turns as the page is pulled and runs through the
/// brand's colors on the way (Shallows Mint, Lagoon, the icon's violet, Curl Coral; the dusk
/// violets in a private tab), faster the nearer the pull is to reloading. Once the pull is far
/// enough it fills with Lagoon (the threshold haptic, from the shell; a tick if pulled back);
/// after release it spins in that one color until the page's load ends. Reduce Motion: one color, no spin.
///
/// The arrow is drawn, not an SF Symbol: `arrow.clockwise`'s image box is not centered on its
/// circle (the open arc and the arrowhead sit off-center), so a symbol turned about its view's
/// center wobbles, and the system's Rotate effect runs on a clock, not with a finger
/// (docs/research/gestures.md, "The refresh arrow"). Here the arc is a true circle about the view's
/// center: it grows with the pull (`strokeEnd`), its head rides the arc's end, and the spin turns
/// the layer about that same center, so it stays concentric.
///
/// Cost per scroll callback: a table lookup, one layer color, the arc's `strokeEnd` and the head's
/// rotation, all layer properties with implicit animations off. No color math, no path built, no
/// image drawn, no allocation.
final class PullIndicator: UIView {
    static let size: CGFloat = 36
    /// The arrow's box, its circle's radius and stroke, and the gap the open arc leaves (radians).
    private static let arrowBox: CGFloat = 20
    private static let radius: CGFloat = 6.5
    private static let lineWidth: CGFloat = 2.25
    private static let gap: CGFloat = 0.9
    /// How much of the arc shows at the start of a pull; it closes to its full sweep at the threshold.
    private static let arcStart: CGFloat = 0.12

    /// A private tab's pull runs through the private palette.
    var isPrivate = false
    private(set) var isRefreshing = false
    private var isArmed = false
    /// The arrow's color, under the drawn arc and head (its mask).
    private let arrow = UIView()
    private let arc = CAShapeLayer()
    private let head = CAShapeLayer()
    /// The table entry last applied, so a callback that lands on the same color does nothing.
    private var lastIndex = -1
    private var refreshInterval: OSSignpostIntervalState?
    private var refreshDeadline: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = Palette.surface
        layer.cornerRadius = Self.size / 2
        layer.cornerCurve = .continuous
        let size = CGSize(width: Self.arrowBox, height: Self.arrowBox)
        let mask = CALayer()
        mask.frame = CGRect(origin: .zero, size: size)
        // The window's scale replaces this one when the view lands in it.
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        for part in [arc, head] {
            part.frame = mask.bounds
            part.contentsScale = scale
            mask.addSublayer(part)
        }
        let (arcPath, headPath) = Self.paths(in: mask.bounds)
        arc.path = arcPath
        arc.fillColor = nil
        arc.strokeColor = UIColor.black.cgColor
        arc.lineWidth = Self.lineWidth
        arc.lineCap = .round
        head.path = headPath
        head.fillColor = UIColor.black.cgColor
        head.strokeColor = UIColor.black.cgColor
        head.lineWidth = 1
        head.lineJoin = .round
        arrow.layer.mask = mask
        arrow.backgroundColor = Palette.textSecondary
        arrow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arrow)
        NSLayoutConstraint.activate([
            arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: size.width),
            arrow.heightAnchor.constraint(equalToConstant: size.height),
        ])
        alpha = 0
        accessibilityIdentifier = "pullToRefresh"
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The drawn arrow is rasterized at the screen's scale, known once in a window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, traitCollection.displayScale > 0 else { return }
        let scale = traitCollection.displayScale
        for part in [arc, head] where part.contentsScale != scale { part.contentsScale = scale }
        arrow.layer.mask?.contentsScale = scale
    }

    /// Follows a pull of `distance` points; `threshold` is where it arms.
    func follow(pull distance: CGFloat, threshold: CGFloat) {
        guard !isRefreshing else { return }
        let fraction = min(max(distance / threshold, 0), 1)
        alpha = fraction
        // Halfway down the pulled gap, never above its resting spot. The disc itself never turns.
        let drop = max(0, distance / 2 - Self.size / 2)
        transform = CGAffineTransform(translationX: 0, y: drop)
        setArc(fraction)
        guard !isArmed else { return }
        applyCycle(fraction: Double(fraction))
    }

    /// The arc shows `fraction` of its sweep (from `arcStart`), its head at its end.
    private func setArc(_ fraction: CGFloat) {
        let shown = Self.arcStart + (1 - Self.arcStart) * fraction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = shown
        // The head is drawn at the full sweep's end; it turns back about the circle's center.
        head.setAffineTransform(CGAffineTransform(rotationAngle: -(1 - shown) * (2 * .pi - Self.gap)))
        CATransaction.commit()
    }

    /// The open arc clockwise from just after twelve o'clock to just before it (the gap at the
    /// top), and a filled arrowhead at its end pointing on along the circle. Both centered on the
    /// box, so any rotation about the center keeps them on the same circle.
    private static func paths(in box: CGRect) -> (CGPath, CGPath) {
        let center = CGPoint(x: box.midX, y: box.midY)
        let start = -CGFloat.pi / 2 + gap / 2
        let end = start + 2 * .pi - gap
        let arc = UIBezierPath(arcCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        // The head: a triangle whose base straddles the arc's end, tip ahead along the tangent.
        let tip = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
        let tangent = CGVector(dx: -sin(end), dy: cos(end))
        let normal = CGVector(dx: cos(end), dy: sin(end))
        let length: CGFloat = 4.6, half: CGFloat = 3.4
        let head = UIBezierPath()
        head.move(to: CGPoint(x: tip.x + tangent.dx * length * 0.6, y: tip.y + tangent.dy * length * 0.6))
        head.addLine(to: CGPoint(
            x: tip.x - tangent.dx * length * 0.4 + normal.dx * half, y: tip.y - tangent.dy * length * 0.4 + normal.dy * half
        ))
        head.addLine(to: CGPoint(
            x: tip.x - tangent.dx * length * 0.4 - normal.dx * half, y: tip.y - tangent.dy * length * 0.4 - normal.dy * half
        ))
        head.close()
        return (arc.cgPath, head.cgPath)
    }

    /// The arrow's color for a pull `fraction` of the way to the threshold.
    private func applyCycle(fraction: Double) {
        guard !Motion.prefersCrossfade else {
            // One color: the cycle is motion of its own.
            return setArrowColor(Self.restColor(isPrivate: isPrivate), index: -2)
        }
        let dark = traitCollection.userInterfaceStyle == .dark
        let table = PullTint.table(isPrivate: isPrivate, dark: dark)
        let phase = ColorCycle.phase(fraction: fraction, turns: FixedChoices.pullTintTurns)
        let index = PullTint.cycle(isPrivate: isPrivate, dark: dark).index(atPhase: phase)
        // Tables differ per palette and appearance: the key folds both in.
        let key = index + (isPrivate ? 1000 : 0) + (dark ? 2000 : 0)
        guard key != lastIndex else { return }
        lastIndex = key
        arrow.layer.backgroundColor = table[index]
    }

    private func setArrowColor(_ color: UIColor, index: Int) {
        lastIndex = index
        arrow.backgroundColor = color
    }

    /// The color a pull rests on: Lagoon (on paper, a deeper step by day) or the private violet.
    private static func restColor(isPrivate: Bool) -> UIColor {
        isPrivate ? PullTint.privateRest : Palette.accentOnGlass
    }

    /// Builds this palette's color table ahead of a pull (a page finished loading), so the
    /// pull's first scroll callback only indexes it.
    func prepareColors() {
        guard !Motion.prefersCrossfade else { return }
        _ = PullTint.table(isPrivate: isPrivate, dark: traitCollection.userInterfaceStyle == .dark)
    }

    func setArmed(_ armed: Bool) {
        guard !isRefreshing, armed != isArmed else { return }
        isArmed = armed
        let fill = isPrivate ? PullTint.privateFill : Palette.accent
        // The arrow turns white at once, so it never sits half-cycled on the filling disc.
        if armed { arrow.backgroundColor = .white }
        Motion.animate(Motion.quick, changes: {
            self.backgroundColor = armed ? fill : Palette.surface
        })
        if !armed { lastIndex = -1 }
        accessibilityValue = armed ? "armed" : nil
    }

    /// Released armed: the arrow moves to its resting spot and spins in the one color until
    /// `endRefreshing` (the load ended) or `FixedChoices.pullSpinnerLongest` has passed.
    func beginRefreshing() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshInterval = Signposts.signposter.beginInterval(Signposts.pullRefreshing)
        let fill = isPrivate ? PullTint.privateFill : Palette.accent
        setArc(1)
        Motion.animate(Motion.quick, changes: {
            self.alpha = 1
            self.transform = .identity
            self.backgroundColor = fill
            self.arrow.backgroundColor = .white
        })
        if !Motion.prefersCrossfade {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 0.8
            spin.repeatCount = .infinity
            arrow.layer.add(spin, forKey: "spin")
        }
        let deadline = DispatchWorkItem { [weak self] in self?.endRefreshing() }
        refreshDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + FixedChoices.pullSpinnerLongest, execute: deadline)
        accessibilityValue = "refreshing"
    }

    func endRefreshing() {
        guard isRefreshing else { return }
        refreshDeadline?.cancel()
        refreshDeadline = nil
        if let refreshInterval { Signposts.signposter.endInterval(Signposts.pullRefreshing, refreshInterval) }
        refreshInterval = nil
        isRefreshing = false
        hide()
    }

    func hide() {
        guard !isRefreshing else { return }
        isArmed = false
        accessibilityValue = nil
        Motion.animate(Motion.quick, changes: {
            self.alpha = 0
        }) {
            guard !self.isRefreshing, self.alpha == 0 else { return }
            self.arrow.layer.removeAnimation(forKey: "spin")
            self.backgroundColor = Palette.surface
            self.arrow.backgroundColor = Palette.textSecondary
            self.lastIndex = -1
        }
    }
}

/// The pull's color loops: small tables of `CGColor`s, each built once on first use.
enum PullTint {
    static let stops = Palette.pullCycle
    static let privateStops = Palette.privatePullCycle
    static let privateFill = Palette.privatePullFill
    static let privateRest = Palette.privatePullRest

    /// Lightness bands so every color holds about 3:1 on the indicator's ground: white by day
    /// (OKLab L at most 0.62), the dark surface by night (at least 0.74).
    private static let dayBand = 0.0...0.62
    private static let nightBand = 0.74...1.0

    /// Built on first use, one palette and appearance at a time (96 samples), never all four
    /// loops at once; `PullIndicator.prepareColors` builds the one in use when a page finishes
    /// loading, so a pull's scroll callbacks only index it.
    private static var cycles: [Int: ColorCycle] = [:]
    private static var tables: [Int: [CGColor]] = [:]

    static func cycle(isPrivate: Bool, dark: Bool) -> ColorCycle {
        let slot = key(isPrivate, dark)
        if let cycle = cycles[slot] { return cycle }
        // There and back (mint, Lagoon, violet, coral, violet, Lagoon): coral never blends
        // straight into mint, its opposite, which passes through grey.
        let stops = pingPong(isPrivate ? privateStops : PullTint.stops).map(srgb)
        let cycle = ColorCycle(stops: stops, lightness: dark ? nightBand : dayBand)
        cycles[slot] = cycle
        return cycle
    }

    static func table(isPrivate: Bool, dark: Bool) -> [CGColor] {
        let slot = key(isPrivate, dark)
        if let table = tables[slot] { return table }
        let table = cycle(isPrivate: isPrivate, dark: dark).table.map {
            CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
        }
        tables[slot] = table
        return table
    }

    private static func pingPong(_ stops: [UIColor]) -> [UIColor] {
        stops.count > 2 ? stops + stops.reversed().dropFirst().dropLast() : stops
    }

    private static func key(_ isPrivate: Bool, _ dark: Bool) -> Int { (isPrivate ? 1 : 0) + (dark ? 2 : 0) }

    private static func srgb(_ color: UIColor) -> SRGB {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SRGB(red: Double(red), green: Double(green), blue: Double(blue))
    }
}
#endif
