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
/// Cost per scroll callback: a table lookup and one layer color, no color math and no allocation.
/// The arrow is a symbol used as a mask over a plain view, so a new color is a layer property, not
/// a symbol drawn again.
final class PullIndicator: UIView {
    static let size: CGFloat = 36

    /// A private tab's pull runs through the private palette.
    var isPrivate = false
    private(set) var isRefreshing = false
    private var isArmed = false
    /// The arrow's color, under the symbol's mask.
    private let arrow = UIView()
    private let shape = UIImageView()
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
        let image = UIImage(
            systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        shape.image = image
        let size = image?.size ?? CGSize(width: 16, height: 18)
        shape.frame = CGRect(origin: .zero, size: size)
        arrow.mask = shape
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

    /// Follows a pull of `distance` points; `threshold` is where it arms.
    func follow(pull distance: CGFloat, threshold: CGFloat) {
        guard !isRefreshing else { return }
        let fraction = min(max(distance / threshold, 0), 1)
        alpha = fraction
        // Halfway down the pulled gap, never above its resting spot.
        let drop = max(0, distance / 2 - Self.size / 2)
        transform = CGAffineTransform(translationX: 0, y: drop).rotated(by: fraction * .pi)
        guard !isArmed else { return }
        applyCycle(fraction: Double(fraction))
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

    func setArmed(_ armed: Bool) {
        guard !isRefreshing, armed != isArmed else { return }
        isArmed = armed
        let fill = isPrivate ? PullTint.privateFill : Palette.accent
        Motion.animate(Motion.quick, changes: {
            self.backgroundColor = armed ? fill : Palette.surface
            if armed { self.arrow.backgroundColor = .white }
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
    static let privateFill = Palette.privateAccent
    static let privateRest = Palette.privateAccentOnGlass

    /// Lightness bands so every color holds about 3:1 on the indicator's ground: white by day
    /// (OKLab L at most 0.62), the dark surface by night (at least 0.74).
    private static let dayBand = 0.0...0.62
    private static let nightBand = 0.74...1.0

    /// Built on first use, one palette and appearance at a time: the first pull in a light
    /// regular tab makes 96 samples (well under a millisecond), never all four loops at once.
    private static var cycles: [Int: ColorCycle] = [:]
    private static var tables: [Int: [CGColor]] = [:]

    static func cycle(isPrivate: Bool, dark: Bool) -> ColorCycle {
        let slot = key(isPrivate, dark)
        if let cycle = cycles[slot] { return cycle }
        let stops = (isPrivate ? privateStops : PullTint.stops).map(srgb)
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

    private static func key(_ isPrivate: Bool, _ dark: Bool) -> Int { (isPrivate ? 1 : 0) + (dark ? 2 : 0) }

    private static func srgb(_ color: UIColor) -> SRGB {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SRGB(red: Double(red), green: Double(green), blue: Double(blue))
    }
}
#endif
