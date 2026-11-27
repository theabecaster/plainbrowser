import BrowserCore
@testable import FeatureUI
import Foundation
import Storage
import Testing

/// The archive in memory, filtered like the database: words in the title or address.
actor FakeArchive: ArchiveStoring {
    var tabs: [ArchivedTab]
    private(set) var queries: [String] = []
    var failNextRead = false

    init(_ tabs: [ArchivedTab]) {
        self.tabs = tabs
    }

    func failNextReadCall() { failNextRead = true }

    func archivedTabs(matching query: String, limit: Int) async throws -> [ArchivedTab] {
        queries.append(query)
        if failNextRead { failNextRead = false; throw URLError(.cannotOpenFile) }
        let matches = query.isEmpty ? tabs : tabs.filter {
            ($0.entry.title ?? "").localizedCaseInsensitiveContains(query)
                || ($0.entry.url?.absoluteString ?? "").localizedCaseInsensitiveContains(query)
        }
        return Array(matches.prefix(limit))
    }
}

@MainActor
struct ArchiveModelTests {
    private static func tab(_ title: String?, _ address: String, archivedHoursAgo hours: Double) -> ArchivedTab {
        ArchivedTab(
            entry: TabEntry(id: TabID(), url: URL(string: address), title: title, createdAt: Date()),
            archivedAt: Date().addingTimeInterval(-hours * 3600)
        )
    }

    @Test func listsRowsWithTitleOrAddress() async {
        let archive = FakeArchive([
            Self.tab("Swift Forums", "https://forums.swift.org/latest", archivedHoursAgo: 1),
            Self.tab(nil, "https://www.example.com/", archivedHoursAgo: 2),
        ])
        let model = ArchiveModel(store: archive, onRestore: { _ in }, onDelete: { _ in })
        await model.load()
        #expect(model.isLoaded)
        #expect(model.rows.map(\.title) == ["Swift Forums", "example.com"])
        #expect(model.rows.map(\.address) == ["forums.swift.org/latest", "example.com"])
    }

    @Test func failedReadShowsTryAgainNotTheEmptyState() async {
        let archive = FakeArchive([Self.tab("Swift Forums", "https://forums.swift.org/latest", archivedHoursAgo: 1)])
        let model = ArchiveModel(store: archive, onRestore: { _ in }, onDelete: { _ in })
        await archive.failNextReadCall()
        await model.load()
        #expect(model.loadFailed)
        #expect(model.isLoaded)
        await model.load()
        #expect(!model.loadFailed)
        #expect(model.rows.count == 1)
        await archive.failNextReadCall()
        await model.load()
        #expect(model.rows.isEmpty, "stale rows don't stay under the failure")
    }

    @Test func restoreAndDeleteLeaveTheListAndReachTheShell() async {
        let first = Self.tab("A", "https://a.example", archivedHoursAgo: 1)
        let second = Self.tab("B", "https://b.example", archivedHoursAgo: 2)
        let archive = FakeArchive([first, second])
        var restored: [TabID] = []
        var deleted: [TabID] = []
        let model = ArchiveModel(store: archive, onRestore: { restored.append($0.id) }, onDelete: { deleted += $0 })
        await model.load()
        model.restore(model.rows[0])
        #expect(restored == [first.id])
        #expect(model.rows.map(\.id) == [second.id])
        model.delete(model.rows[0])
        #expect(deleted == [second.id])
        #expect(model.rows.isEmpty)
        // A reload before the store writes the delete still leaves them out.
        await model.load()
        #expect(model.rows.isEmpty)
    }

    @Test func searchWaitsForThePauseThenFilters() async throws {
        let archive = FakeArchive([
            Self.tab("Recipes", "https://recipes.example", archivedHoursAgo: 1),
            Self.tab("News", "https://news.example", archivedHoursAgo: 2),
        ])
        let model = ArchiveModel(store: archive, onRestore: { _ in }, onDelete: { _ in })
        await model.load()
        model.query = "rec"
        try await Task.sleep(for: FixedChoices.historySearchDelay * 4)
        #expect(model.rows.map(\.title) == ["Recipes"])
        #expect(await archive.queries.last == "rec")
    }
}
