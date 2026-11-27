import BrowserCore
import Foundation
import Synchronization

/// Whether a launch opens with the splash (docs/state-rules.md, "Launch splash").
public nonisolated enum SplashGate {
    /// An isolated test run (`TestIsolation`, any build) shows no splash unless this argument is
    /// given: hundreds of UI tests launch the app, and none of them is about the splash. The perf
    /// launch tests and the splash's own tests pass it, in Release too, so the launch they measure
    /// is the one a user gets.
    public static let argument = "-PlainSplash"

    /// - Parameters:
    ///   - alreadyPlayed: this process showed (or decided about) a splash before: only the first
    ///     scene of a cold launch plays it, never a second window or a return from the background.
    ///   - launchedForCommand: a link from another app, a widget, a shortcut, a Spotlight result
    ///     or Handoff started the app: the page comes first.
    ///   - isNewWindow: the scene was asked for by "Open in New Window".
    public static func shouldPlay(arguments: [String], alreadyPlayed: Bool, launchedForCommand: Bool, isNewWindow: Bool) -> Bool {
        guard FixedChoices.launchSplashEnabled, !alreadyPlayed, !launchedForCommand, !isNewWindow else { return false }
        if TestIsolation.mode(for: arguments) != .off { return arguments.contains(argument) }
        return true
    }
}

/// Debug-build launch arguments for the splash (docs/development.md): `-PlainSplashIcon
/// Night|Coral|Paper|Dawn` shows that icon's world without changing the Home Screen icon,
/// `-PlainSplashSlow 6` plays the dive six times slower, `-PlainSplashHold 2` waits 2 s longer
/// first, `-PlainSplashPath iris` forces the Core Animation iris.
nonisolated struct SplashDebug: Sendable, Equatable {
    var icon: AppIconChoice?
    var slow = 1.0
    var hold = 0.0
    var irisOnly = false

    init(arguments: [String]) {
        #if DEBUG
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        icon = value(after: "-PlainSplashIcon").flatMap { name in AppIconChoice.allCases.first { $0.rawValue.lowercased() == name.lowercased() } }
        slow = max(value(after: "-PlainSplashSlow").flatMap(Double.init) ?? 1, 1)
        hold = max(value(after: "-PlainSplashHold").flatMap(Double.init) ?? 0, 0)
        irisOnly = value(after: "-PlainSplashPath") == "iris"
        #endif
    }
}

/// A value another thread is making: taken if it is there (the main thread never waits for one),
/// waited for (a background queue) or handed to a callback once it is there.
///
/// `@unchecked Sendable`: every access to the state is under the lock.
nonisolated final class SplashFuture<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var done = false
    private var value: Value?
    private var waiters: [@Sendable (Value?) -> Void] = []

    /// Nil: it could not be made.
    func fulfill(_ made: Value?) {
        let waiting = lock.withLock { () -> [@Sendable (Value?) -> Void] in
            guard !done else { return [] }
            done = true
            value = made
            defer { waiters = [] }
            return waiters
        }
        ready.signal()
        for waiter in waiting { waiter(made) }
    }

    var isDone: Bool { lock.withLock { done } }

    /// The value if it is made by now; nil when it is not, or could not be made. Never waits.
    func take() -> Value? {
        lock.withLock { value }
    }

    /// Blocks until it is made. Never on the main thread.
    func wait() -> Value? {
        ready.wait()
        ready.signal()
        return lock.withLock { value }
    }

    /// Calls `handler` once, now if the value is made, else when it is (on the making thread).
    func whenReady(_ handler: @escaping @Sendable (Value?) -> Void) {
        let now = lock.withLock { () -> Value?? in
            if done { return .some(value) }
            waiters.append(handler)
            return nil
        }
        if let now { handler(now) }
    }
}

/// A flag one thread clears and others act on. Starts set. `whileSet` runs its body only while
/// the flag is set and holds off `clear` until the body is done, so once `clear` has returned
/// nothing guarded by the flag is running or will run.
nonisolated final class SplashFlag: Sendable {
    private let flag = Mutex(true)

    var isSet: Bool { flag.withLock { $0 } }

    func clear() { flag.withLock { $0 = false } }

    /// False when the flag was already cleared, and the body did not run.
    @discardableResult
    func whileSet(_ body: () -> Void) -> Bool {
        flag.withLock { set in
            if set { body() }
            return set
        }
    }
}

