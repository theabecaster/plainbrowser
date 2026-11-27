import BrowserCore
import Foundation
import PerfSignposts
import Storage

/// Each profile's history database for one window (docs/decisions.md, "Profiles, no tab
/// groups"): Personal's is the main database; every other profile's opens from
/// `ProfileDataLocation` the first time it is needed, off the main thread, and stays open for the
/// launch. Nothing opens for a person who never makes a second profile.
@MainActor
public final class ProfileDatabases {
    private let main: @Sendable () async -> AppDatabase?
    private let location: ProfileDataLocation
    private var opened: [ProfileID: Task<AppDatabase?, Never>] = [:]

    /// - Parameters:
    ///   - main: the main database, once open (Personal's history and favorites).
    ///   - location: where the other profiles' databases live (a temporary folder, or memory, in
    ///     an isolated test run).
    public init(main: @escaping @Sendable () async -> AppDatabase?, location: ProfileDataLocation) {
        self.main = main
        self.location = location
    }

    /// `id`'s history database; nil while the main database is not open or when it can't open.
    public func database(for id: ProfileID) async -> AppDatabase? {
        if id == Profile.defaultID { return await main() }
        if let task = opened[id] { return await task.value }
        let location = location
        let task = Task<AppDatabase?, Never> {
            let signposter = Signposts.signposter
            let interval = signposter.beginInterval(Signposts.profileDataOpen, id: signposter.makeSignpostID())
            defer { signposter.endInterval(Signposts.profileDataOpen, interval) }
            return try? await location.open(id)
        }
        opened[id] = task
        let database = await task.value
        // A failed open is tried again next time rather than remembered.
        if database == nil, opened[id] == task { opened[id] = nil }
        return database
    }

    /// Every open database of a profile other than Personal, with its profile.
    func openDatabases(of profiles: [ProfileID]) async -> [(ProfileID, AppDatabase)] {
        var databases: [(ProfileID, AppDatabase)] = []
        for id in profiles where id != Profile.defaultID {
            if let database = await database(for: id) { databases.append((id, database)) }
        }
        return databases
    }

    /// Deletes a deleted profile's history database. The caller has written what was queued for
    /// it (`LiveAddressBarData.forgetProfile`).
    func remove(_ id: ProfileID) async {
        guard id != Profile.defaultID else { return }
        if let database = await opened.removeValue(forKey: id)?.value {
            await database.historyRecorder.flush()
        }
        await location.remove(id)
    }

    /// Deletes data of profiles no longer in the list (a deletion the app could not finish). The
    /// list is read after the folders are found, so a profile made meanwhile keeps its data.
    func removeLeftovers(keeping profiles: () -> [ProfileID]) async {
        let stored = await location.storedProfiles()
        let live = Set(profiles())
        for id in stored where !live.contains(id) && opened[id] == nil {
            await location.remove(id)
        }
    }
}
