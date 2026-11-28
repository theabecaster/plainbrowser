#if canImport(UIKit)
import BrowserCore
import Foundation
import Intelligence

/// The on-device model's availability, for any screen that needs it outside a summary run: the
/// first-run intro (which shows before the browser and its `SummaryService` exist) and any later
/// screen that explains a switched-off feature. One check, one mapping (`AIAvailability`), one
/// Debug override (docs/decisions.md, "Apple Intelligence availability, shared").
public enum OnDeviceAI {
    /// A check that reads the system's answer each time it is called (off the main thread).
    ///
    /// Isolated runs get a fixed answer, so nothing depends on the Mac a simulator runs on: the
    /// Debug override `-PlainAIAvailability` (`AIAvailability.scripted`: one state per call, the
    /// last one kept), or else an ineligible phone. Each call of this function makes its own
    /// script, so two screens walk the states independently.
    public static func availabilityCheck(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> @MainActor () async -> AIAvailability {
        if TestIsolation.mode(for: arguments) != .off {
            #if DEBUG
            if let states = AIAvailability.scripted(arguments: arguments) {
                let script = ScriptedAvailability(states)
                return { script.next() }
            }
            #endif
            return { .deviceNotEligible }
        }
        return { await FoundationSummaryModel.currentAvailability() }
    }
}

#if DEBUG
/// The override's states, one per check; the last one stays.
@MainActor private final class ScriptedAvailability {
    private var states: [AIAvailability]

    init(_ states: [AIAvailability]) { self.states = states }

    func next() -> AIAvailability {
        states.count > 1 ? states.removeFirst() : states[0]
    }
}
#endif
#endif