#if canImport(UIKit)
import Darwin
import DesignSystem
import PerfSignposts
import UIKit
import os

/// The launch splash and the dive through the P (docs/decisions.md, "Launch splash: through the
/// P"): the chosen icon's world over the app from the first frame, then the camera goes into the
/// P's counter, whose cut edge rolls back like the icon's fold, and the opening grows until the
/// app fills the screen.
///
/// The app never waits for it. The browser (or the intro) is built, laid out and interactive
/// underneath from its own first frame; the splash is a window above that passes every touch
/// through. Its pictures are drawn and its shaders compiled off the main thread from the moment
/// the scene connects (`init`); the first frame takes the pictures only if they are drawn (it never waits), and the
/// dive takes the GPU renderer only if it is ready a little before the start, else Core
/// Animation plays a plain iris. A touch, a link from another app, typing, or the app leaving
/// the foreground ends it at once.
///
/// One per process: only the first scene of a cold launch makes one (`SplashGate`).
public final class LaunchSplash {
    /// How a splash ended, for the signpost and the tests.
    enum Ending: String {
        /// The GPU dive ran to its end.
        case metal
        /// The Core Animation iris ran to its end.
        case iris
        /// Reduce Motion: a fade.
        case crossfade
        /// A touch, typing, a link or a resize ended it early.
        case skipped
        /// The app left the foreground.
        case left
        /// Its pictures were not drawn in time for the first frame: no splash this launch.
        case missed
    }

    /// In an isolated test run the window under the splash carries an accessibility element with
    /// this identifier once the splash has ended; its value says how (`Ending`) and, after a GPU
    /// dive, the frame timing.
    public static let reportIdentifier = "plainLaunchSplash"

    nonisolated static let log = Logger(subsystem: Signposts.subsystem, category: "launch")
    /// A splash was made, or decided against, in this process.
    private static var decided = false

    /// Above the browser's window and the intro's.
    private static let windowLevel = UIWindow.Level.alert + 1

    private weak var scene: UIWindowScene?
    private let debug: SplashDebug
    private let art = SplashFuture<SplashArt>()
    private let kit = SplashFuture<SplashKit>()
    private let iris = SplashFuture<SplashIrisArt>()
    private var window: SplashWindow?
    private var view: LaunchSplashView?
    private var content: () -> UIView? = { nil }
    private var renderer: SplashRenderer?
    /// The dive's start, once scheduled.
    private var t0: CFTimeInterval?
    /// Between scheduling the dive and choosing who draws it.
    private var choosing = false
    private var firstFrameDone = false
    private var sceneActive = false
    private var ended = false
    private var typing: NSObjectProtocol?
    /// Whether a GPU renderer is still wanted: until the splash ends or Core Animation is chosen.
    /// Read by the renderer's builder on its own queue.
    private let wantsRenderer = SplashFlag()
    private var firstFrame: FirstFrame?
    private var splashInterval: OSSignpostIntervalState?
    private var diveInterval: OSSignpostIntervalState?
    /// Called once, when the splash is gone (or was never shown).
    public var onEnd: (() -> Void)?
    /// Called once, when the app starts to show: `FixedChoices.splashKeyboardAt` into the dive,
    /// or when the splash ends sooner. The keyboard of a search-first launch waits for this.
    public var onOpening: (() -> Void)?

    private func opening() {
        let open = onOpening
        onOpening = nil
        open?()
    }

