#if os(iOS)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import SwiftUI
import UIKit

/// The first-run intro: the Stem mark assembles on paper and the dawn opens behind it, then the steps (promise, what's
/// inside, icon where it can change,
/// blocking demo, Browse for Me where Apple Intelligence can run, and the
/// default-browser step when its prompts are on). Finishing
/// or skipping dissolves it into the search field. See docs/research/intro.md.
///
/// Shown once (`IntroGate`). The app puts it in its own window above the browser's: on finish it
/// calls `onFinish`, the app brings up the browser (its search field takes focus, the keyboard
/// rises), and then calls `dissolve(completion:)` to fade the intro off the top.
public final class IntroViewController: UIViewController {
    /// Runs once, when the user finishes or skips. The intro is already marked seen.
    public var onFinish: (() -> Void)?

    private let model = IntroModel(
        defaultBrowserStep: DefaultBrowserPrompts.isEnabled(),
        iconStep: AppIcons.isSupported,
        icon: AppIcons.current
    )
    private let dawn = DawnView()
    private let mark = StemMarkView(shadowed: true)
    private lazy var steps = UIHostingController(rootView: IntroStepsView(model: model))
    private enum MarkPlace { case splash, promise, gone }
    private var markPlace = MarkPlace.splash
    private var splashInterval: OSSignpostIntervalState?
    /// The bounds and safe area the dawn was last laid out for.
    private var laidOut: (CGRect, CGRect)?
    private var didStart = false
    /// The window's hierarchy reports a hinge (`UIHingeInteraction`): the phone folds.
    private var hasHinge = false
    private var isSplashing = false
    private let splashTap = UITapGestureRecognizer()
    /// Reads the on-device model's availability (ShellUI's `OnDeviceAI` in the app).
    private let aiAvailability: @MainActor () async -> AIAvailability
    private var firstAnswer: Task<Void, Never>?
    private var aiCheck: Task<Void, Never>?
    private var foregroundObserver: (any NSObjectProtocol)?

    /// - Parameter aiAvailability: the model's availability, read once before the first step
    ///   (it decides whether the Browse for Me step shows) and again while that step needs it.
    public init(aiAvailability: @escaping @MainActor () async -> AIAvailability = { .deviceNotEligible }) {
        self.aiAvailability = aiAvailability
        super.init(nibName: nil, bundle: nil)
    }

