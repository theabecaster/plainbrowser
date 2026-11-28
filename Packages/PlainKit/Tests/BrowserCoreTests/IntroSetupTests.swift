@testable import BrowserCore
import Foundation
import Testing

/// The intro's Browse for Me step: which availability shows it, with which action, and the Debug
/// override its UI tests use.
@Suite struct IntroSetupTests {
    @Test func stepFollowsAvailability() {
        #expect(IntroSetup.browseForMe(.available) == .ready)
        #expect(IntroSetup.browseForMe(.appleIntelligenceOff) == .turnOn)
        #expect(IntroSetup.browseForMe(.modelNotReady) == .gettingReady)
        // Nothing the user could turn on: the step is left out.
        #expect(IntroSetup.browseForMe(.deviceNotEligible) == nil)
        #expect(IntroSetup.browseForMe(.unsupportedLanguage) == nil)
    }

    @Test func overrideListsStatesInOrder() {
        #expect(AIAvailability.scripted(arguments: ["-PlainAIAvailability", "off,available"])
            == [.appleIntelligenceOff, .available])
        #expect(AIAvailability.scripted(arguments: ["-X", "-PlainAIAvailability", "notReady"]) == [.modelNotReady])
        #expect(AIAvailability.scripted(arguments: ["-PlainAIAvailability", "notEligible"]) == [.deviceNotEligible])
    }

    @Test func overrideRefusesUnknownOrMissingStates() {
        #expect(AIAvailability.scripted(arguments: []) == nil)
        #expect(AIAvailability.scripted(arguments: ["-PlainAIAvailability"]) == nil)
        #expect(AIAvailability.scripted(arguments: ["-PlainAIAvailability", "off,sometimes"]) == nil)
    }
}
