import Foundation

/// The first-run intro's setup steps: features that need the user to set something up outside
/// Plain. Only Browse for Me qualifies today (docs/decisions.md, "Setup steps in the intro"); the
/// default-browser step waits behind `FixedChoices.defaultBrowserPromptsEnabled`.
public enum IntroSetup {
    /// What the intro's Browse for Me step asks of the user.
    public enum BrowseForMe: Sendable, Equatable {
        /// Apple Intelligence runs here: the step only shows the feature.
        case ready
        /// Apple Intelligence is off: one button opens Settings.
        case turnOn
        /// The model is downloading or preparing: the step says so and updates by itself.
        case gettingReady
    }

    /// The step for this availability, or nil when the step is left out: a phone that can't run
    /// Apple Intelligence, or a language its model doesn't read, has nothing the user can turn on.
    public static func browseForMe(_ availability: AIAvailability) -> BrowseForMe? {
        switch availability {
        case .available: .ready
        case .appleIntelligenceOff: .turnOn
        case .modelNotReady: .gettingReady
        case .deviceNotEligible, .unsupportedLanguage: nil
        }
    }
}
