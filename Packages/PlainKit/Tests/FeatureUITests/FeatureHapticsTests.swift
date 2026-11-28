import BrowserCore
import DesignSystem
@testable import FeatureUI
import Foundation
import Storage
import Testing

/// The haptics the Settings and History models play (docs/research/haptics.md §4.10). Suites run
/// in parallel, so each test reads only the haptics its own task played (a task-local probe), and
/// the throttle is off: another test's play must not swallow this one's.
@MainActor
final class HapticProbe {
    @TaskLocal static var current: HapticProbe?
    private(set) var kinds: [Haptic] = []

    static func run(_ body: () async throws -> Void) async rethrows -> [Haptic] {
        Haptic.configure(.init(minimumGap: 0, nothingThereGap: 0))
        Haptic.recorder = { kind in HapticProbe.current?.kinds.append(kind) }
        let probe = HapticProbe()
        try await $current.withValue(probe) { try await body() }
        return probe.kinds
    }
}

@MainActor
@Suite struct FeatureHapticsTests {
    @Test func searchEngineTicksOnlyWhenTheCheckmarkMoves() async throws {
        let model = SettingsModel(store: try AppDatabase.inMemory(), clearer: RecordingClearer(), about: testAbout)
        await model.load()
        let kinds = await HapticProbe.run {
            model.selectSearchEngine(.duckDuckGo)
            model.selectSearchEngine(.duckDuckGo)
            model.selectSearchEngine(.kagi)
        }
        #expect(kinds == [.selection, .selection])
    }

    @Test func customEngineTicksWhenValidAndBumpsWhenNot() async throws {
        let model = SettingsModel(store: try AppDatabase.inMemory(), clearer: RecordingClearer(), about: testAbout)
        await model.load()
        let kinds = await HapticProbe.run {
            model.customTemplate = "not a url %s"
            _ = model.useCustomTemplate()
            model.customTemplate = "search.example.com/find?q=%s"
            _ = model.useCustomTemplate()
        }
        #expect(kinds == [.nothingThere, .selection])
    }

    @Test func clearHistoryAndDataSucceedsOnceAndFailsSilently() async throws {
        let model = SettingsModel(store: try AppDatabase.inMemory(), clearer: RecordingClearer(), about: testAbout)
        let succeeded = await HapticProbe.run { await model.clearHistoryAndData() }
        #expect(succeeded == [.success])

        let failing = SettingsModel(store: try AppDatabase.inMemory(), clearer: FailingClearer(), about: testAbout)
        let failed = await HapticProbe.run { await failing.clearHistoryAndData() }
        #expect(failed == [], "the alert is the feedback")
    }

    @Test func historyClearSucceedsAfterTheRowsAreGone() async {
        let model = HistoryModel(store: FakeHistory(HistoryModelTests.sample), now: { HistoryModelTests.now },
                                 calendar: HistoryModelTests.calendar, locale: Locale(identifier: "en_US"))
        await model.load()
        let kinds = await HapticProbe.run { await model.clear(.all) }
        #expect(kinds == [.success])
        #expect(model.days.isEmpty)
    }

    @Test func historyClearFailureIsSilent() async {
        let model = HistoryModel(store: UnclearableHistory(), now: { HistoryModelTests.now },
                                 calendar: HistoryModelTests.calendar, locale: Locale(identifier: "en_US"))
        let kinds = await HapticProbe.run { await model.clear(.all) }
        #expect(kinds == [])
    }
}

/// History whose clear always fails.
private actor UnclearableHistory: HistoryStoring {
    func visits(matching query: String, limit: Int) async throws -> [HistoryVisit] { [] }
    func deleteHistory(for url: URL) async throws {}
    func clearHistory(since start: Date?) async throws { throw URLError(.cannotRemoveFile) }
}
