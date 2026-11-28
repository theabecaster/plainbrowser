#if os(iOS)
import DesignSystem
import PerfSignposts
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

/// Copy Link from a row's menu: the link on the pasteboard and the success haptic, as the page
/// menu's Copy Link does (it leaves nothing else on screen).
@MainActor
func copyLink(_ url: URL) {
    Signposts.signposter.emitEvent(Signposts.copyLink, "sheet")
    UIPasteboard.plain.url = url
    Haptic.success.play()
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
            .foregroundStyle(Style.ink, Style.inkSecondary, Style.inkSecondary)
    }

    /// Rows on a lifted paper card with ink hairlines. Put it on the rows, a `ForEach` or a
    /// `Section`: one flat color per row, no texture or shadow, so lists scroll at full rate.
    func paperRows() -> some View {
        listRowBackground(Style.card)
            .listRowSeparatorTint(Style.hairline)
            .listSectionSeparatorTint(Style.hairline)
    }

    /// A sheet's first screen: its title, Done and an optional leading control in a header pinned
    /// above the list. Not the navigation bar: at a compact height (the Duo's outer screen) the
    /// system hides a sheet's bar as the list scrolls, and the title and Done went with it;
    /// asking for a visible bar (`toolbarVisibility(.visible)`) did not keep it (lead's call,
    /// 2026-11-27). `navigationTitle` stays for VoiceOver and the pushed screens. Without
    /// `onDone` Done dismisses the sheet.
    func sheetTitle(_ title: String, onDone: (() -> Void)?, @ViewBuilder leading: () -> some View) -> some View {
        modifier(SheetHeaderModifier(title: title, leading: leading(), trailing: SheetDone(onDone: onDone)))
    }

    /// The pinned header with both sides given: a sheet whose trailing button changes with its
    /// state (Favorites while editing: Done ends the editing, not the sheet).
    func sheetTitle(_ title: String, @ViewBuilder leading: () -> some View, @ViewBuilder trailing: () -> some View) -> some View {
        modifier(SheetHeaderModifier(title: title, leading: leading(), trailing: trailing()))
    }

    /// The same, with nothing on the leading side.
    func sheetTitle(_ title: String, onDone: (() -> Void)?) -> some View {
        sheetTitle(title, onDone: onDone) { EmptyView() }
    }

    /// A screen pushed inside a sheet: the same pinned header with Back in place of Done.
    func sheetTitle(_ title: String) -> some View {
        modifier(SheetHeaderModifier(title: title, leading: SheetBack(), trailing: EmptyView()))
    }
}

private struct SheetHeaderModifier<Leading: View, Trailing: View>: ViewModifier {
    let title: String
    let leading: Leading
    let trailing: Trailing

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: title, leading: leading, trailing: trailing)
            }
    }
}

/// The pinned header: the title in New York, semibold, at the bar title's size, centered between
/// the two sides. It grows with Dynamic Type up to the point where it would crowd the buttons, as
/// the system title does. Opaque paper, so rows scroll under it out of sight.
struct SheetHeader<Leading: View, Trailing: View>: View {
    let title: String
    let leading: Leading
    let trailing: Trailing

    var body: some View {
        // Each side takes the same share of the width, so the title stays centered whatever the
        // two sides hold, and takes the room left before it truncates.
        HStack(spacing: 8) {
            ZStack { Color.clear.frame(height: 1); side(leading) }.frame(maxWidth: .infinity, alignment: .leading)
            Text(title)
                .font(.system(.headline, design: .serif))
                .foregroundStyle(Style.ink)
                .lineLimit(1)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityAddTraits(.isHeader)
                .layoutPriority(1)
            ZStack { Color.clear.frame(height: 1); side(trailing) }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background { PaperBackground().ignoresSafeArea(edges: [.top, .horizontal]) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Style.hairline).frame(height: 0.5)
        }
    }

    /// A side's buttons keep one line at their full width and stop growing where the title does;
    /// the title truncates first. At the accessibility sizes Done wrapped a letter or two per
    /// line ("D / on / e") beside "Archived Tabs".
    private func side(_ content: some View) -> some View {
        content
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .fixedSize()
    }
}

/// A list row's text: the title, the address under it and when, at the trailing end. From the
/// first accessibility text size the time goes under the address and the title may take two
/// lines: beside a large time the title was cut to a word ("The Verg…", clarity audit 14).
struct TimedRowLabel: View {
    let title: String
    let detail: String
    let time: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary).lineLimit(2)
                if !detail.isEmpty { detailText }
                timeText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    if !detail.isEmpty { detailText }
                }
                Spacer(minLength: 0)
                timeText
            }
        }
    }

    private var detailText: some View {
        Text(detail)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var timeText: some View {
        Text(time)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

/// Done, in the header's trailing corner.
struct SheetDone: View {
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("Done") {
            if let onDone { onDone() } else { dismiss() }
        }
        .buttonStyle(.glass)
        .foregroundStyle(Style.accent)
    }
}

/// Back, on a pushed screen.
private struct SheetBack: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Label("Back", systemImage: "chevron.backward").labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .foregroundStyle(Style.accent)
        .accessibilityIdentifier("BackButton")
    }
}

/// A list's search field as its first row, under the pinned header: it scrolls away with the
/// rows, as in Safari's history (docs/decisions.md, "Search field"). Put it first in the `List`.
struct SheetSearchRow: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityAddTraits(.isSearchField)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Label("Clear", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        // A step darker than the cards, as the system's search field is: it reads as a field.
        .background(Style.ink.opacity(0.07), in: Capsule())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
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

/// A sheet's empty state on paper (docs/state-rules.md §6, Sheets): the symbol and one sentence
/// in the ink's secondary step, body text, as the start screen's sentence. The system's
/// `ContentUnavailableView` sets the sentence as a bold black title, which nothing else in Plain
/// uses. An optional footer is one more quiet line under it.
struct PaperEmptyState: View {
    let message: String
    let systemImage: String
    var footer: String?
    /// The sentence with a symbol in it (the More button, as the bar draws it), shown in place of
    /// `message`, which VoiceOver then reads.
    var symbolMessage: Text?

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(Style.inkSecondary)
                .accessibilityHidden(true)
                .padding(.bottom, Spacing.xs)
            (symbolMessage ?? Text(message))
                .font(.body)
                .foregroundStyle(Style.inkSecondary)
                .accessibilityLabel(message)
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(Style.inkSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sheetEmptyState")
    }
}

/// The empty states that point at the page sheet show its button, More, as the bar draws it:
/// a first-time user knows the button by its picture, and nothing on screen is called "the page
/// menu".
extension Wording {
    private static var more: Image { Image(systemName: "line.3.horizontal.circle") }
    static var favoritesEmptySymbol: Text { Text("Tap \(more) on a page, then Favorite.") }
    static var readingListEmptySymbol: Text { Text("Tap \(more) on a page, then Read Later.") }
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

#endif
