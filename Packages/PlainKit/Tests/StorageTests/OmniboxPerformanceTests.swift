import BrowserCore
import Foundation
import GRDB
@testable import Storage
import Testing

/// Budget from docs/plan.md, section 2: the address bar query on 100k history pages, p95 < 16 ms.
/// Measured end to end through the public async API (`addressBarCandidates`), on a file-backed
/// DatabasePool like the app uses, while simulating typing.
@Suite(.serialized) struct OmniboxPerformanceTests {
    static let pageCount = 100_000
    static let budget = Duration.milliseconds(16)

    @Test func omniboxQueryOn100kPagesMeetsBudget() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "plain-perf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await AppDatabase.open(at: folder.appending(path: "Plain.sqlite"))

        var generator = SeededGenerator(seed: 42)
        let vocabulary = Self.vocabulary(using: &generator)
        let seedStart = ContinuousClock.now
        try await Self.seed(database, pages: Self.pageCount, vocabulary: vocabulary, using: &generator)
        let seedTime = ContinuousClock.now - seedStart
        for index in 0..<20 {
            try await database.addFavorite(url: URL(string: "https://\(vocabulary[index]).com/")!, title: vocabulary[index + 20])
        }

        // Every keystroke of typing these, then extra words, as people do.
        var queries: [String] = []
        let targets = ["github", "swift ui", "youtube music", "news", "apple developer", "wikipedia", "docs swift"]
            + (0..<25).map { _ in vocabulary[Int.random(in: 0..<300, using: &generator)] }
            + (0..<10).map { _ in vocabulary[Int.random(in: 0..<vocabulary.count, using: &generator)] + " " + vocabulary[Int.random(in: 0..<300, using: &generator)] }
        for target in targets {
            for length in 1...target.count { queries.append(String(target.prefix(length))) }
        }

        // Warm the page cache and statement cache once, as the app does after the first keystroke.
        for query in queries.prefix(20) { _ = try await database.addressBarCandidates(for: query) }

        var samples: [(query: String, time: Duration, hits: Int)] = []
        for _ in 0..<3 {
            for query in queries {
                let start = ContinuousClock.now
                let result = try await database.addressBarCandidates(for: query)
                samples.append((query, ContinuousClock.now - start, result.history.count))
            }
        }

        let sorted = samples.map(\.time).sorted()
        func percentile(_ p: Double) -> Duration { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let oneLetter = samples.filter { $0.query.count == 1 }.map(\.time).sorted()
        let slowest = samples.max { $0.time < $1.time }!
        print("""
            [perf] omnibox on \(Self.pageCount) pages (seeded in \(seedTime.formatted(.units(allowed: [.seconds, .milliseconds])))):
            [perf]   \(samples.count) queries, p50 \(Self.ms(percentile(0.5))), p95 \(Self.ms(percentile(0.95))), p99 \(Self.ms(percentile(0.99))), max \(Self.ms(sorted.last!)) ("\(slowest.query)")
            [perf]   one-letter queries p95 \(Self.ms(oneLetter[Int(Double(oneLetter.count) * 0.95)])), budget p95 < \(Self.ms(Self.budget))
            """)
        #expect(samples.filter { $0.query.hasPrefix("gith") }.allSatisfy { $0.hits > 0 })
        #expect(percentile(0.95) < Self.budget)
    }

    static func ms(_ duration: Duration) -> String {
        String(format: "%.2f ms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }

    /// Well-known words first (so they are common, as on real phones), then made-up ones.
    static func vocabulary(using generator: inout SeededGenerator) -> [String] {
        var words = [
            "github", "google", "youtube", "news", "swift", "apple", "developer", "wikipedia", "reddit", "amazon",
            "docs", "music", "maps", "mail", "weather", "recipes", "stack", "overflow", "medium", "twitter",
            "ui", "kit", "documentation", "tutorial", "guide", "review", "sports", "video", "shop", "travel",
        ]
        let syllables = ["ka", "lo", "mi", "ne", "ru", "ta", "vo", "zi", "pe", "sa", "do", "fu", "gri", "hel", "jun", "bro", "cle", "dra", "fen", "mor"]
        while words.count < 4_000 {
            let count = Int.random(in: 2...4, using: &generator)
            words.append((0..<count).map { _ in syllables.randomElement(using: &generator)! }.joined())
        }
        return words
    }

    /// Zipf-like pick: low indexes (common words) come up far more often.
    static func pick(_ vocabulary: [String], using generator: inout SeededGenerator) -> String {
        let u = Double.random(in: 0..<1, using: &generator)
        return vocabulary[min(vocabulary.count - 1, Int(pow(Double(vocabulary.count), u)) - 1)]
    }

    static func seed(_ database: AppDatabase, pages: Int, vocabulary: [String], using generator: inout SeededGenerator) async throws {
        let tlds = ["com", "org", "net", "io", "dev", "co.uk"]
        var rows: [(url: String, address: String, title: String, count: Int, last: Date, frecency: Double)] = []
        rows.reserveCapacity(pages)
        var seen = Set<String>()
        while rows.count < pages {
            let host = pick(vocabulary, using: &generator) + "." + tlds.randomElement(using: &generator)!
            let path = (0..<Int.random(in: 0...3, using: &generator)).map { _ in pick(vocabulary, using: &generator) }.joined(separator: "/")
            let suffix = Int.random(in: 0..<1_000, using: &generator)
            // One page in 20 is a site's root page (`github.com`), which the site-level top hit
            // looks up; the rest are deep pages.
            let isRoot = rows.count % 20 == 0
            let address = isRoot ? host : "\(host)/\(path)\(path.isEmpty ? "" : "-")\(suffix)"
            guard seen.insert(address).inserted else { continue }
            let title = (0..<Int.random(in: 2...7, using: &generator)).map { _ in pick(vocabulary, using: &generator).capitalized }.joined(separator: " ")
            let last = t0.addingTimeInterval(-Double.random(in: 0..<(365 * 86_400), using: &generator))
            var frecency: Double?
            let count = Int.random(in: 1...20, using: &generator)
            for _ in 0..<count { frecency = Frecency.adding(visitAt: last, to: frecency) }
            rows.append(("https://www." + address, address, title, count, last, frecency!))
        }
        let batch = rows
        try await database.writer.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO historyPlace (url, address, title, visitCount, lastVisitedAt, frecency)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            for row in batch {
                try statement.execute(arguments: [row.url, row.address, row.title, row.count, row.last, row.frecency])
            }
            // Adaptive history: a few thousand remembered picks for short inputs, as months of use leave.
            let pick = try db.makeStatement(sql: """
                INSERT OR IGNORE INTO inputHistory (input, url, useCount, lastUsedAt) VALUES (?, ?, ?, ?)
                """)
            for (index, row) in batch.enumerated() where index % 40 == 0 {
                let input = String(row.address.prefix(1 + index % 4))
                try pick.execute(arguments: [input, row.url, 1 + Double(index % 7), row.last])
            }
        }
        try await database.writer.write { db in try db.execute(sql: "ANALYZE") }
    }
}

/// SplitMix64: a deterministic generator, so every run seeds the same data.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
