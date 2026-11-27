#if os(iOS)
import SwiftUI

/// The Archive sheet: tabs Plain moved out of the way after the Archive Tabs interval, newest
/// first, searchable. Tap a row to bring the tab back; swipe to delete it for good.
public struct ArchiveView: View {
    @Bindable private var model: ArchiveModel
    private let onDone: (() -> Void)?
    private let footer: String

    /// - Parameter footer: one sentence on when tabs move here, from the Archive Tabs setting.
    public init(model: ArchiveModel, footer: String, onDone: (() -> Void)? = nil) {
        self.model = model
        self.footer = footer
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.rows) { row in
                        ArchiveRowView(row: row) { model.restore(row) }
                            .swipeActions {
                                Button("Delete", role: .destructive) { model.delete(row) }
                            }
                            .contextMenu {
                                Button("Open", systemImage: "arrow.up.forward.app") { model.restore(row) }
                                if let url = row.tab.entry.url {
                                    Button("Copy Link", systemImage: "link") { copyLink(url) }
                                }
                                Section {
                                    Button("Delete", systemImage: "trash", role: .destructive) { model.delete(row) }
                                }
                            }
                    }
                } footer: {
                    if !model.rows.isEmpty, model.query.isEmpty { Text(footer).foregroundStyle(.secondary) }
                }
                .paperRows()
            }
            .paperSheet()
            .overlay {
                if model.loadFailed {
                    ReadFailedView(message: Wording.archiveReadFailed, systemImage: "archivebox") { await model.load() }
                } else if model.isLoaded, model.rows.isEmpty {
                    if model.query.isEmpty {
                        PaperEmptyState(message: "No archived tabs.", systemImage: "archivebox", footer: footer)
                    } else {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
            // Search sits under the title and scrolls away with the rows, as in Safari's history:
            // the bottom field's glass, and a field kept on screen (`.always`, which floats once the
            // bar hides on scroll), showed a ghost of the row behind it on paper.
            .searchable(
                text: $model.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search Archive"
            )
            // Rows scrolled under the field fade out at a hard edge instead of showing through it.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .sheetTitle("Archived Tabs")
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
}

struct ArchiveRowView: View {
    let row: ArchiveRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !row.address.isEmpty {
                        Text(row.address)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(row.tab.archivedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityIdentifier("archiveRow")
    }
}
#endif
