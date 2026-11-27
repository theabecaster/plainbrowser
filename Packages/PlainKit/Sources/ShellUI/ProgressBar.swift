#if canImport(UIKit)
import DesignSystem
import UIKit

/// The load-progress bar along the URL pill's bottom edge (Brand/identity.md): mint to blue,
/// ending in a coral tip. It shows only while the page loads (docs/ui-reference.md, Chrome).
///
/// Progress moves a full-width gradient with a transform, so an update never relayouts.
final class ProgressBar: UIView {
    private let fill = GradientView()
    private(set) var progress: Double = 0
    /// Bumped by every new load, so a fade from the previous load cannot hide this one.
    private var generation = 0
    /// Moves the bar on its own while the engine reports nothing, so a page that waits on its
    /// server never looks stuck (`creep`).
    private var creepTimer: Timer?
    private var lastReport = Date.distantPast

    /// How often the creep checks, how long the engine may stay quiet first, and how far the
    /// creep may take the bar: a third of the way, eased, so real progress always has room.
    static let creepInterval: TimeInterval = 0.25
    static let creepQuietTime: TimeInterval = 0.5
    static let creepCeiling: Double = 0.35
    static let creepStep: Double = 0.12

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        alpha = 0
        resolveColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: ProgressBar, _) in bar.resolveColors() }
        fill.gradient.locations = [0, 0.82, 1]
        fill.gradient.startPoint = CGPoint(x: 0, y: 0.5)
        fill.gradient.endPoint = CGPoint(x: 1, y: 0.5)
        addSubview(fill)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.transform = .identity
        fill.frame = bounds
        applyProgress()
    }

    private func resolveColors() {
        fill.gradient.colors = Palette.progress.map { $0.resolvedColor(with: traitCollection).cgColor }
    }

    /// Shows the bar and moves it to `value` (0...1). Progress never runs backwards within a load.
    func setProgress(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        guard clamped > progress else { return }
        lastReport = Date()
        if clamped < Self.creepCeiling { startCreep() }
        move(to: clamped)
    }

    private func move(to clamped: Double) {
        progress = clamped
        if alpha < 1 {
            alpha = 1
            applyProgress()
        } else {
            Motion.animate(Motion.quick, changes: { self.applyProgress() })
        }
    }

    /// Starts a new load: empties the bar, cancelling the previous load's fill and fade.
    func begin() {
        generation += 1
        stopCreep()
        layer.removeAllAnimations()
        fill.layer.removeAllAnimations()
        reset()
    }

    /// Fills the bar, then fades it out (the load finished).
    func finish() {
        stopCreep()
        guard alpha > 0 else { return }
        progress = 1
        let load = generation
        Motion.animate(Motion.quick, changes: { self.applyProgress() }) {
            guard load == self.generation else { return }
            UIView.animate(withDuration: Motion.crossfadeDuration, delay: 0, options: [.allowUserInteraction]) {
                self.alpha = 0
            } completion: { _ in
                if load == self.generation { self.reset() }
            }
        }
    }

    /// Hides the bar at once and empties it, ready for the next load.
    func reset() {
        stopCreep()
        progress = 0
        alpha = 0
        applyProgress()
    }

    /// While the engine is quiet (the server has not answered yet, a slow connection), the bar
    /// eases toward `creepCeiling` by itself, as Safari's does. Monotonic: the engine's next
    /// report only ever moves it further.
    private func startCreep() {
        guard creepTimer == nil else { return }
        let timer = Timer(timeInterval: Self.creepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.creep() }
        }
        timer.tolerance = Self.creepInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        creepTimer = timer
    }

    private func stopCreep() {
        creepTimer?.invalidate()
        creepTimer = nil
    }

    private func creep() {
        guard alpha > 0, progress < Self.creepCeiling else { return stopCreep() }
        guard Date().timeIntervalSince(lastReport) >= Self.creepQuietTime else { return }
        move(to: progress + (Self.creepCeiling - progress) * Self.creepStep)
    }

    private func applyProgress() {
        fill.transform = CGAffineTransform(translationX: -(1 - progress) * bounds.width, y: 0)
    }
}

/// A view backed by a gradient layer, so the layer follows the view's frame and transform.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { layer as! CAGradientLayer }
}
#endif
