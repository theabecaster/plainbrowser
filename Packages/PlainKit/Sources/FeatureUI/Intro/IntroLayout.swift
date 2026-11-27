#if canImport(UIKit)
import CoreGraphics

/// Where the dawn window and the mark sit on each step, shared by the view controller (which moves
/// them) and the steps (which leave room for them). Everything is measured from the safe area, so
/// it follows the screen, never the device.
///
/// The dawn shows through a window cut in the paper at the top: tall on the promise and default
/// steps, with the mark resting on its sill, and a narrow band over the steps that need the room.
enum IntroLayout {
    /// The row with the step rings and Skip, inside the window.
    static let topRow: CGFloat = 44
    /// The mark on the promise and default steps.
    static let markSize: CGFloat = 96
    /// How far the mark rises above the sill: the ring sits in the window, its stem stands on
    /// the paper.
    static let markLift: CGFloat = 0.2 * markSize
    /// The window's gap to the safe area's top and sides, and its corners.
    static let windowTop: CGFloat = 2
    static let windowInset: CGFloat = 12
    static let windowCorner: CGFloat = 30
    static let bandCorner: CGFloat = 22
    static let windowMaxWidth: CGFloat = 520

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }

    private static func isBand(_ step: IntroModel.Step) -> Bool {
        step == .inside || step == .icon || step == .blocking
    }

    /// The window's height on each step.
    static func windowHeight(_ step: IntroModel.Step, safeHeight: CGFloat) -> CGFloat {
        switch step {
        case .promise: clamp(safeHeight * 0.40, 200, 360)
        case .defaultBrowser: clamp(safeHeight * 0.28, 170, 280)
        case .inside, .icon, .blocking: clamp(safeHeight * 0.085, 56, 76)
        }
    }

    /// How far the sun is up on each step: the day breaks as the intro goes on.
    static func rise(_ step: IntroModel.Step) -> CGFloat {
        switch step {
        case .promise: 0.12
        case .inside: 0.35
        case .icon: 0.55
        case .blocking: 0.75
        case .defaultBrowser: 1
        }
    }

    /// The room a step leaves under its top row for the window, and on the promise step for the
    /// part of the mark below the sill.
    static func reserve(_ step: IntroModel.Step, safeHeight: CGFloat) -> CGFloat {
        let window = windowTop + windowHeight(step, safeHeight: safeHeight) - topRow
        return step == .promise ? window + markSize / 2 - markLift : window
    }

    /// The mark at rest on the promise step: on the window's sill.
    static func promiseMark(safe: CGRect) -> CGRect {
        let sill = safe.minY + windowTop + windowHeight(.promise, safeHeight: safe.height)
        return CGRect(x: safe.midX - markSize / 2, y: sill - markSize / 2 - markLift, width: markSize, height: markSize)
    }

    /// The dawn window on a step.
    static func scene(_ step: IntroModel.Step, safe: CGRect) -> DawnView.Scene {
        let width = min(safe.width - 2 * windowInset, windowMaxWidth)
        let band = isBand(step)
        return DawnView.Scene(
            frame: CGRect(x: safe.midX - width / 2, y: safe.minY + windowTop, width: width,
                          height: windowHeight(step, safeHeight: safe.height)),
            cornerRadius: band ? bandCorner : windowCorner,
            rise: rise(step),
            horizon: band ? 0.8 : 0.72
        )
    }
}
#endif
