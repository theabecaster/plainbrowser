import BrowserCore
import Foundation

/// Where each profile but Personal keeps its history, favorites and typed-input learning: a
/// database of its own in `Profiles/<id>/` beside the main one. Deleting a profile deletes that
/// folder, so nothing of it can linger in Personal's database, and no history query needs a
/// profile filter. Personal keeps the main database (the data Plain had before profiles).
///
/// The profile databases use the main one's schema; their tab tables stay empty, since tabs and
/// the archive of every profile live in the main database with the profile list.
public struct ProfileDataLocation: Sendable {
    /// The main database's folder, or nil to keep every profile's data in memory (tests and an
    /// in-memory isolated run).
    public let directory: URL?

    public init(directory: URL?) {
        self.directory = directory
    }

    /// The folder of `id`'s data; nil in memory.
    public func folder(for id: ProfileID) -> URL? {
        directory?.appending(path: "Profiles", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Opens (or creates) `id`'s database, off the caller's actor. Never Personal's: that is the
    /// main database.
    @concurrent
    public func open(_ id: ProfileID) async throws -> AppDatabase {
        precondition(id != Profile.defaultID, "Personal's data is the main database")
        guard let folder = folder(for: id) else { return try AppDatabase.inMemory() }
        return try await AppDatabase.open(at: folder.appending(path: "Plain.sqlite"))
    }

    /// Deletes `id`'s data for good. The caller has flushed and released its database first.
    @concurrent
    public func remove(_ id: ProfileID) async {
        guard id != Profile.defaultID, let folder = folder(for: id) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The profiles that have data on disk. The caller removes those no longer in its profile
    /// list (a deletion the app could not finish), checking the list after this returns.
    @concurrent
    public func storedProfiles() async -> [ProfileID] {
        guard let root = directory?.appending(path: "Profiles", directoryHint: .isDirectory),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return folders.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }
}
