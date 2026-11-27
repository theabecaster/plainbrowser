import Foundation
import Testing
@testable import FeatureUI

@Suite struct IntroGateTests {
    private func freshDefaults() -> UserDefaults {
        let name = "IntroGateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func showsOnceUntilSeen() {
        let defaults = freshDefaults()
        #expect(IntroGate.shouldShow(arguments: [], defaults: defaults))
        IntroGate.markSeen(defaults: defaults)
        #expect(!IntroGate.shouldShow(arguments: [], defaults: defaults))
    }

    /// Isolated runs (any build, Release perf runs included) skip the intro.
    @Test func isolatedRunsSkipIt() {
        let defaults = freshDefaults()
        #expect(!IntroGate.shouldShow(arguments: ["-PlainInMemoryStore"], defaults: defaults))
        #expect(!IntroGate.shouldShow(arguments: ["-PlainTestStore"], defaults: defaults))
    }

    #if DEBUG
    @Test func browserUITestsSkipItUnlessAsked() {
        let defaults = freshDefaults()
        #expect(IntroGate.shouldShow(arguments: ["-PlainInMemoryStore", "-PlainShowIntro"], defaults: defaults))
        #expect(IntroGate.shouldShow(arguments: ["-PlainTestStore", "-PlainRespectIntroSeen"], defaults: defaults))
        IntroGate.markSeen(defaults: defaults)
        #expect(IntroGate.shouldShow(arguments: ["-PlainShowIntro"], defaults: defaults))
        #expect(!IntroGate.shouldShow(arguments: ["-PlainTestStore", "-PlainRespectIntroSeen"], defaults: defaults))
    }

    @Test func defaultBrowserPromptsAreOffUntilTheEntitlement() {
        let defaults = freshDefaults()
        #expect(!DefaultBrowserPrompts.isEnabled(arguments: []))
        #expect(DefaultBrowserPrompts.isEnabled(arguments: ["-PlainForceDefaultBrowserPrompts"]))
        #expect(DefaultBrowserPrompts.showsEmptyTabCard(arguments: ["-PlainForceDefaultBrowserPrompts"], defaults: defaults))
        DefaultBrowserPrompts.dismissEmptyTabCard(defaults: defaults)
        #expect(!DefaultBrowserPrompts.showsEmptyTabCard(arguments: ["-PlainForceDefaultBrowserPrompts"], defaults: defaults))
    }
    #endif

    @Test func iconChoicesMatchTheAlternateIconNames() {
        #expect(AppIconChoice.dawn.alternateIconName == nil)
        #expect(AppIconChoice.allCases.compactMap(\.alternateIconName) == ["AppIcon-Night", "AppIcon-Coral", "AppIcon-Paper"])
        for choice in AppIconChoice.allCases {
            #expect(AppIconChoice(alternateIconName: choice.alternateIconName) == choice)
            #expect(choice.previewURL != nil, "missing preview for \(choice.rawValue)")
        }
        #expect(AppIconChoice(alternateIconName: "Unknown") == .dawn)
    }
}
