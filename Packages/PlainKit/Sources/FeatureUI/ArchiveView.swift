#if os(iOS)
import SwiftUI

/// The Archive sheet: tabs Plain moved out of the way after the Archive Tabs interval, newest
/// first in sections by when they moved (Today, Yesterday, This Week, Earlier), searchable. Tap a
/// row to bring the tab back; swipe to delete it for good. They leave by themselves after 30 days.
public struct ArchiveView: View {
    @Bindable private var model: ArchiveModel
    private let onDone: (() -> Void)?
    private let footer: String

    /// - Parameter footer: one sentence on when tabs move here and leave, from the Archive Tabs
    ///   setting (`ArchiveAfter.archiveFooter`).
    public init(model: ArchiveModel, footer: String, onDone: (() -> Void)? = nil) {
        self.model = model
        self.footer = footer
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            List {
                SheetSearchRow(prompt: "Search Archive", text: $model.query)
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            ArchiveRowView(row: row, period: section.period) { model.restore(row) }
                                .swipeActions {
                                    Button("Delete", role: .destructive) { model.delete(row) }
                                        .tint(Style.destructive)
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
                    } header: {
                        Text(section.title)
                    } footer: {
                        // Once, under the oldest section: when tabs come here and when they leave.
                        if section.id == model.sections.last?.id, model.query.isEmpty {
                            Text(footer).foregroundStyle(.secondary)
                        }
                    }
                    .paperRows()
                }
            }
            .paperSheet()
            .overlay {
                if model.loadFailed {
                    ReadFailedView(message: Wording.archiveReadFailed, systemImage: "archivebox") { await model.load() }
                } else if model.isLoaded, model.isEmpty {
                    if model.query.isEmpty {
                        PaperEmptyState(message: "No archived tabs.", systemImage: "archivebox", footer: footer)
                    } else {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
            .sheetTitle("Archived Tabs", onDone: onDone)
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
    let period: ArchivePeriod
    let open: () -> Void

    /// When it moved here, in the section's terms (like History's times): a time today and
    /// yesterday, the weekday this week, the date before that.
    private var archived: String {
        let date = row.tab.archivedAt
        return switch period {
        case .today, .yesterday: date.formatted(.dateTime.hour().minute())
        case .thisWeek: date.formatted(.dateTime.weekday(.wide))
        case .earlier: date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    var body: some View {
        Button(action: open) {
            TimedRowLabel(title: row.title, detail: row.address, time: archived)
                .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityIdentifier("archiveRow")
    }
}
#endif
