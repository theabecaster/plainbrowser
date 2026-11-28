#if canImport(UIKit)
import BrowserCore
import DesignSystem
import UIKit

/// The app's side of `Haptic` (DesignSystem can't see BrowserCore): the timing Plain decides, and
/// the UI tests' haptic log. The scene calls both; nothing else runs in a normal launch.
public enum HapticSetup {
    /// The timing from `FixedChoices`. Idempotent: every scene may call it.
    public static func configure() {
        Haptic.configure(timing)
    }

    static let timing = Haptic.Timing(
        minimumGap: FixedChoices.hapticMinimumGap, nothingThereGap: FixedChoices.hapticNothingThereGap
    )

    /// The launch argument that turns the log on, in an isolated test run only.
    public static let logArgument = "-PlainHapticLog"
    /// The hidden element each window carries with the log: value `"<count> <kind>,<kind>,…"`,
    /// the last 8 kinds, oldest first. The count lets a test see new events.
    public static let logIdentifier = "plainHapticLog"

    private static let logViews = NSHashTable<UIView>.weakObjects()
    private static var log: [String] = []
    private static var count = 0

    /// With `-PlainHapticLog` in an isolated run: records every haptic that passed the gates and
    /// shows them on a tiny accessibility element in `window`. Nothing otherwise, so the recorder
    /// stays nil in the perf gate and in the owner's app.
    public static func installLog(in window: UIWindow, arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard TestIsolation.isActive, arguments.contains(logArgument) else { return }
        if Haptic.recorder == nil { Haptic.recorder = record }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = logIdentifier
        view.accessibilityLabel = "Haptic log"
        view.accessibilityValue = value
        window.addSubview(view)
        logViews.add(view)
    }

    private static func record(_ kind: Haptic) {
        count += 1
        log.append(kind.rawValue)
        if log.count > 32 { log.removeFirst(log.count - 32) }
        for view in logViews.allObjects { view.accessibilityValue = value }
    }

    private static var value: String {
        "\(count) " + log.suffix(8).joined(separator: ",")
    }
}
#endif