    /// Decides whether this launch has a splash and, if so, starts drawing its pictures and
    /// compiling its shaders off the main thread. Call it as early as the scene connects, before
    /// the browser is built: that work then runs while the main thread builds the first frame.
    public init?(scene: UIWindowScene, arguments: [String], launchedForCommand: Bool, isNewWindow: Bool) {
        let play = SplashGate.shouldPlay(
            arguments: arguments, alreadyPlayed: Self.decided, launchedForCommand: launchedForCommand, isNewWindow: isNewWindow
        )
        Self.decided = true
        guard play else { return nil }
        let signposter = Signposts.signposter
        let build = signposter.beginInterval(Signposts.launchSplashBuild, "prepare")
        defer { signposter.endInterval(Signposts.launchSplashBuild, build) }
        self.scene = scene
        debug = SplashDebug(arguments: arguments)
        // The icon's world, as the Home Screen shows it: the system's light or dark, not the
        // app's own Appearance setting. The launch screen under it follows the system too.
        let dark = scene.traitCollection.userInterfaceStyle == .dark
        let theme = SplashTheme.theme(for: debug.icon ?? AppIcons.current, dark: dark)
        let scale = scene.traitCollection.displayScale
        let art = art, kit = kit
        DispatchQueue.global(qos: .userInitiated).async {
            art.fulfill(SplashArt.draw(theme: theme, scale: scale))
        }
        // Reduce Motion fades; it needs no renderer.
        guard !Motion.prefersCrossfade, !debug.irisOnly else {
            kit.fulfill(nil)
            return
        }
        let kicked = CACurrentMediaTime()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let built = try SplashKit { art.wait() }
                Self.log.debug("""
                    splash kit: library+pipelines \(built.compileTime * 1000, format: .fixed(precision: 1)) ms, \
                    whole kit \(built.buildTime * 1000, format: .fixed(precision: 1)) ms, \
                    ready \((CACurrentMediaTime() - kicked) * 1000, format: .fixed(precision: 1)) ms after the scene connected
                    """)
                kit.fulfill(built)
            } catch {
                Self.log.error("splash kit failed: \(String(describing: error), privacy: .public)")
                kit.fulfill(nil)
            }
        }
    }

    // MARK: First frame

    /// Puts the splash over the app, before the first frame is committed. `content` is the view
    /// the app shows under it (the browser's, or the intro's), asked for when the dive starts.
    public func show(over content: @escaping () -> UIView?) {
        guard !ended, window == nil, let scene else { return }
        let signposter = Signposts.signposter
        let build = signposter.beginInterval(Signposts.launchSplashBuild, "show")
        defer { signposter.endInterval(Signposts.launchSplashBuild, build) }
        // Only if the pictures are drawn by now (they are started as the scene connects and take a
        // few milliseconds; the browser's build since then takes many times that). The first
        // frame never waits for them: a launch that outran them goes on with no splash.
        self.content = content
        guard let art = art.take() else {
            Self.log.error("splash pictures not ready for the first frame: no splash")
            Signposts.signposter.emitEvent(Signposts.launchSplash, "missed")
            return finish(.missed)
        }
        let controller = SplashViewController(art: art)
        let window = SplashWindow(windowScene: scene)
        window.windowLevel = Self.windowLevel
        window.backgroundColor = .clear
        window.rootViewController = controller
        window.onTouch = { [weak self] in self?.end() }
        window.isHidden = false
        controller.splash.onResize = { [weak self] in self?.end() }
        self.window = window
        view = controller.splash
        splashInterval = signposter.beginInterval(Signposts.launchSplash)
        // Typing on a hardware keyboard goes to the search field under the splash: show it.
        typing = NotificationCenter.default.addObserver(forName: UITextField.textDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
        sceneActive = scene.activationState == .foregroundActive
        // The clock starts from what is on screen: a display link's first callback comes at the
        // vsync after the first frame went to the render server (a dispatch to the main queue can
        // run before that commit).
        firstFrame = FirstFrame { [weak self] in
            self?.firstFrame = nil
            self?.firstFrameDone = true
            self?.scheduleIfReady()
        }
    }

    /// Calls back once, at the first display-link callback after it is made.
    private final class FirstFrame: NSObject {
        private let done: () -> Void
        private var link: CADisplayLink?

        init(_ done: @escaping () -> Void) {
            self.done = done
            super.init()
            let link = CADisplayLink(target: self, selector: #selector(fire(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func fire(_ link: CADisplayLink) {
            link.invalidate()
            self.link = nil
            done()
        }

        func cancel() {
            link?.invalidate()
            link = nil
        }
    }

    /// The scene is on screen and active (the app delegate's scene callback).
    public func sceneDidBecomeActive() {
        sceneActive = true
        scheduleIfReady()
    }

    // MARK: The dive

    /// Schedules the dive once the first frame is out and the scene is active: no sooner than
    /// `splashMinimumTime` after the process started, nor `splashHandoff` after this moment.
    private func scheduleIfReady() {
        guard !ended, t0 == nil, firstFrameDone, sceneActive, let view else { return }
        view.layoutIfNeeded()
        guard let layout = view.layout else { return finish(.missed) }
        let elapsed = Self.processUptime() ?? 0
        let delay = max(FixedChoices.splashMinimumTime - elapsed, FixedChoices.splashHandoff) + debug.hold
        let start = CACurrentMediaTime() + delay
        t0 = start

        if Motion.prefersCrossfade {
            view.crossfade(t0: start, duration: Motion.crossfadeDuration) { [weak self] in self?.finish(.crossfade) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.opening() }
            return
        }

        // The iris's own pictures, in case Core Animation plays the dive.
        let theme = view.art.theme, iris = iris
        DispatchQueue.global(qos: .userInitiated).async {
            iris.fulfill(SplashIrisArt.draw(theme: theme, layout: layout))
        }
        // Put in while the splash is still (the hole is hidden under the ring), never mid-dive.
        iris.whenReady { [weak self] made in
            Task { @MainActor in
                guard let self, let made, !self.ended, self.choosing else { return }
                self.view?.setIrisArt(made)
            }
        }

        choosing = true
        // Once the kit is built, draw the renderer's first frame off the main thread, then choose.
        let slow = debug.slow
        let finished: @Sendable (SplashStats) -> Void = { [weak self] stats in
            Task { @MainActor in self?.rendererFinished(stats) }
        }
        let wanted = wantsRenderer
        kit.whenReady { [weak self] kit in
            // No renderer (Metal failed, or the iris was asked for): Core Animation plays the dive,
            // chosen at the deadline below, by when its own pictures are drawn.
            guard let kit else { return }
            let note = String(format: "kit %.1f ms (shaders %.1f)", kit.buildTime * 1000, kit.compileTime * 1000)
            Task { @MainActor in self?.kitNote = note }
            DispatchQueue.global(qos: .userInteractive).async {
                let made: SplashRenderer?
                let why: String
                do {
                    made = try SplashRenderer.make(kit: kit, layout: layout, t0: start, slow: slow, wanted: wanted, onFinish: finished)
                    why = ""
                } catch {
                    made = nil
                    why = String(describing: error)
                }
                Task { @MainActor in self?.choose(made, why: why) }
            }
        }
        let wait = max(start - FixedChoices.splashRendererLead - CACurrentMediaTime(), 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.choose(nil, why: self.kit.isDone && self.kit.take() == nil ? "no renderer" : "renderer not ready in time")
        }
    }

    /// Chooses who draws the dive, once: the GPU renderer if it arrived in time, else Core Animation.
    private func choose(_ made: SplashRenderer?, why: String) {
        guard choosing, !ended, let t0, let view else {
            made?.cancel()   // already chosen; a late renderer is simply dropped
            return
        }
        choosing = false
        let now = CACurrentMediaTime()
        // A main thread blocked past the start would skip the beginning: start a beat later instead.
        let start = max(t0, now + 0.03)
        let k = debug.slow
        diveInterval = Signposts.signposter.beginInterval(Signposts.launchSplashDive)
        if let made, now < t0 - FixedChoices.splashRendererLead / 2 {
            renderer = made
            view.show(made)
            made.start()
            // Should the render thread never report back, the splash still goes.
            let limit = start - now + SplashTimeline.duration * k + 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in self?.finish(.metal) }
        } else {
            wantsRenderer.clear()
            made?.cancel()
            let reason = made == nil ? why : "renderer too close to the start"
            Self.log.debug("splash: Core Animation (\(reason, privacy: .public))")
            frames = reason
            if let iris = iris.take(), !view.hasIrisArt { view.setIrisArt(iris) }
            guard view.hasIrisArt else {
                // Without its own pictures the iris has no hole to open: fade instead.
                if let diveInterval { Signposts.signposter.endInterval(Signposts.launchSplashDive, diveInterval, "crossfade") }
                diveInterval = nil
                view.crossfade(t0: start, duration: Motion.crossfadeDuration) { [weak self] in self?.finish(.crossfade) }
                DispatchQueue.main.asyncAfter(deadline: .now() + (start - now)) { [weak self] in self?.opening() }
                return
            }
            view.playIris(t0: start, slow: k) { [weak self] in self?.finish(.iris) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (start - now) + FixedChoices.splashKeyboardAt * k) { [weak self] in
            self?.opening()
        }
        // The app settles from a little large to its size as the opening grows.
        if let content = content() {
            let length = (SplashTimeline.duration - SplashTimeline.diveStart) * k
            let zoom = CASpringAnimation(perceptualDuration: length, bounce: 0)
            zoom.keyPath = "transform.scale"
            zoom.fromValue = FixedChoices.splashContentZoom
            zoom.toValue = 1.0
            zoom.beginTime = start + SplashTimeline.diveStart * k
            zoom.duration = zoom.settlingDuration
            zoom.fillMode = .backwards
            zoom.preferredFrameRateRange = LaunchSplashView.frameRate
            content.layer.add(zoom, forKey: Self.zoomKey)
        }
    }

    private static let zoomKey = "launchSplashZoom"

    private func rendererFinished(_ stats: SplashStats) {
        let summary = stats.summary + (kitNote.map { "; " + $0 } ?? "")
        Self.log.debug("splash: \(summary, privacy: .public)")
        Signposts.signposter.emitEvent(Signposts.launchSplashFrames, "\(summary, privacy: .public)")
        frames = summary
        finish(.metal)
    }

    /// After a GPU dive its frame timing; after an iris, why the GPU did not draw it.
    private var frames: String?
    /// The kit's build times, for the frame report.
    private var kitNote: String?

    // MARK: Ending

    /// Ends the splash now: a touch, typing, a link from another app or a resize. A short fade,
    /// while the app underneath already has the touch.
    public func end() {
        guard !ended, let view else { return finish(.skipped) }
        ended = true
        choosing = false
        wantsRenderer.clear()
        content()?.layer.removeAnimation(forKey: Self.zoomKey)
        // After this turn: `end` runs inside the touch's hit test, and the keyboard's return is
        // not something to start from in there.
        DispatchQueue.main.async { [weak self] in self?.opening() }
        view.fadeOut(duration: FixedChoices.splashSkipFade) { [weak self] in self?.remove(.skipped) }
    }

    /// The app left the foreground: the splash goes at once, with nothing drawn in the background.
    public func sceneDidLeave() {
        content()?.layer.removeAnimation(forKey: Self.zoomKey)
        ended = true
        choosing = false
        remove(.left)
    }

    private func finish(_ ending: Ending) {
        guard !ended else { return }
        ended = true
        choosing = false
        remove(ending)
    }

    private func remove(_ ending: Ending) {
        guard window != nil || onEnd != nil || splashInterval != nil else { return }
        wantsRenderer.clear()
        firstFrame?.cancel()
        firstFrame = nil
        renderer?.cancel()
        renderer = nil
        if let typing { NotificationCenter.default.removeObserver(typing) }
        typing = nil
        let host = content()?.window
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        view = nil
        let signposter = Signposts.signposter
        if let diveInterval { signposter.endInterval(Signposts.launchSplashDive, diveInterval, "\(ending.rawValue, privacy: .public)") }
        if let splashInterval {
            let why = ending == .iris ? frames.map { " (\($0))" } ?? "" : ""
            signposter.endInterval(Signposts.launchSplash, splashInterval, "\(ending.rawValue, privacy: .public)\(why, privacy: .public)")
        }
        diveInterval = nil
        splashInterval = nil
        report(ending, in: host)
        opening()
        let done = onEnd
        onEnd = nil
        content = { nil }
        done?()
    }

    /// An isolated test run reads how the splash ended from an invisible element in the app's window.
    private func report(_ ending: Ending, in host: UIWindow?) {
        guard TestIsolation.isActive, let host else { return }
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = Self.reportIdentifier
        marker.accessibilityLabel = "Launch splash"
        marker.accessibilityValue = [ending.rawValue, frames].compactMap(\.self).joined(separator: "; ")
        host.addSubview(marker)
    }

    /// Seconds since this process started (the user's tap, roughly).
    nonisolated static func processUptime() -> CFTimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        let start = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        let elapsed = Date().timeIntervalSince1970 - start
        return elapsed >= 0 && elapsed < 60 ? elapsed : nil
    }
}
#endif
