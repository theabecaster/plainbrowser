#if os(iOS)
import SwiftUI

/// The History sheet: visits grouped by day, searchable, swipe a row to delete it, tap to open it.
///
/// `onOpen` gets the page to open; the presenter decides where and dismisses the sheet. In the
/// side pane (`isInPane`) there is nothing to dismiss: no Done button, the pane has its own close.
public struct HistoryView: View {
    @Bindable private var model: HistoryModel
    private let onOpen: (URL) -> Void
    private let onDone: (() -> Void)?
    private let isInPane: Bool
    @State private var pendingClear: HistoryClearRange?

    public init(model: HistoryModel, onOpen: @escaping (URL) -> Void, onDone: (() -> Void)? = nil, isInPane: Bool = false) {
        self.model = model
        self.onOpen = onOpen
        self.onDone = onDone
        self.isInPane = isInPane
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(model.days) { day in
                    Section(day.title) {
                        ForEach(day.rows) { row in
                            HistoryRowView(row: row) { open(row) }
                                .swipeActions {
                                    Button("Delete", role: .destructive) {
                                        Task { await model.delete(row) }
                                    }
                                }
                                .contextMenu {
                                    Button("Open", systemImage: "arrow.up.forward.app") { open(row) }
                                    Button("Copy Link", systemImage: "link") { copyLink(row.url) }
                                    Section {
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            Task { await model.delete(row) }
                                        }
                                    }
                                }
                                .onAppear { model.rowAppeared(row) }
                        }
                        .paperRows()
                    }
                }
            }
            .paperSheet()
            .overlay {
                if model.loadFailed {
                    ReadFailedView(message: Wording.historyReadFailed, systemImage: "clock") { await model.load() }
                } else if model.isLoaded, model.isEmpty {
                    if model.query.isEmpty {
                        ContentUnavailableView("Pages you visit show up here.", systemImage: "clock")
                    } else {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
            // Search sits under the title and scrolls away with the rows, as in Safari's history:
            // the bottom field's glass, and a field kept on screen (`.always`, which floats once the
            // bar hides on scroll), showed a ghost of the row behind it on paper.
            .searchable(
                text: $model.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search History"
            )
            // Rows scrolled under the field fade out at a hard edge instead of showing through it.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .sheetTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu("Clear…") {
                        Button("Last Hour") { pendingClear = .lastHour }
                        Button("Today") { pendingClear = .today }
                        Button("All History", role: .destructive) { pendingClear = .all }
                    }
                    // Dims only when history itself is empty, not when a search finds nothing.
                    .disabled(model.isLoaded && !model.hasHistory)
                }
                if !isInPane { DoneButton(onDone: onDone) }
            }
            .confirmationDialog(
                pendingClear.map(Self.confirmTitle) ?? "",
                isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } }),
                titleVisibility: .visible,
                presenting: pendingClear
            ) { range in
                Button(Self.confirmButton(range), role: .destructive) {
                    Task { await model.clear(range) }
                }
            }
            .alert(model.errorMessage ?? "", isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
        }
        .tint(Style.accent)
        .task { await model.load() }
    }

    private func open(_ row: HistoryRow) {
        model.opened(row)
        onOpen(row.url)
    }

    static func confirmTitle(_ range: HistoryClearRange) -> String {
        switch range {
        case .lastHour: "Clear the last hour of history?"
        case .today: "Clear today's history?"
        case .all: "Clear all history?"
        }
    }

    static func confirmButton(_ range: HistoryClearRange) -> String {
        switch range {
        case .lastHour: "Clear Last Hour"
        case .today: "Clear Today"
        case .all: "Clear All History"
        }
    }
}

struct HistoryRowView: View {
    let row: HistoryRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(row.address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text(row.visitedAt, format: .dateTime.hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(.rect)
        }
        .tint(.primary)
    }
}

#if DEBUG
#Preview("History") {
    HistoryView(model: PreviewData.historyModel(), onOpen: { _ in })
}
#endif
#endif
