import BrowserCore
import DesignSystem

extension SummaryStage {
    /// The haptic a summary or Browse for Me run ends with, when it moves from `old` to this
    /// stage (haptics plan, §4.8): success the first time it is done, the warning the first time
    /// it fails, nothing for any other step. The user waited for it either way.
    public func outcomeHaptic(after old: SummaryStage) -> Haptic? {
        guard !old.isFinished else { return nil }
        switch self {
        case .done: return .success
        case .failed: return .failed
        case .searching, .reading, .writing: return nil
        }
    }
}
