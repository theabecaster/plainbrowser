#if os(iOS)
import DesignSystem
import SwiftUI

/// The few style values the FeatureUI screens share. Colors come from `DesignSystem`.
enum Style {
    /// Lagoon Blue, the one accent color: actions and checkmarks, a step deeper on paper so it
    /// reads as text.
    static let accent = Color(uiColor: Palette.accentOnPaper)
    /// Text on paper, and its supporting step.
    static let ink = Color(uiColor: Palette.ink)
    static let inkSecondary = Color(uiColor: Palette.inkSecondary)
    /// A card of rows, and the hairline between them.
    static let card = Color(uiColor: Palette.paperCard)
    static let hairline = Color(uiColor: Palette.paperHairline)
}

extension View {
    /// A sheet's list on Plain's paper: the textured ground behind it and ink text. Supporting
    /// text (footers, values, a row's address) asks for `.secondary`, which here is the ink's
    /// secondary step; the ink replaces the system's own footer gray, so each footer says so.
    /// Native in every other way. Put it on the `List` (or `ScrollView`); give the rows
    /// `paperRows()`.
    func paperSheet() -> some View {
        scrollContentBackground(.hidden)
            .background { PaperBackground().ignoresSafeArea() }
            // The floating search field (History, Archive) gets the system's hard edge, so rows
            // under it fade out instead of showing through its glass. No bar, no effect.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .foregroundStyle(Style.ink, Style.inkSecondary, Style.inkSecondary)
    }

    /// Rows on a lifted paper card with ink hairlines. Put it on the rows, a `ForEach` or a
    /// `Section`: one flat color per row, no texture or shadow, so lists scroll at full rate.
    func paperRows() -> some View {
        listRowBackground(Style.card)
            .listRowSeparatorTint(Style.hairline)
            .listSectionSeparatorTint(Style.hairline)
    }

    /// The sheet's inline title, set in New York like the intro's headlines. `navigationTitle`
    /// stays for the back button and VoiceOver; the bar shows the serif one, centered.
    func sheetTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: title)
                }
            }
    }
}

/// A sheet's title in the bar: New York, semibold, at the bar title's size. Grows with Dynamic Type
/// up to the point where the bar would crowd its buttons, as the system title does.
private struct SheetTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.headline, design: .serif))
            .foregroundStyle(Style.ink)
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A row's title and its current value ("Search Engine", "Google"): `LabeledContent` with the value
/// in the ink's secondary step, since the sheet's ink would otherwise flatten it to the title's.
struct ValueLabel: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value).foregroundStyle(.secondary)
        } label: {
            Text(title)
        }
    }
}

/// A read that failed, in place of the list: one sentence and Try Again (docs/state-rules.md §6,
/// Sheets). Never the empty state.
struct ReadFailedView: View {
    let message: String
    let systemImage: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(message, systemImage: systemImage)
        } actions: {
            Button("Try Again") { Task { await retry() } }
                .accessibilityIdentifier("sheetTryAgain")
        }
    }
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
