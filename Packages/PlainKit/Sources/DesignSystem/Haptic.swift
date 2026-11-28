import CoreGraphics
import Foundation
import PerfSignposts
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// Plain's haptic language (docs/ui-reference.md, "Haptics"; docs/research/haptics.md). Eight
/// kinds, each with one meaning. A haptic marks a moment, never a tap whose result is on screen.
/// Haptics follow System Haptics, which UIKit's generators already respect: there is no switch.
public enum Haptic: String, Sendable, CaseIterable {
    /// The tick: a value or state changed in place, or a gesture crossed back over its threshold.
    case selection
    /// The commit: an action whose result is small, off-screen or delayed (a background tab).
    case tap
    /// A gesture crossed into a new outcome while the finger is still down (medium, 0.7).
    case threshold
    /// A dragged item landed in a new place (rigid, 0.6).
    case drop
    /// Something went away: a tab, a pane, a profile (soft).
    case close
    /// It worked, and the result is invisible or ends a wait (Copy Link, a finished download).
    case success
    /// A task the user started and waited for did not work. The soft warning pattern, never the
    /// three-hit error: Plain's failures are recoverable and say why.
    case failed
    /// Instant refusal, nothing to do (Back with no history). At most one per `nothingThereGap`.
    case nothingThere
}

// MARK: - Gates (throttle, suppression, recorder, signpost): platform-free, so `swift test` runs them

extension Haptic {
    /// The timing Plain decides (`FixedChoices.hapticMinimumGap`, `hapticNothingThereGap`; the
    /// scene sets it once at connect). The defaults equal those values, and a test keeps them so.
    public struct Timing: Sendable, Equatable {
        /// Two haptics closer than this are one event: the first, synced to the visual, wins.
        public var minimumGap: TimeInterval
        /// A refusal repeated faster than this stays silent.
        public var nothingThereGap: TimeInterval

        public init(minimumGap: TimeInterval = 0.06, nothingThereGap: TimeInterval = 1) {
            self.minimumGap = minimumGap
            self.nothingThereGap = nothingThereGap
        }
    }

    public static func configure(_ timing: Timing) { Gate.timing = timing }

    /// Every play that passed the gates, in order (UI tests' `-PlainHapticLog`, unit tests). nil in
    /// normal runs, so the perf gate never pays for it.
    public static var recorder: ((Haptic) -> Void)? {
        get { Gate.recorder }
        set { Gate.recorder = newValue }
    }

    /// Runs `body` with every haptic suppressed: key commands (a keyboard means a desk), the
    /// threshold paths of VoiceOver custom actions, state restoration. Nests.
    public static func withoutFeedback<T>(_ body: () throws -> T) rethrows -> T {
        Gate.suppression += 1
        defer { Gate.suppression -= 1 }
        return try body()
    }

    /// The clock, injectable for tests.
    static var now: () -> CFTimeInterval {
        get { Gate.now }
        set { Gate.now = newValue }
    }

    /// Forgets the last plays (tests).
    static func resetGates() {
        Gate.lastPlay = -.infinity
        Gate.lastNothingThere = -.infinity
    }

    /// The platform-free half of a play: suppression, the throttle (first wins), then the recorder
    /// and the signpost. true when the generator should fire. O(1), no allocation.
    func admit() -> Bool {
        guard Gate.suppression == 0 else { return false }
        let now = Gate.now()
        guard now - Gate.lastPlay >= Gate.timing.minimumGap else { return false }
        if self == .nothingThere {
            guard now - Gate.lastNothingThere >= Gate.timing.nothingThereGap else { return false }
            Gate.lastNothingThere = now
        }
        Gate.lastPlay = now
        Gate.recorder?(self)
        Signposts.signposter.emitEvent(Signposts.haptic, "\(rawValue, privacy: .public)")
        return true
    }
}

private enum Gate {
    static var timing = Haptic.Timing()
    static var recorder: ((Haptic) -> Void)?
    static var suppression = 0
    static var now: () -> CFTimeInterval = CACurrentMediaTime
    static var lastPlay: CFTimeInterval = -.infinity
    static var lastNothingThere: CFTimeInterval = -.infinity
}

/// `prepare()` once per gesture: the flag holds until the next fire on that generator or until
/// `lifetime` passes (the engine stays ready "typically seconds", and repeated prepares without a
/// fire may be ignored), so a caller may ask from every `.changed` frame for free.
struct PrepareFlag: Sendable {
    static let lifetime: CFTimeInterval = 2
    private var preparedAt: CFTimeInterval?

    /// true when the generator should really be prepared now (and marks it prepared).
    mutating func shouldPrepare(at now: CFTimeInterval) -> Bool {
        if let preparedAt, now - preparedAt < Self.lifetime { return false }
        preparedAt = now
        return true
    }

    /// The generator fired: the engine idles again, so the next prepare goes through.
    mutating func fired() { preparedAt = nil }
}

/// The both-ways threshold rule, written once (docs/ui-reference.md, "Haptics", rule 4): crossing
/// into the outcome gives `.threshold`, falling back out by more than the hysteresis gives
/// `.selection`, and a finger resting on the line never chatters. `value` grows toward the
/// outcome (a distance, a progress); feed it what is on screen, after the rubber band.
public struct ThresholdLatch: Sendable {
    public var threshold: CGFloat
    public var hysteresis: CGFloat
    public private(set) var isArmed = false

    public init(threshold: CGFloat, hysteresis: CGFloat) {
        self.threshold = threshold
        self.hysteresis = hysteresis
    }

    /// The haptic this frame's value calls for, if it crossed the line either way.
    public mutating func update(_ value: CGFloat) -> Haptic? {
        if !isArmed, value >= threshold {
            isArmed = true
            return .threshold
        }
        if isArmed, value < threshold - hysteresis {
            isArmed = false
            return .selection
        }
        return nil
    }

