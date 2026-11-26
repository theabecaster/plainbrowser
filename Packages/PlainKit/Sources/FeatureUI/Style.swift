#if os(iOS)
import DesignSystem
import SwiftUI

/// The few style values the FeatureUI screens share. Colors come from `DesignSystem`.
enum Style {
    /// Lagoon Blue, the one accent color.
    static let accent = Color(uiColor: Palette.accent)
}

/// The sheet's one "Done" button. Uses `onDone` when the presenter gives one, else dismisses.
struct DoneButton: ToolbarContent {
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                if let onDone { onDone() } else { dismiss() }
            }
        }
    }
}
#endif
