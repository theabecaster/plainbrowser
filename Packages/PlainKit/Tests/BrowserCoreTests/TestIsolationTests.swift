import Foundation
import Testing
@testable import BrowserCore

@Suite struct TestIsolationTests {
    @Test func modeFromArguments() {
        #expect(TestIsolation.mode(for: []) == .off)
        #expect(TestIsolation.mode(for: ["-PlainIntroSeen", "YES"]) == .off)
        #expect(TestIsolation.mode(for: ["-PlainInMemoryStore"]) == .inMemory)
        #expect(TestIsolation.mode(for: ["-PlainTestStore"]) == .testStore)
        // The test store wins: UI tests of session restore add it to the in-memory default.
        #expect(TestIsolation.mode(for: ["-PlainInMemoryStore", "-PlainTestStore", "-PlainResetStore"]) == .testStore)
    }

    /// `swift test` runs with no Plain arguments: the real paths and standard defaults.
    @Test func offWithoutArguments() {
        #expect(TestIsolation.mode == .off)
        #expect(!TestIsolation.isActive)
        #expect(TestIsolation.directory == nil)
        #expect(TestIsolation.folder("Downloads") == nil)
        #expect(TestIsolation.defaults === UserDefaults.standard)
    }
}
