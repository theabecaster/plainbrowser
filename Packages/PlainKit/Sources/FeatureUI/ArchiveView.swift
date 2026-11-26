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
                                    Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
                                }
                                Section {
                                    Button("Delete", systemImage: "trash", role: .destructive) { model.delete(row) }
                                }
                            }
                    }
                } footer: {
                    if !model.rows.isEmpty, model.query.isEmpty { Text(footer) }
                }
            }
            .overlay {
                if model.isLoaded, model.rows.isEmpty {
                    if model.query.isEmpty {
                        ContentUnavailableView {
                            Label("No archived tabs.", systemImage: "archivebox")
                        } description: {
                            Text(footer)
                        }
                    } else {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
            .searchable(text: $model.query, prompt: "Search Archive")
            .navigationTitle("Archived Tabs")
            .navigationBarTitleDisplayMode(.inline)
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