    /// A new gesture starts unarmed.
    public mutating func reset() { isArmed = false }

    /// Takes the state `value` is in without a haptic (a finger grabbing a page mid-spring).
    public mutating func sync(_ value: CGFloat) { isArmed = value >= threshold }
}

#if canImport(UIKit)
// MARK: - Playing (UIKit)

// The app's only: the widget extension links DesignSystem for its colors and has no
// `UIApplication`.
@available(iOSApplicationExtension, unavailable)
extension Haptic {
    /// Plays on the window that holds `view`, located at `point` in `view`'s space where given (Apple
    /// Pencil Pro, haptic trackpads). No view: the foreground key window. Plays nothing while the
    /// app is not active: an outcome that finished in the background plays with its toast.
    public func play(in view: UIView? = nil, at point: CGPoint? = nil) {
        guard UIApplication.shared.applicationState == .active else { return }
        // The window first: a play with nowhere to go neither records nor holds the throttle.
        guard let window = Self.window(for: view), admit() else { return }
        let location = point.flatMap { point in view.map { $0.convert(point, to: window) } }
        WindowGenerators.for(window).fire(self, at: location, in: window)
    }

    /// Readies this kind's generator for a fire expected within about a second (a gesture's
    /// `.began`, a pull past half its threshold). Cheap to repeat: it prepares once until a fire.
    public func prepare(in view: UIView? = nil) {
        guard let window = Self.window(for: view) else { return }
        WindowGenerators.for(window).prepare(self, in: window)
    }

    private static func window(for view: UIView?) -> UIWindow? {
        if let window = view as? UIWindow ?? view?.window { return window }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
        where scene.activationState == .foregroundActive {
            if let key = scene.keyWindow { return key }
        }
        return nil
    }
}

/// A window's generators, each attached to the window and made on first use (none at launch).
/// Kept weakly by window, so a closed window (iPad, the Duo's scenes) lets them go.
@MainActor
private final class WindowGenerators {
    private static let table = NSMapTable<UIWindow, WindowGenerators>.weakToStrongObjects()

    static func `for`(_ window: UIWindow) -> WindowGenerators {
        if let generators = table.object(forKey: window) { return generators }
        let generators = WindowGenerators()
        table.setObject(generators, forKey: window)
        return generators
    }

    private enum Slot: Int, CaseIterable { case selection, light, medium, rigid, soft, notification }

    private var selection: UISelectionFeedbackGenerator?
    private var impacts: [UIImpactFeedbackGenerator?] = [nil, nil, nil, nil, nil, nil]
    private var notification: UINotificationFeedbackGenerator?
    private var flags = [PrepareFlag](repeating: PrepareFlag(), count: Slot.allCases.count)

    private init() {}

    private static func slot(_ kind: Haptic) -> Slot {
        switch kind {
        case .selection: .selection
        case .tap: .light
        case .threshold: .medium
        case .drop: .rigid
        case .close, .nothingThere: .soft
        case .success, .failed: .notification
        }
    }

    func fire(_ kind: Haptic, at location: CGPoint?, in window: UIWindow) {
        let slot = Self.slot(kind)
        flags[slot.rawValue].fired()
        switch kind {
        case .selection:
            let generator = selectionGenerator(window)
            if let location { generator.selectionChanged(at: location) } else { generator.selectionChanged() }
        case .success, .failed:
            let type: UINotificationFeedbackGenerator.FeedbackType = kind == .success ? .success : .warning
            let generator = notificationGenerator(window)
            if let location { generator.notificationOccurred(type, at: location) } else { generator.notificationOccurred(type) }
        case .tap, .threshold, .drop, .close, .nothingThere:
            let intensity: CGFloat = switch kind {
            case .threshold: 0.7
            case .drop: 0.6
            case .nothingThere: 0.5
            default: 1
            }
            let generator = impact(slot, window)
            if let location { generator.impactOccurred(intensity: intensity, at: location) } else { generator.impactOccurred(intensity: intensity) }
        }
    }

    func prepare(_ kind: Haptic, in window: UIWindow) {
        let slot = Self.slot(kind)
        guard flags[slot.rawValue].shouldPrepare(at: CACurrentMediaTime()) else { return }
        switch slot {
        case .selection: selectionGenerator(window).prepare()
        case .notification: notificationGenerator(window).prepare()
        default: impact(slot, window).prepare()
        }
    }

    private func selectionGenerator(_ window: UIWindow) -> UISelectionFeedbackGenerator {
        if let selection { return selection }
        let generator = UISelectionFeedbackGenerator(view: window)
        selection = generator
        return generator
    }

    private func notificationGenerator(_ window: UIWindow) -> UINotificationFeedbackGenerator {
        if let notification { return notification }
        let generator = UINotificationFeedbackGenerator(view: window)
        notification = generator
        return generator
    }

    private func impact(_ slot: Slot, _ window: UIWindow) -> UIImpactFeedbackGenerator {
        if let generator = impacts[slot.rawValue] { return generator }
        let style: UIImpactFeedbackGenerator.FeedbackStyle = switch slot {
        case .light: .light
        case .medium: .medium
        case .rigid: .rigid
        default: .soft
        }
        let generator = UIImpactFeedbackGenerator(style: style, view: window)
        impacts[slot.rawValue] = generator
        return generator
    }
}
#else
extension Haptic {
    /// No Taptic Engine here (macOS `swift test`): the gates and the recorder only, so the models
    /// that play haptics (Settings, History) are tested with the same calls.
    public func play() { _ = admit() }
    public func prepare() {}
}
#endif
