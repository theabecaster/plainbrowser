import BrowserCore
import Foundation
import GRDB
@testable import Storage
import Testing

/// Cold launch with 100 open tabs and 1,000 archived ones, on a file-backed DatabasePool like the
/// app uses. The read runs off the main thread; the main thread only builds `TabStore` from it,
/// and that part has the 5 ms budget. The archive is never read at launch.
@MainActor
@Suite(.serialized) struct TabSessionPerformanceTests {
    nonisolated static let openTabs = 100
    nonisolated static let archivedTabs = 1_000
    static let mainThreadBudget = Duration.milliseconds(5)
    static let runs = 30

    @Test func coldLaunchWith100TabsAnd1000ArchivedMeetsBudget() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "plain-tabs-perf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "Plain.sqlite")
        try await Self.seed(try await AppDatabase.open(at: path))

        var reads: [Duration] = []
        var builds: [Duration] = []
        var searches: [Duration] = []
        for _ in 0 ..< Self.runs {
            // A fresh open each run, as at launch: no warm statement cache.
            let database = try await AppDatabase.open(at: path)
            let readStart = ContinuousClock.now
            let session = try await database.loadTabSession()
            reads.append(ContinuousClock.now - readStart)

            let buildStart = ContinuousClock.now
            let store = TabStore(session: session, persistence: database.tabSession)
            _ = store.selectedTabID(in: store.windows[0].id)
            builds.append(ContinuousClock.now - buildStart)
            #expect(store.windows[0].tabIDs.count == Self.openTabs)

            let searchStart = ContinuousClock.now
            let found = try await database.searchArchivedTabs("recipe")
            searches.append(ContinuousClock.now - searchStart)
            #expect(!found.isEmpty)
        }
        let read = Self.median(reads), build = Self.median(builds), search = Self.median(searches)
        print("""
            [perf] tab cold launch (\(Self.openTabs) open + \(Self.archivedTabs) archived), median of \(Self.runs):
              loadTabSession (off main): \(Self.ms(read)) ms, p95 \(Self.ms(Self.p95(reads))) ms
              TabStore(session:) on main: \(Self.ms(build)) ms, p95 \(Self.ms(Self.p95(builds))) ms
              archive search "recipe" (1000 rows, FTS): \(Self.ms(search)) ms
            """)
        #expect(Self.p95(builds) < Self.mainThreadBudget)
    }

    /// The Archive screen's read at its largest (the whole archive, 1,000 rows) and a pruning pass
    /// that clears 500 expired tabs with their state files, both off the main thread.
    @Test func fullArchiveReadAndPruneAreQuick() async throws {
        var reads: [Duration] = []
        var prunes: [Duration] = []
        for _ in 0 ..< 10 {
            let folder = FileManager.default.temporaryDirectory.appending(path: "plain-archive-perf-\(UUID())")
            defer { try? FileManager.default.removeItem(at: folder) }
            let database = try await AppDatabase.open(
                at: folder.appending(path: "Plain.sqlite"), tabStateDirectory: folder.appending(path: "TabState")
            )
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            // Spread over 60 days: the older half is past the archive's 30 days.
            let step = 2 * FixedChoices.archivedTabLifetime / Double(Self.archivedTabs)
            let entries = (0 ..< Self.archivedTabs).map { index in
                TabEntry(url: URL(string: "https://example.com/\(index)")!, title: "Page \(index)", createdAt: now)
            }
            for entry in entries { try await database.tabStates.write(Data(repeating: 1, count: 4_096), for: entry.id) }
            try await database.writer.write { db in
                for (index, entry) in entries.enumerated() {
                    _ = try TabSessionWriter.apply(
                        [.archive([entry], at: now.addingTimeInterval(-step * Double(index)))], written: nil,
                        archiveLimit: Self.archivedTabs, in: db
                    )
                }
            }
            let readStart = ContinuousClock.now
            let all = try await database.archivedTabs(limit: Self.archivedTabs)
            reads.append(ContinuousClock.now - readStart)
            #expect(all.count == Self.archivedTabs)

            let pruneStart = ContinuousClock.now
            database.tabSession.enqueue(.pruneArchive(archivedBefore: now.addingTimeInterval(-FixedChoices.archivedTabLifetime)))
            await database.tabSession.flush()
            prunes.append(ContinuousClock.now - pruneStart)
            let left = try await database.archivedTabCount()
            #expect(left == Self.archivedTabs / 2 + 1 || left == Self.archivedTabs / 2)
        }
        print("""
            [perf] archive (\(Self.archivedTabs) rows), median of \(reads.count):
              full archive read (off main): \(Self.ms(Self.median(reads))) ms, p95 \(Self.ms(Self.p95(reads))) ms
              prune of ~500 expired with state files (off main): \(Self.ms(Self.median(prunes))) ms, p95 \(Self.ms(Self.p95(prunes))) ms
            """)
    }

    static func seed(_ database: AppDatabase) async throws {
        let window = WindowID()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let words = ["recipe", "news", "swift", "travel", "music", "docs", "sports", "weather"]
        let open = (0 ..< openTabs).map { index in
            TabEntry(
                url: URL(string: "https://\(words[index % words.count]).example/page/\(index)")!,
                title: "Open \(words[index % words.count]) page \(index)", createdAt: base,
                thumbnail: TabThumbnail(fileName: "\(index).jpg", revision: 1)
            )
        }
        let archived = (0 ..< archivedTabs).map { index in
            TabEntry(
                url: URL(string: "https://\(words[index % words.count]).example/old/\(index)")!,
                title: "Archived \(words[index % words.count]) story \(index)", createdAt: base
            )
        }
        let session = TabSession(
            windows: [WindowSession(id: window, tabIDs: open.map(\.id), panes: [open[0].id], focusedPane: 0)],
            tabs: open
        )
        try await database.writer.write { db in
            _ = try TabSessionWriter.apply(
                [.archive(archived, at: base), .session(session)], written: nil, archiveLimit: archivedTabs, in: db
            )
        }
    }

    static func median(_ values: [Duration]) -> Duration { values.sorted()[values.count / 2] }
    static func p95(_ values: [Duration]) -> Duration { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
    static func ms(_ duration: Duration) -> String {
        String(format: "%.3f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }
}
