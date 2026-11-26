#if os(iOS)
import Storage
import SwiftUI

/// The favorites editor sheet: drag to reorder, tap to rename, delete with the minus button or a
/// swipe.
public struct FavoritesEditor: View {
    @Bindable private var model: FavoritesModel
    private let onDone: (() -> Void)?
    @State private var renaming: Favorite?
    @State private var newTitle = ""

    public init(model: FavoritesModel, onDone: (() -> Void)? = nil) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(model.favorites, id: \.id) { favorite in
                    Button {
                        newTitle = FavoritesModel.displayTitle(favorite)
                        renaming = favorite
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FavoritesModel.displayTitle(favorite))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(HistoryModel.displayAddress(favorite.url))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .tint(.primary)
                    .accessibilityHint("Renames this favorite")
                }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { model.delete(atOffsets: $0) }
            }
            .environment(\.editMode, .constant(.active))
            .overlay {
                if model.isLoaded, model.favorites.isEmpty {
                    ContentUnavailableView("Add favorites from the page menu.", systemImage: "star")
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton(onDone: onDone) }
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
}

#if DEBUG
#Preview("Favorites") {
    FavoritesEditor(model: PreviewData.favoritesModel())
}
#endif
#endif
