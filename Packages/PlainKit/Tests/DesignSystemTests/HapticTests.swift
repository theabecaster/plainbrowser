import CoreGraphics
@testable import DesignSystem
import XCTest

/// The haptic gates (docs/research/haptics.md §3.1, §6.1): the throttle keeps the first of two
/// plays for one moment, refusals are rate-limited, suppression nests, prepare goes through once
/// per fire, and the threshold latch plays both ways with hysteresis. Platform-free, so these run
/// under `swift test` on macOS as well as on a simulator.
@MainActor
final class HapticTests: XCTestCase {
    private var clock: CFTimeInterval = 100
    private var played: [Haptic] = []

    override func setUp() async throws {
        clock = 100
        played = []
        Haptic.configure(.init())
        Haptic.resetGates()
        Haptic.now = { [unowned self] in clock }
        Haptic.recorder = { [unowned self] in played.append($0) }
    }

    override func tearDown() async throws {
        Haptic.recorder = nil
        Haptic.now = CACurrentMediaTime
        Haptic.resetGates()
    }

    private func play(_ kind: Haptic, after seconds: CFTimeInterval = 0) {
        clock += seconds
        _ = kind.admit()
    }

    func testRecorderSeesEachPlayInOrder() {
        play(.threshold)
        play(.selection, after: 0.2)
        XCTAssertEqual(played, [.threshold, .selection])
    }

    func testTwoPlaysInsideTheGapAreOneEventAndTheFirstWins() {
        play(.success)
        play(.selection, after: 0.03)
        XCTAssertEqual(played, [.success])
        play(.close, after: 0.031)
        XCTAssertEqual(played, [.success, .close], "61 ms after the first play is a new event")
    }

    func testADroppedPlayDoesNotExtendTheGap() {
        play(.threshold)
        play(.selection, after: 0.05)
        play(.close, after: 0.011)
        XCTAssertEqual(played, [.threshold, .close])
    }

    func testNothingThereIsRateLimitedToOncePerSecond() {
        play(.nothingThere)
        play(.nothingThere, after: 0.5)
        XCTAssertEqual(played, [.nothingThere])
        play(.nothingThere, after: 0.5)
        XCTAssertEqual(played, [.nothingThere, .nothingThere])
    }

    func testOtherKindsStillPlayInsideTheNothingThereGap() {
        play(.nothingThere)
        play(.tap, after: 0.1)
        XCTAssertEqual(played, [.nothingThere, .tap])
    }

    func testWithoutFeedbackSuppressesAndNests() {
        Haptic.withoutFeedback {
            play(.close)
            Haptic.withoutFeedback { play(.success, after: 0.1) }
            play(.tap, after: 0.1)
        }
        XCTAssertEqual(played, [])
        play(.drop, after: 0.1)
        XCTAssertEqual(played, [.drop])
    }

    func testSuppressedPlaysDoNotStartTheGap() {
        Haptic.withoutFeedback { play(.close) }
        play(.tap, after: 0.01)
        XCTAssertEqual(played, [.tap])
    }

    func testConfigureChangesTheGaps() {
        Haptic.configure(.init(minimumGap: 0.2, nothingThereGap: 3))
        play(.tap)
        play(.tap, after: 0.1)
        XCTAssertEqual(played, [.tap])
        Haptic.configure(.init())
    }

    func testEveryKindHasAName() {
        XCTAssertEqual(
            Haptic.allCases.map(\.rawValue),
            ["selection", "tap", "threshold", "drop", "close", "success", "failed", "nothingThere"]
        )
    }

    // MARK: prepare

    func testPrepareGoesThroughOnceUntilAFire() {
        var flag = PrepareFlag()
        XCTAssertTrue(flag.shouldPrepare(at: 0))
        XCTAssertFalse(flag.shouldPrepare(at: 0.016))
        XCTAssertFalse(flag.shouldPrepare(at: 1.5))
        flag.fired()
        XCTAssertTrue(flag.shouldPrepare(at: 1.6))
    }

    func testPrepareGoesThroughAgainAfterTheEngineIdles() {
        var flag = PrepareFlag()
        XCTAssertTrue(flag.shouldPrepare(at: 0))
        XCTAssertTrue(flag.shouldPrepare(at: PrepareFlag.lifetime))
    }

    // MARK: ThresholdLatch

    func testLatchArmsOnceAndDisarmsPastTheHysteresis() {
        var latch = ThresholdLatch(threshold: 80, hysteresis: 10)
        let frames: [CGFloat] = [10, 60, 79, 80, 95, 75, 71, 70, 69.5, 60, 80, 81]
        let haptics = frames.map { latch.update($0) }
        XCTAssertEqual(haptics, [nil, nil, nil, .threshold, nil, nil, nil, nil, .selection, nil, .threshold, nil])
        XCTAssertTrue(latch.isArmed)
    }

    func testLatchRestingOnTheLineNeverChatters() {
        var latch = ThresholdLatch(threshold: 0.5, hysteresis: 0.03)
        var haptics: [Haptic] = []
        for value in stride(from: 0.4, through: 0.6, by: 0.01) { if let h = latch.update(value) { haptics.append(h) } }
        for _ in 0..<20 {
            for value: CGFloat in [0.49, 0.51, 0.48, 0.5] { if let h = latch.update(value) { haptics.append(h) } }
        }
        XCTAssertEqual(haptics, [.threshold])
    }

    func testLatchResetStartsUnarmed() {
        var latch = ThresholdLatch(threshold: 10, hysteresis: 2)
        XCTAssertEqual(latch.update(20), .threshold)
        latch.reset()
        XCTAssertFalse(latch.isArmed)
        XCTAssertEqual(latch.update(20), .threshold)
    }

    func testLatchFollowsAMovingThreshold() {
        var latch = ThresholdLatch(threshold: 100, hysteresis: 10)
        XCTAssertNil(latch.update(90))
        latch.threshold = 80
        XCTAssertEqual(latch.update(90), .threshold)
    }
}
