#if os(iOS)
import Storage
import SwiftUI

/// The Favorites sheet: tap a favorite to open it, as people expect of a list of pages (clarity
/// audit 7). Rename and Delete are a swipe away and in the row's menu (touch and hold); Edit
/// shows the reorder handles and the delete buttons.
///
/// `onOpen` gets the page to open; the presenter decides where and dismisses the sheet.
public struct FavoritesEditor: View {
    @Bindable private var model: FavoritesModel
    private let onOpen: (URL) -> Void
    private let onDone: (() -> Void)?
    @State private var renaming: Favorite?
    @State private var newTitle = ""
    @State private var editMode: EditMode

    /// - Parameter startsEditing: opens with the reorder handles showing (from "Edit Favorites"
    ///   on the favorites above the keyboard).
    public init(
        model: FavoritesModel, startsEditing: Bool = false, onOpen: @escaping (URL) -> Void = { _ in },
        onDone: (() -> Void)? = nil
    ) {
        self.model = model
        self.onOpen = onOpen
        self.onDone = onDone
        _editMode = State(initialValue: startsEditing ? .active : .inactive)
    }

    private var isEditing: Bool { editMode.isEditing }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.favorites, id: \.id) { favorite in
                        row(favorite)
                    }
                    .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { model.delete(atOffsets: $0) }
                } footer: {
                    if !model.favorites.isEmpty { Text(Wording.favoritesFooter).foregroundStyle(.secondary) }
                }
                .paperRows()
            }
            .environment(\.editMode, $editMode)
            .animation(.snappy(duration: 0.25), value: isEditing)
            .paperSheet()
            .overlay {
                if model.loadFailed {
                    ReadFailedView(message: Wording.favoritesReadFailed, systemImage: "star") { await model.load() }
                } else if model.isLoaded, model.favorites.isEmpty {
                    PaperEmptyState(message: Wording.favoritesEmpty, systemImage: "star", symbolMessage: Wording.favoritesEmptySymbol)
                }
            }
            .sheetTitle("Favorites") {
                if !isEditing, !model.favorites.isEmpty {
                    Button("Edit") { editMode = .active }
                        .buttonStyle(SheetHeaderButtonStyle())
                        .accessibilityHint("Shows the handles to reorder and delete favorites")
                }
            } trailing: {
                if isEditing {
                    // Ends the editing, not the sheet: the sheet's own Done comes back after.
                    Button("Done") { editMode = .inactive }
                        .buttonStyle(SheetHeaderButtonStyle(font: .headline))
                } else {
                    SheetDone(onDone: onDone)
                }
            }
            .onChange(of: model.favorites.isEmpty) { _, isEmpty in
                if isEmpty { editMode = .inactive }
            }
            .alert("Rename Favorite", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } }
            ), presenting: renaming) { favorite in
                TextField("Name", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { model.rename(favorite, to: newTitle) }
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

    private func row(_ favorite: Favorite) -> some View {
        Button {
            onOpen(favorite.url)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(FavoritesModel.displayTitle(favorite))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(HistoryModel.displayAddress(favorite.url))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityIdentifier("favoriteRow")
        .accessibilityHint("Opens this page")
        .swipeActions(edge: .leading) {
            Button("Rename", systemImage: "pencil") { rename(favorite) }
                .tint(Style.accent)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { delete(favorite) }
                .tint(Style.destructive)
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.app") { onOpen(favorite.url) }
            Button("Rename", systemImage: "pencil") { rename(favorite) }
            Button("Copy Link", systemImage: "link") { copyLink(favorite.url) }
            Section {
                Button("Delete", systemImage: "trash", role: .destructive) { delete(favorite) }
            }
        }
    }

    private func rename(_ favorite: Favorite) {
        newTitle = FavoritesModel.displayTitle(favorite)
        renaming = favorite
    }

    private func delete(_ favorite: Favorite) {
        guard let index = model.favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
        model.delete(atOffsets: IndexSet(integer: index))
    }
}

#if DEBUG
#Preview("Favorites") {
    FavoritesEditor(model: PreviewData.favoritesModel())
}
#endif
#endif
