#if os(iOS)
import SwiftUI

/// The Reading List sheet: pages saved to read later, unread first, then read ones, searchable.
/// Tap a row to open it (it is read from then on); swipe right to mark it read or unread, left to
/// delete it. A saved copy opens in the reader when the page can't load.
///
/// `onOpen` gets the page to open; the presenter decides where and dismisses the sheet.
public struct ReadingListView: View {
    @Bindable private var model: ReadingListModel
    private let onOpen: (URL) -> Void
    private let onDone: (() -> Void)?

    public init(model: ReadingListModel, onOpen: @escaping (URL) -> Void, onDone: (() -> Void)? = nil) {
        self.model = model
        self.onOpen = onOpen
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            List {
                if !model.unread.isEmpty {
                    Section {
                        rows(model.unread)
                    }
                }
                if !model.read.isEmpty {
                    Section("Read") {
                        rows(model.read)
                    }
                }
            }
            .paperSheet()
            .animation(.snappy(duration: 0.25), value: model.unread)
            .animation(.snappy(duration: 0.25), value: model.read)
            .overlay {
                if model.loadFailed {
                    ReadFailedView(message: Wording.readingListReadFailed, systemImage: "eyeglasses") { await model.load() }
                } else if model.isLoaded, model.isEmpty {
                    if model.query.isEmpty {
                        ContentUnavailableView(Wording.readingListEmpty, systemImage: "eyeglasses")
                    } else {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
            // As History: the field sits under the title and scrolls away with the rows.
            .searchable(
                text: $model.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search Reading List"
            )
            .scrollEdgeEffectStyle(.hard, for: .top)
            .sheetTitle("Reading List")
            .toolbar { DoneButton(onDone: onDone) }
            .alert(model.errorMessage ?? "", isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
        }
        .tint(Style.accent)
        .task { await model.load() }
    }

    private func rows(_ rows: [ReadingListRow]) -> some View {
        ForEach(rows) { row in
            ReadingListRowView(row: row) { open(row) }
                .swipeActions(edge: .leading) {
                    Button(row.isRead ? "Mark Unread" : "Mark Read", systemImage: row.isRead ? "eyeglasses" : "checkmark") {
                        model.toggleRead(row)
                    }
                    .tint(Style.accent)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { model.delete(row) }
                }
                .contextMenu {
                    Button("Open", systemImage: "arrow.up.forward.app") { open(row) }
                    Button(row.isRead ? "Mark as Unread" : "Mark as Read", systemImage: row.isRead ? "eyeglasses" : "checkmark") {
                        model.toggleRead(row)
                    }
                    Button("Copy Link", systemImage: "link") { copyLink(row.url) }
                    Section {
                        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(row) }
                    }
                }
        }
        .paperRows()
    }

    private func open(_ row: ReadingListRow) {
        model.opened(row)
        onOpen(row.url)
    }
}

struct ReadingListRowView: View {
    let row: ReadingListRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(row.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityIdentifier("readingListRow")
        .accessibilityValue(row.isRead ? "Read" : "Unread")
    }
}

#if DEBUG
#Preview("Reading List") {
    ReadingListView(model: PreviewData.readingListModel(), onOpen: { _ in })
}
#endif
#endif
