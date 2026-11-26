#if canImport(UIKit)
import BrowserCore
import Foundation
import Storage
import Testing
import UIKit
@testable import WebEngine

/// The M2 shell seams: a closed tab keeps its state file for Reopen Closed Tab, a saved tab reads
/// that file on first attach, and private tabs write nothing and share one separate data store.
@MainActor
@Suite(.serialized)
struct SavedTabTests {
    @Test func closingKeepsTheStateFileAndASavedTabComesBackWithItsHistory() async throws {
        let harness = try await Harness(tabStates: true)
        defer { harness.cleanUp() }
        let states = TabStateStore(directory: harness.directory.appending(path: "TabStates"))
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        try await harness.load("/b", in: tab)
        let id = tab.id
        harness.pool.close(tab, keepingSavedState: true)
        try await waitUntil("state written on close") { FileManager.default.fileExists(atPath: states.fileURL(for: id).path) }

        // Reopen Closed Tab: a saved tab with the same id, only its address until it attaches.
        let reopened = harness.pool.makeSavedTab(id: id, url: tab.url, title: "B")
        #expect(reopened.tier == .discarded)
        harness.pool.attach(reopened, to: harness.container)
        try await waitUntil("restored") { reopened.title == "B" && !reopened.isLoading && reopened.canGoBack }
        reopened.goBack()
        try await waitUntil("history came back") { reopened.title == "A" }
        harness.pool.close(reopened)
        try await waitUntil("deleted on a plain close") { !FileManager.default.fileExists(atPath: states.fileURL(for: id).path) }
    }

    @Test func aSavedTabWithoutAFileLoadsItsAddress() async throws {
        let harness = try await Harness(tabStates: true)
        defer { harness.cleanUp() }
        let url = harness.server.url("/a")
        let tab = harness.pool.makeSavedTab(id: UUID(), url: url, title: "A")
        harness.pool.attach(tab, to: harness.container)
        try await waitUntil("loaded") { tab.title == "A" && !tab.isLoading }
        #expect(!tab.canGoBack)
    }

    @Test func privateTabsWriteNothingAndShareTheirOwnStore() async throws {
        let harness = try await Harness(tabStates: true)
        defer { harness.cleanUp() }
        let states = TabStateStore(directory: harness.directory.appending(path: "TabStates"))
        let regular = harness.pool.makeTab()
        harness.pool.attach(regular, to: harness.container)
        try await harness.load("/a", in: regular)
        _ = try await harness.evaluate("localStorage.setItem('who', 'regular'); 0", in: regular)

        let first = harness.pool.makeTab(isPrivate: true)
        harness.pool.attach(first, to: harness.container)
        try await harness.load("/a", in: first)
        let seen = try await harness.evaluate("localStorage.getItem('who')", in: first)
        #expect(seen as? String == nil, "a private tab must not see regular storage")
        _ = try await harness.evaluate("localStorage.setItem('who', 'private'); 0", in: first)

        let second = harness.pool.makeTab(isPrivate: true)
        harness.pool.attach(second, to: harness.container)
        try await harness.load("/b", in: second)
        let shared = try await harness.evaluate("localStorage.getItem('who')", in: second)
        #expect(shared as? String == "private", "private tabs share one store")

        harness.pool.detach(first)
        harness.pool.detach(second)
        await harness.pool.saveAllTabs()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: states.fileURL(for: first.id).path))
        #expect(!FileManager.default.fileExists(atPath: harness.pool.thumbnails.fileURL(for: first.id).path))
        #expect(FileManager.default.fileExists(atPath: states.fileURL(for: regular.id).path))
    }
}
#endif
