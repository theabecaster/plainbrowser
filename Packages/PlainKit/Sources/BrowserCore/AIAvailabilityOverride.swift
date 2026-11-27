import Foundation

// The on-device model's availability, as every screen reads it (docs/decisions.md, "Apple
// Intelligence availability, shared"): ShellUI's `OnDeviceAI.availabilityCheck()` is the one
// check for screens that come before or outside the browser (the intro), and `SummaryService`
// keeps the browser's answer. Both map the system's reasons to `AIAvailability` (Summaries.swift).

extension AIAvailability {
    /// The Debug launch override: `-PlainAIAvailability off,available` answers each check with
    /// the next state and keeps the last one. Honored only in Debug builds and isolated runs
    /// (`TestIsolation`), so a UI test can walk every state on any simulator, whatever the Mac's
    /// own Apple Intelligence says.
    public static let overrideArgument = "-PlainAIAvailability"

    /// The states the override lists, in order, or nil when it is missing or names an unknown
    /// state. Names: available, off, notReady, notEligible, unsupportedLanguage.
    public static func scripted(arguments: [String]) -> [AIAvailability]? {
        guard let index = arguments.firstIndex(of: overrideArgument), index + 1 < arguments.count else { return nil }
        let names = arguments[index + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let states = names.compactMap(AIAvailability.init(scriptName:))
        guard !states.isEmpty, states.count == names.count else { return nil }
        return states
    }

    init?(scriptName: String) {
        switch scriptName {
        case "available": self = .available
        case "off": self = .appleIntelligenceOff
        case "notReady": self = .modelNotReady
        case "notEligible": self = .deviceNotEligible
        case "unsupportedLanguage": self = .unsupportedLanguage
        default: return nil
        }
    }
}