    isolated deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        firstAnswer?.cancel()
        aiCheck?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        // The paper is the launch screen's color, so the launch hands over without a change.
        view.backgroundColor = Palette.background
        view.accessibilityIdentifier = "intro"
        // UIKit's own answer to "does this phone fold": a hinge interaction gets a hinge only in a
        // hierarchy that has one (nil elsewhere). It only reads; nothing here follows the angle.
        view.addInteraction(UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            let hasHinge = update.hinge != nil
            guard self.hasHinge != hasHinge else { return }
            self.hasHinge = hasHinge
            self.view.setNeedsLayout()
        })
        let ground = IntroPaper.makeGround()
        ground.frame = view.bounds
        ground.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(ground)
        dawn.frame = view.bounds
        dawn.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dawn)

        addChild(steps)
        steps.view.backgroundColor = .clear
        steps.view.frame = view.bounds
        steps.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(steps.view)
        steps.didMove(toParent: self)

        mark.accessibilityIdentifier = "introMark"
        view.addSubview(mark)

        // Only for the splash; it never takes a touch from the steps' buttons.
        splashTap.addTarget(self, action: #selector(splashTapped))
        splashTap.cancelsTouchesInView = false
        view.addGestureRecognizer(splashTap)
        model.onStepChange = { [weak self] step in self?.stepChanged(to: step) }
        model.onFinish = { [weak self] in self?.finished() }
        // Icon previews decode off the main thread now, so the icon step has them when it comes.
        Task { [model] in await model.loadPreviews() }
        // The model's answer comes in during the splash, so the steps are known before the first.
        firstAnswer = Task { [weak self, aiAvailability] in
            let answer = await aiAvailability()
            self?.model.setAIAvailability(answer)
        }
        // Back from Settings (Apple Intelligence turned on, or not): read the answer again.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAI() }
        }
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        if model.safeHeight != safe.height { model.safeHeight = safe.height }
        // A fold or unfold changes the traits and the bounds together, so this pass sees it.
        let traits = traitCollection
        let canUnfold = IntroRules.showsUnfoldRow(
            hasHinge: hasHinge, hasVerticalBarEdge: traits.verticalBarEdge != .unspecified,
            widthRegular: traits.horizontalSizeClass == .regular, heightRegular: traits.verticalSizeClass == .regular
        )
        if model.canUnfold != canUnfold { model.canUnfold = canUnfold }
        layoutMark()
        // A new size (the Duo unfolding, a rotation) moves the dawn with it, at once.
        if laidOut.map({ $0.0 != view.bounds || $0.1 != safe }) ?? true {
            laidOut = (view.bounds, safe)
            if let step = model.step { dawn.apply(scene(step)) }
        }
    }

    /// The first frame is the launch color alone: no mark yet, no dawn.
    override public func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard !didStart else { return }
        mark.isHidden = true
        dawn.alpha = 0
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        // The splash's clock starts at the vsync after the first frame reached the render server,
        // not when the view appears: the first frame of a cold launch can take a few hundred ms,
        // and the mark would otherwise show up already half drawn.
        let link = CADisplayLink(target: self, selector: #selector(firstFrameDidCommit(_:)))
        link.add(to: .main, forMode: .common)
    }

    @objc private func firstFrameDidCommit(_ link: CADisplayLink) {
        link.invalidate()
        firstFrameCommitted = true
        if !waitsForLaunchSplash { playSplash() }
    }

    /// The launch splash covers the intro's first frame (docs/state-rules.md, "Launch splash"):
    /// the mark waits to assemble until the dive opens onto it. Set before the view appears.
    public var waitsForLaunchSplash = false
    private var firstFrameCommitted = false

    /// The launch splash is opening (or gone): the mark assembles now.
    public func launchSplashIsOpening() {
        guard waitsForLaunchSplash else { return }
        waitsForLaunchSplash = false
        if firstFrameCommitted, !isSplashing, mark.isHidden { playSplash() }
    }

    override public var preferredStatusBarStyle: UIStatusBarStyle { .default }

    // MARK: Splash

    private func playSplash() {
        isSplashing = true
        splashInterval = Signposts.signposter.beginAnimationInterval(Signposts.introSplash)
        mark.isHidden = false
        mark.assemble(onLanded: { Haptic.tap.play() }, completion: { [weak self] in self?.splashEnded() })
    }

    /// A tap during the splash lands the mark at once and goes on.
    @objc private func splashTapped() {
        guard isSplashing else { return }
        mark.showAssembled()
        splashEnded()
    }

    private func splashEnded() {
        guard isSplashing else { return }
        isSplashing = false
        view.removeGestureRecognizer(splashTap)
        if let splashInterval { Signposts.signposter.endInterval(Signposts.introSplash, splashInterval) }
        splashInterval = nil
        // The first step waits a moment at most for the model's answer; without it the intro goes
        // on with no Browse for Me step. The answer is almost always in by now.
        guard model.aiAvailability == nil, let firstAnswer else {
            model.start()
            return
        }
        // Two independent tasks, whichever ends first starts the intro (`start` runs once): a task
        // group would wait for the answer even after the timeout.
        Task { [weak self] in
            await firstAnswer.value
            self?.model.start()
        }
        Task { [weak self] in
            try? await Task.sleep(for: IntroMotion.aiAnswerWait)
            self?.model.start()
        }
    }

    // MARK: Apple Intelligence

    /// Reads the answer again while the Browse for Me step is on screen (on arriving, and back
    /// from Settings), and every few seconds while the model is getting ready.
    private func checkAI() {
        // Only on its own step: the other steps never read it.
        guard model.step == .browseForMe else { return }
        aiCheck?.cancel()
        aiCheck = Task { [weak self, aiAvailability] in
            while !Task.isCancelled {
                let answer = await aiAvailability()
                guard let self, !Task.isCancelled else { return }
                Signposts.signposter.emitEvent(Signposts.introAIAvailability, "\(String(describing: answer), privacy: .public)")
                model.setAIAvailability(answer)
                guard model.step == .browseForMe, model.browseForMe == .gettingReady else { return }
                try? await Task.sleep(for: IntroMotion.aiRecheck)
            }
        }
    }

    // MARK: Steps

    private func scene(_ step: IntroModel.Step) -> DawnView.Scene {
        IntroLayout.scene(step, safe: view.safeAreaLayoutGuide.layoutFrame)
    }

    private func stepChanged(to step: IntroModel.Step?) {
        if dawn.scene == nil, let step {
            openDawn(on: step)
        } else if let step {
            dawn.apply(scene(step), animation: IntroMotion.dawnStep)
        }
        switch step {
        case .promise: moveMark(to: .promise)
        default: moveMark(to: .gone)
        }
        if step != nil {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        // On the Browse for Me step the answer is read again (the model may have finished
        // downloading meanwhile); elsewhere no checks run.
        if step == .browseForMe { checkAI() } else { aiCheck?.cancel() }
    }

    /// The signature moment: the dawn opens out of the mark, growing from the ring's own window into
    /// the page's while the mark settles on its sill.
    private func openDawn(on step: IntroModel.Step) {
        let target = scene(step)
        if Motion.prefersCrossfade {
            dawn.apply(target)
            UIView.animate(withDuration: Motion.crossfadeDuration) { self.dawn.alpha = 1 }
            return
        }
        var start = target
        let circle = mark.windowRect(in: view)
        start.frame = circle
        start.cornerRadius = circle.width / 2
        start.rise = 0
        dawn.apply(start)
        dawn.alpha = 1
        dawn.apply(target, animation: IntroMotion.dawn)
    }

    private func moveMark(to place: MarkPlace) {
        guard place != markPlace else { return }
        markPlace = place
        if place == .gone {
            // It leaves with the step around it: the same fade and slight shrink (a fade alone
            // under Reduce Motion).
            let reduce = Motion.prefersCrossfade
            let shrunk = mark.transform.scaledBy(x: 0.92, y: 0.92)
            UIView.animate(withDuration: reduce ? Motion.crossfadeDuration : 0.32, delay: 0,
                           options: [.curveEaseIn, .allowUserInteraction]) {
                self.mark.alpha = 0
                if !reduce { self.mark.transform = shrunk }
            } completion: { _ in
                self.mark.isHidden = true
            }
            return
        }
        // Onto the promise step's place, on the same spring as the dawn opening behind it.
        Motion.animate(IntroMotion.dawn, crossfading: view) {
            self.layoutMark()
        }
    }

    private func layoutMark() {
        guard markPlace != .gone else { return }
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let target: CGRect
        switch markPlace {
        case .splash:
            let side = min(min(safe.width, safe.height) * 0.46, 220)
            target = CGRect(x: safe.midX - side / 2, y: safe.midY - side / 2 - 20, width: side, height: side)
        case .promise:
            target = IntroLayout.promiseMark(safe: safe)
        case .gone:
            return
        }
        // Moved by center and scale, so the layers inside never relayout mid-flight.
        let base = CGRect(x: 0, y: 0, width: 220, height: 220)
        if mark.bounds != base { mark.bounds = base }
        mark.center = CGPoint(x: target.midX, y: target.midY)
        let scale = target.width / base.width
        mark.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    // MARK: Finish

    private func finished() {
        IntroGate.markSeen()
        view.isUserInteractionEnabled = false
        moveMark(to: .gone)
        // The step's own dissolve runs first; the browser comes up as it ends.
        Task {
            try? await Task.sleep(for: .seconds(Motion.prefersCrossfade ? 0.15 : 0.22))
            onFinish?()
        }
    }

    /// Fades the intro away over the browser (whose keyboard is rising), then calls `completion`.
    public func dissolve(completion: @escaping () -> Void) {
        let interval = Signposts.signposter.beginAnimationInterval(Signposts.introFinish)
        let reduce = Motion.prefersCrossfade
        UIView.animate(withDuration: reduce ? Motion.crossfadeDuration : 0.5, delay: 0, options: [.curveEaseInOut]) {
            self.view.alpha = 0
            if !reduce { self.dawn.transform = CGAffineTransform(scaleX: 1.06, y: 1.06) }
        } completion: { _ in
            Signposts.signposter.endInterval(Signposts.introFinish, interval)
            completion()
        }
    }
}

/// The intro's paper in one place: the ground under every step and the fill of its sheets (the
/// feature cards). The shared paper texture (DesignSystem `Paper`) is applied here and nowhere
/// else in the intro.
enum IntroPaper {
    /// The ground under the dawn and the steps.
    static func makeGround() -> UIView {
        let ground = UIView()
        Paper.apply(to: ground)
        ground.isUserInteractionEnabled = false
        return ground
    }

    /// A sheet of paper lying on the ground.
    static let sheet = Palette.surface
}
#endif
