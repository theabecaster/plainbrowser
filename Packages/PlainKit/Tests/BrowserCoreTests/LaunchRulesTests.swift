@testable import BrowserCore
import Foundation
import Testing

/// docs/state-rules.md, "Launch and return".
@Suite struct LaunchRulesTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func hint(awayFor seconds: TimeInterval) -> LaunchHint {
        LaunchHint(tabID: UUID(), windowID: UUID(), url: URL(string: "https://example.com")!, leftAt: now.addingTimeInterval(-seconds))
    }

    @Test func noTabOpensToSearch() {
        #expect(LaunchRules.opening(hint: nil, now: now) == .search)
    }

    @Test func shortAbsenceOpensTheLastTab() {
        #expect(LaunchRules.opening(hint: hint(awayFor: 0), now: now) == .lastTab)
        #expect(LaunchRules.opening(hint: hint(awayFor: 3 * 3600 + 3599), now: now) == .lastTab)
    }

    @Test func longAbsenceOpensSearchOverTheLastTab() {
        #expect(LaunchRules.opening(hint: hint(awayFor: 4 * 3600), now: now) == .searchOverLastTab)
        #expect(LaunchRules.opening(hint: hint(awayFor: 9 * 24 * 3600), now: now) == .searchOverLastTab)
    }

    @Test func clockGoingBackwardsIsAShortAbsence() {
        #expect(LaunchRules.opening(hint: hint(awayFor: -3600), now: now) == .lastTab)
    }

    @Test func returnAfterAShortAbsenceChangesNothing() {
        let leftAt = now.addingTimeInterval(-600)
        #expect(LaunchRules.onReturn(awayFrom: leftAt, now: now, showsPage: true, isOccupied: false) == nil)
    }

    @Test func returnAfterALongAbsence() {
        let leftAt = now.addingTimeInterval(-5 * 3600)
        #expect(LaunchRules.onReturn(awayFrom: leftAt, now: now, showsPage: true, isOccupied: false) == .searchOverLastTab)
        #expect(LaunchRules.onReturn(awayFrom: leftAt, now: now, showsPage: false, isOccupied: false) == .search)
        // The gallery, a sheet, the open field or a busy page: left alone.
        #expect(LaunchRules.onReturn(awayFrom: leftAt, now: now, showsPage: true, isOccupied: true) == nil)
    }

    @Test func hintRoundTrips() throws {
        let original = LaunchHint(
            tabID: UUID(), windowID: UUID(), picture: "a.jpg", url: URL(string: "http://example.com/a?b=c")!, leftAt: now, canGoBack: true,
            canGoForward: false, others: 3, notSecure: true
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(LaunchHint.self, from: data) == original)
    }
}
