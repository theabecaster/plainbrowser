#if canImport(UIKit)
import BrowserCore
import UIKit

/// The launch splash's window: above the browser's and the intro's. The first touch ends the
/// splash and does nothing else: the app underneath is built and interactive, but a tap on
/// something that cannot be seen must not act on it (a tap on the search sheet's empty space
/// would close the search). Touches after that one go straight through while the splash fades.
final class SplashWindow: UIWindow {
    var onTouch: (() -> Void)?
    /// The event time of the touch that ended the splash; UIKit may hit-test one touch twice.
    private var ending: TimeInterval?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let ending else {
            ending = event?.timestamp ?? 0
            onTouch?()
            return rootViewController?.view
        }
        return event?.timestamp == ending ? rootViewController?.view : nil
    }
}

/// Holds the splash and gives the status bar the right text color for the icon's field while
/// the splash is up.
final class SplashViewController: UIViewController {
    let splash: LaunchSplashView
    private let lightStatusBar: Bool

    init(art: SplashArt) {
        splash = LaunchSplashView(art: art)
        lightStatusBar = art.theme.statusBarIsLight
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = splash }
    override var preferredStatusBarStyle: UIStatusBarStyle { lightStatusBar ? .lightContent : .darkContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
}

/// The splash: the chosen icon's world, three pictures drawn once (`SplashArt`) in three layers.
/// Core Animation shows it from the first frame; for the dive the GPU renderer's layer takes its
/// place (`show(_:)`), its first frame the same pixels. When the renderer isn't ready in time,
/// Core Animation plays the plain iris instead (`playIris`).
///
/// Layers (bottom to top), all in `cover`, which is what the iris scales:
/// - `field`: the icon's background, stretched over the screen;
/// - `dawn`: the dawn in the window;
/// - `depth`: the opening's shadow and lit rim (the iris only; `SplashIrisArt`);
/// - `mark`: the ring, the stem and the fold, on the pixel grid.
final class LaunchSplashView: UIView {
    let art: SplashArt
    private(set) var layout: SplashLayout?
    /// The window changed size (a rotation, a fold) after the splash was laid out.
    var onResize: (() -> Void)?

    private let cover = CALayer()
    private let field = CALayer()
    private let dawn = CALayer()
    private let depth = CALayer()
    private let mark = CALayer()

    init(art: SplashArt) {
        self.art = art
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        field.contents = art.field.image
        dawn.contents = art.view.image
        mark.contents = art.mark.image
        depth.opacity = 0
        for layer in [field, dawn, depth, mark] {
            layer.contentsGravity = .resize
            cover.addSublayer(layer)
        }
        layer.addSublayer(cover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let next = SplashLayout(size: bounds.size, scale: art.scale)
        if let layout {
            if layout != next { onResize?() }
            return
        }
        layout = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // bounds + position, not frame: the iris scales the cover about the opening's pivot.
        cover.bounds = bounds
        cover.anchorPoint = CGPoint(x: next.pivot.x / bounds.width, y: next.pivot.y / bounds.height)
        cover.position = next.pivot
        field.frame = bounds
        dawn.frame = next.viewRect
        mark.frame = next.tileRect
        CATransaction.commit()
    }

    /// The iris's own pictures, once drawn: the field with its hole (hidden under the ring, so
    /// the change can't be seen) and the opening's depth.
    func setIrisArt(_ iris: SplashIrisArt) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.contents = iris.field.image
        depth.contents = iris.depth.image
        depth.frame = iris.depthRect
        CATransaction.commit()
    }

    var hasIrisArt: Bool { depth.contents != nil }

    /// Swaps the Core Animation splash for the renderer's identical first frame, in one transaction.
    func show(_ renderer: SplashRenderer) {
        let begin = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.addSublayer(renderer.layer)
        renderer.presentFirstFrame()
        cover.isHidden = true
        CATransaction.commit()
        renderer.noteSwap(CACurrentMediaTime() - begin)
    }

    /// The Core Animation iris, scheduled whole on the render server: the dawn clears, the cover
    /// (field, mark and the opening's depth) scales about the pivot until the opening has cleared
    /// the screen. `k` is the debug slow-motion factor.
    func playIris(t0: CFTimeInterval, slow k: Double, completion: @escaping () -> Void) {
        guard let layout else { return completion() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)

        let start = SplashTimeline.diveStart * k, length = (SplashTimeline.duration - SplashTimeline.diveStart) * k
        let iris = CAKeyframeAnimation(keyPath: "transform.scale")
        iris.values = SplashTimeline.zoomKeyframes(end: Double(layout.zoomEnd))
        iris.calculationMode = .linear
        iris.beginTime = t0 + start
        iris.duration = length
        iris.fillMode = .backwards
        iris.preferredFrameRateRange = Self.frameRate
        cover.add(iris, forKey: "iris")
        cover.transform = CATransform3DMakeScale(layout.zoomEnd, layout.zoomEnd, 1)
        // The pictures soften at large scale; by then the edge is leaving the screen, so the last
        // bit fades.
        cover.add(basic("opacity", from: 1, to: 0, at: t0 + start + length * 0.85, duration: length * 0.15, .linear), forKey: "fade")
        cover.opacity = 0

        dawn.add(basic("opacity", from: 1, to: 0, at: t0, duration: SplashTimeline.dawnClear * k, .easeInEaseOut), forKey: "clear")
        dawn.opacity = 0

        // The depth: in as the dawn clears, there while the opening is small, lifting as it opens.
        let end = SplashTimeline.depthOut * k
        let shade = CAKeyframeAnimation(keyPath: "opacity")
        shade.values = [0, 1, 1, 0]
        shade.keyTimes = [0, NSNumber(value: SplashTimeline.depthIn * k / end), NSNumber(value: start / end), 1]
        shade.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear),
                                 CAMediaTimingFunction(name: .easeIn)]
        shade.beginTime = t0
        shade.duration = end
        shade.fillMode = .backwards
        depth.add(shade, forKey: "depth")
        CATransaction.commit()
    }

    /// Reduce Motion: the splash fades off the app.
    func crossfade(t0: CFTimeInterval, duration: CFTimeInterval, completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(basic("opacity", from: 1, to: 0, at: t0, duration: duration, .easeInEaseOut), forKey: "fade")
        layer.opacity = 0
        CATransaction.commit()
    }

    /// Ends whatever is playing with a short fade from what is on screen now.
    func fadeOut(duration: CFTimeInterval, completion: @escaping () -> Void) {
        let now = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.removeAnimation(forKey: "fade")
        layer.add(basic("opacity", from: CGFloat(now), to: 0, at: 0, duration: duration, .easeOut), forKey: "skip")
        layer.opacity = 0
        CATransaction.commit()
    }

    static let frameRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    private func basic(_ key: String, from: CGFloat, to: CGFloat, at start: CFTimeInterval, duration: CFTimeInterval,
                       _ timing: CAMediaTimingFunctionName) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.beginTime = start
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: timing)
        a.fillMode = .backwards
        a.preferredFrameRateRange = Self.frameRate
        return a
    }
}
#endif
