import Foundation
import Observation
import PerfSignposts
import Storage

/// State for the favorites editor: reorder, rename and delete. The list changes at once and the
/// store catches up in order; if a write fails, the list reloads from the store.
@Observable
public final class FavoritesModel {
    public private(set) var favorites: [Favorite] = []
    public private(set) var isLoaded = false
    public var errorMessage: String?

    private let store: any FavoritesStoring
    private let writes = WriteQueue()
    /// Bumped by every edit, so a read that started before an edit is not applied over it.
    private var edits = 0

    public init(store: any FavoritesStoring) {
        self.store = store
    }

    public func load() async {
        let editsAtStart = edits
        do {
            let stored = try await store.favorites()
            // An edit made while reading is newer than what was read.
            if edits == editsAtStart { favorites = stored }
        } catch {
            errorMessage = Wording.favoritesFailed
        }
        isLoaded = true
    }

    /// The name shown for a favorite: its title, or its address when it has none.
    public static func displayTitle(_ favorite: Favorite) -> String {
        if let title = favorite.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return HistoryModel.displayAddress(favorite.url)
    }

    /// Moves rows the way `List`'s `onMove` reports it.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let before = favorites.map(\.id)
        // What `List`'s `onMove` means: the rows at `source`, in order, land before the row that
        // was at `destination`.
        let moving = source.map { favorites[$0] }
        let insertAt = destination - source.count(in: 0..<destination)
        favorites = favorites.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        favorites.insert(contentsOf: moving, at: insertAt)
        let after = favorites.map(\.id)
        // Place every favorite from the first changed index down, top to bottom. Each move only
        // shifts rows below the one placed, so the rows above stay put and the store ends in
        // exactly this order. Favorites are a short list, and a single drag usually changes a few.
        guard let first = before.indices.first(where: { before[$0] != after[$0] }),
              let last = before.indices.last(where: { before[$0] != after[$0] })
        else { return }
        let targets = (first...last).compactMap { index in after[index].map { ($0, index) } }
        let store = store
        persist {
            for (id, index) in targets {
                try await store.moveFavorite(id: id, to: index)
            }
        }
    }

    public func delete(atOffsets offsets: IndexSet) {
        let ids = offsets.compactMap { favorites[$0].id }
        favorites = favorites.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let store = store
        persist {
            for id in ids {
                try await store.removeFavorite(id: id)
            }
        }
    }

    /// Renames a favorite. An empty name is ignored.
    public func rename(_ favorite: Favorite, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let id = favorite.id,
              let index = favorites.firstIndex(where: { $0.id == id }),
              favorites[index].title != title
        else { return }
        favorites[index].title = title
        let store = store
        persist { try await store.renameFavorite(id: id, title: title) }
    }

    private func persist(_ operation: @escaping @Sendable () async throws -> Void) {
        edits += 1
        Signposts.signposter.emitEvent(Signposts.favoritesEdit)
        writes.enqueue(operation) { [weak self] _ in
            guard let self else { return }
            errorMessage = Wording.favoritesFailed
            // Re-read through the write queue, after every write queued so far, so the list
            // shows what is stored. An edit made after the failure wins over the re-read.
            writes.enqueue({ [weak self] in await self?.reloadAfterFailure() }, onError: { _ in })
        }
    }

    private func reloadAfterFailure() async {
        let editsAtStart = edits
        guard let stored = try? await store.favorites(), edits == editsAtStart else { return }
        favorites = stored
    }

    /// Returns when every change so far is saved.
    func waitForSaves() async {
        await writes.drain()
    }
}
