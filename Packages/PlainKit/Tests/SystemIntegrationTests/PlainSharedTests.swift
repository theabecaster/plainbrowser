import Foundation
import PlainShared
import Testing

@Suite struct PlainLinkTests {
    @Test(arguments: [
        PlainCommand.focusSearch, .search("swift & co = 1+1 #tag"), .open(URL(string: "https://example.com/a?b=c#d")!),
        .newTab, .newPrivateTab, .showTabs,
    ])
    func everyCommandRoundTrips(_ command: PlainCommand) {
        let url = PlainLink.url(for: command)
        #expect(url.scheme == "plainbrowser")
        #expect(PlainLink.command(from: url) == command)
    }

    @Test func webLinksOpen() {
        let page = URL(string: "https://example.com")!
        #expect(PlainLink.command(from: page) == .open(page))
        #expect(PlainLink.command(from: URL(string: "HTTP://example.com")!) != nil)
    }

    @Test func anEmptySearchFocusesTheField() {
        #expect(PlainLink.command(from: URL(string: "plainbrowser://search?q=%20%20")!) == .focusSearch)
        #expect(PlainLink.command(from: URL(string: "plainbrowser://search")!) == .focusSearch)
    }

    @Test func onlyWebPagesOpen() {
        #expect(PlainLink.command(from: URL(string: "plainbrowser://open?url=javascript:alert(1)")!) == nil)
        #expect(PlainLink.command(from: URL(string: "plainbrowser://open?url=file:///etc/hosts")!) == nil)
        #expect(PlainLink.command(from: URL(string: "plainbrowser://open")!) == nil)
        #expect(PlainLink.command(from: URL(string: "plainbrowser://elsewhere")!) == nil)
        #expect(PlainLink.command(from: URL(string: "mailto:a@b.c")!) == nil)
    }
}

@Suite struct SharedFavoritesTests {
    private func temporaryFile() -> SharedFavoritesFile {
        SharedFavoritesFile(url: FileManager.default.temporaryDirectory
            .appending(path: "PlainShared-\(UUID().uuidString)/favorites.json"))
    }

    @Test func writesAndReadsInOrder() throws {
        let file = temporaryFile()
        #expect(file.read().isEmpty)
        let favorites = [
            SharedFavorite(url: URL(string: "https://b.example")!, title: "B"),
            SharedFavorite(url: URL(string: "https://a.example")!, title: "A"),
        ]
        try file.write(favorites)
        #expect(file.read() == favorites)
        try FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }

    @Test func aDamagedFileReadsAsEmpty() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        #expect(file.read().isEmpty)
        try FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }

    @Test func untitledFavoritesTakeTheSiteName() {
        let favorite = SharedFavorite(url: URL(string: "https://www.apple.com/iphone")!, title: "  ")
        #expect(favorite.title == "apple.com")
        #expect(favorite.monogram == "A")
        #expect(SharedFavorite(url: URL(string: "https://x.example")!, title: "“9to5Mac”").monogram == "9")
    }

    @Test func theWidgetShowsTheFirstFour() {
        let six = (0 ..< 6).map { SharedFavorite(url: URL(string: "https://\($0).example")!, title: "\($0)") }
        #expect(SearchWidgetContent(favorites: six).favorites.map(\.title) == ["0", "1", "2", "3"])
        #expect(SearchWidgetContent(file: nil).favorites.isEmpty)
    }
}

@MainActor @Suite struct CommandInboxTests {
    @Test func commandsWaitForTheHandlerThenArriveInOrder() {
        let inbox = CommandInbox()
        var received: [PlainCommand] = []
        inbox.send(.newTab)
        inbox.send(.search("a"))
        #expect(received.isEmpty)
        inbox.handler = { received.append($0) }
        #expect(received == [.newTab, .search("a")])
        inbox.send(.showTabs)
        #expect(received == [.newTab, .search("a"), .showTabs])
    }
}
