import Foundation

/// The page menu's zoom: one step in or out of `FixedChoices.pageZoomSteps`, and its percentage.
/// Plain values, so the rules test on macOS.
public enum PageZoom {
    public static let actualSize = 1.0

    /// The next step above `zoom`, or nil at the largest step.
    public static func zoomedIn(from zoom: Double) -> Double? {
        FixedChoices.pageZoomSteps.first { $0 > zoom + tolerance }
    }

    /// The next step below `zoom`, or nil at the smallest step.
    public static func zoomedOut(from zoom: Double) -> Double? {
        FixedChoices.pageZoomSteps.last { $0 < zoom - tolerance }
    }

    /// `zoom` as the whole percentage the page menu shows ("115%").
    public static func percent(_ zoom: Double) -> Int {
        Int((zoom * 100).rounded())
    }

    /// The nearest step, for a stored value that predates a change of steps.
    public static func nearestStep(to zoom: Double) -> Double {
        FixedChoices.pageZoomSteps.min { abs($0 - zoom) < abs($1 - zoom) } ?? actualSize
    }

    private static let tolerance = 0.001
}
