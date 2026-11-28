import BrowserCore
import DesignSystem
import XCTest

/// DesignSystem can't see FixedChoices, so `Haptic.Timing` repeats its values as defaults; the
/// scene configures them from FixedChoices. This keeps the two from drifting.
@MainActor
final class HapticTimingTests: XCTestCase {
    func testTimingDefaultsEqualTheFixedChoices() {
        let timing = Haptic.Timing()
        XCTAssertEqual(timing.minimumGap, FixedChoices.hapticMinimumGap)
        XCTAssertEqual(timing.nothingThereGap, FixedChoices.hapticNothingThereGap)
    }
}
