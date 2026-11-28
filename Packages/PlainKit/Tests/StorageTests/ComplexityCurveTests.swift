import BrowserCore
import Foundation
import GRDB
@testable import Storage
import Testing

/// Time against size for the address bar's query and the tab session's launch read, at three sizes
/// each, with SQLite's query plan for every statement the keystroke runs (docs/research/perf-pass-3.md,
/// "Complexity"). Slow to seed (100k pages), so it runs only with `PLAIN_CURVES=1`:
/// `PLAIN_CURVES=1 swift test --filter ComplexityCurveTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PLAIN_CURVES"] == "1"))
struct ComplexityCurveTests {
    static let historySizes = [1_000, 10_000, 100_000]
    static let tabSizes = [10, 100, 1_000]

    /// Each size seeded the same way as `OmniboxPerformanceTests`; the same keystrokes at each.
    @Test func addressBarQueryAgainstHistorySize() async throws {
        var lines: [String] = []
        for size in Self.historySizes {
            let folder = FileManager.default.temporaryDirectory.appending(path: "plain-curve-\(UUID())")
            defer { try? FileManager.default.removeItem(at: folder) }
            let database = try await AppDatabase.open(at: folder.appending(path: "Plain.sqlite"))
            var generator = SeededGenerator(seed: 42)
            let vocabulary = OmniboxPerformanceTests.vocabulary(using: &generator)
            try await OmniboxPerformanceTests.seed(database, pages: size, vocabulary: vocabulary, using: &generator)
            for index in 0..<20 {
                try await database.addFavorite(url: URL(string: "https://\(vocabulary[index]).com/")!, title: vocabulary[index + 20])
            }
            let groups: [(String, [String])] = [
                ("1 letter", ["g", "s", "n", "y", "w", "a", "m", "d"]),
                ("2-3 letters", ["gi", "git", "sw", "swi", "ne", "yo", "wik", "ap"]),
                ("word", ["github", "swift", "youtube", "wikipedia", "developer", "music"]),
                ("2 words", ["swift ui", "apple developer", "docs swift", "youtube music"]),
            ]
            for (_, queries) in groups { for query in queries { _ = try await database.addressBarCandidates(for: query) } }
            var parts: [String] = []
            for (name, queries) in groups {
                var samples: [Duration] = []
                var matches = 0
                for _ in 0..<5 {
                    for query in queries {
                        let start = ContinuousClock.now
                        _ = try await database.addressBarCandidates(for: query)
                        samples.append(ContinuousClock.now - start)
                    }
                }
                // How many index rows the FTS match visits for these queries (the n each costs).
                for query in queries {
                    guard let pattern = HistoryQuery(query).pattern else { continue }
                    matches += try await database.writer.read { db in
                        try Int.fetchOne(db, sql: "SELECT count(*) FROM \(Schema.historySearch) WHERE \(Schema.historySearch) MATCH ?", arguments: [pattern]) ?? 0
                    }
                }
                samples.sort()
                parts.append("\(name) p50 \(OmniboxPerformanceTests.ms(samples[samples.count / 2])) p95 \(OmniboxPerformanceTests.ms(samples[Int(Double(samples.count - 1) * 0.95)])) (FTS rows visited avg \(matches / queries.count))")
            }
            lines.append("pages \(size): " + parts.joined(separator: "; "))
            if size == Self.historySizes.last {
                let plans = try await database.writer.read { db in try Self.plans(in: db) }
                lines.append(contentsOf: plans)
            }
        }
        print("[perf] address bar query vs history size:\n  " + lines.joined(separator: "\n  "))
    }

    /// The query plan of each statement a keystroke runs, on the seeded database.
    static func plans(in db: Database) throws -> [String] {
        let statements: [(String, String, StatementArguments)] = [
            ("history FTS", """
                SELECT p.url, p.title, p.frecency FROM \(Schema.historySearch) s JOIN \(Schema.historyPlace) p ON p.id = s.rowid
                WHERE \(Schema.historySearch) MATCH ? ORDER BY (p.address LIKE ? ESCAPE '\\') DESC, p.frecency DESC LIMIT ?
                """, ["\"swift\"*", "swift%", 16]),
            ("site", """
                SELECT url, title, frecency FROM \(Schema.historyPlace) INDEXED BY historyPlace_sites
                WHERE address >= ? AND address < ? AND instr(address, '/') = 0 AND instr(address, '?') = 0
                ORDER BY frecency DESC LIMIT 1
                """, ["swi", "swi\u{10FFFF}"]),
            ("input history", """
                SELECT i.url, max(i.useCount) AS use, p.title, p.frecency FROM \(Schema.inputHistory) i
                LEFT JOIN \(Schema.historyPlace) p ON p.url = i.url
                WHERE i.input >= ? AND i.input < ? GROUP BY i.url ORDER BY use DESC LIMIT ?
                """, ["sw", "sw\u{10FFFF}", 8]),
        ]
        var out: [String] = []
        for (name, sql, arguments) in statements {
            let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
            out.append("plan \(name): " + rows.map { String($0["detail"] as String? ?? "") }.joined(separator: " | "))
        }
        return out
    }

    /// The launch read and the main thread's build of `TabStore` against the open tabs.
    @MainActor
    @Test func tabSessionAgainstTabCount() async throws {
        var lines: [String] = []
        for count in Self.tabSizes {
            let folder = FileManager.default.temporaryDirectory.appending(path: "plain-curve-tabs-\(UUID())")
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appending(path: "Plain.sqlite")
            let seeded = try await AppDatabase.open(at: path)
            let window = WindowID()
            let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let open = (0..<count).map { index in
                TabEntry(url: URL(string: "https://site\(index % 50).example/page/\(index)")!, title: "Page \(index)", createdAt: base,
                         thumbnail: TabThumbnail(fileName: "\(index).jpg", revision: 1))
            }
            let session = TabSession(windows: [WindowSession(id: window, tabIDs: open.map(\.id), panes: [open[0].id], focusedPane: 0)], tabs: open)
            try await seeded.writer.write { db in
                _ = try TabSessionWriter.apply([.session(session)], written: nil, archiveLimit: 1_000, in: db)
            }
            var reads: [Duration] = []
            var builds: [Duration] = []
            var closes: [Duration] = []
            for _ in 0..<15 {
                let database = try await AppDatabase.open(at: path)
                let start = ContinuousClock.now
                let loaded = try await database.loadTabSession()
                reads.append(ContinuousClock.now - start)
                let buildStart = ContinuousClock.now
                // A sink that drops the changes: the session snapshot each change builds is the
                // production cost, the write is not this test's.
                let store = TabStore(session: loaded, persistence: DroppingPersistence())
                _ = store.selectedTabID(in: store.windows[0].id)
                builds.append(ContinuousClock.now - buildStart)
                // Closing every other tab one by one: each close is O(tabs) in the lists.
                let ids = store.windows[0].tabIDs.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                let closeStart = ContinuousClock.now
                for id in ids { store.close(id) }
                closes.append(ContinuousClock.now - closeStart)
            }
            func median(_ values: [Duration]) -> String { TabSessionPerformanceTests.ms(values.sorted()[values.count / 2]) }
            lines.append("tabs \(count): read \(median(reads)) ms, TabStore build \(median(builds)) ms, \(count / 2) closes \(median(closes)) ms")
        }
        print("[perf] tab session vs open tabs:\n  " + lines.joined(separator: "\n  "))
    }
}

/// Takes every change and keeps none.
private struct DroppingPersistence: TabPersistence {
    func enqueue(_ change: TabChange) {}
    func flush() async {}
}
