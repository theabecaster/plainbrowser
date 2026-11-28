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

    /// The icon picker shows only where the system lets the icon change, and never for an iPhone
    /// app on a Mac (its Dock icon can't change), whatever `supportsAlternateIcons` says there.
    @Test func iconPickerOnlyWhereTheIconCanChange() {
        #expect(AppIconSupport.isSupported(systemSupports: true, isiOSAppOnMac: false, arguments: []))
        #expect(!AppIconSupport.isSupported(systemSupports: false, isiOSAppOnMac: false, arguments: []))
        #expect(!AppIconSupport.isSupported(systemSupports: true, isiOSAppOnMac: true, arguments: []))
        #expect(!AppIconSupport.isSupported(systemSupports: false, isiOSAppOnMac: true, arguments: []))
        // The override needs an isolated run: a real launch can't be talked out of the system's answer.
        #expect(AppIconSupport.isSupported(systemSupports: true, isiOSAppOnMac: false, arguments: ["-PlainAlternateIcons", "off"]))
        #expect(!AppIconSupport.isSupported(systemSupports: false, isiOSAppOnMac: true, arguments: ["-PlainAlternateIcons", "on"]))
    }

    #if DEBUG
    @Test func iconPickerOverrideInIsolatedRuns() {
        let off = ["-PlainInMemoryStore", "-PlainAlternateIcons", "off"]
        #expect(!AppIconSupport.isSupported(systemSupports: true, isiOSAppOnMac: false, arguments: off))
        let on = ["-PlainTestStore", "-PlainAlternateIcons", "on"]
        #expect(AppIconSupport.isSupported(systemSupports: false, isiOSAppOnMac: true, arguments: on))
        // A missing or unknown value leaves the system's answer.
        #expect(AppIconSupport.isSupported(systemSupports: true, isiOSAppOnMac: false, arguments: ["-PlainInMemoryStore", "-PlainAlternateIcons"]))
        #expect(!AppIconSupport.isSupported(systemSupports: true, isiOSAppOnMac: true, arguments: ["-PlainInMemoryStore", "-PlainAlternateIcons", "maybe"]))
    }
    #endif

    #if os(iOS)
    /// Without the icon step the intro goes from "What's inside" straight to the blocking demo.
    @Test @MainActor func introLeavesOutTheIconStepWhereTheIconCannotChange() {
        #expect(IntroModel.initialSteps(defaultBrowserStep: false, iconStep: true) == [.promise, .inside, .icon, .blocking])
        #expect(IntroModel.initialSteps(defaultBrowserStep: false, iconStep: false) == [.promise, .inside, .blocking])
        #expect(IntroModel.initialSteps(defaultBrowserStep: true, iconStep: false) == [.promise, .inside, .blocking, .defaultBrowser])
        let model = IntroModel(defaultBrowserStep: false, iconStep: false, icon: .dawn)
        model.setAIAvailability(.available)
        #expect(model.steps == [.promise, .inside, .blocking, .browseForMe])
    }
    #endif
}
