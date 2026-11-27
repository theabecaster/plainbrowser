#if canImport(UIKit)
import BrowserCore
import Foundation
import ImageIO
import Storage
import Testing
import UIKit
import WebKit
@testable import WebEngine

/// Site icons end to end against the local server: asked once per site, stored per profile,
/// private ones in memory only, decoded at the size asked for.
@Suite(.serialized) @MainActor
struct FaviconServiceTests {
    static let site = "127.0.0.1"
    static let personal = SiteIconScope.profile(Profile.defaultID)

    /// A colored square with a clear border, a black mark on a clear ground, or an opaque square.
    enum Art: Sendable { case color, darkMark, opaque }

    nonisolated static func png(_ art: Art, side: Int = 128) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let bounds = CGRect(origin: .zero, size: size)
            switch art {
            case .opaque:
                context.cgContext.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.7, alpha: 1))
                context.cgContext.fill(bounds)
            case .color:
                context.cgContext.setFillColor(CGColor(red: 1, green: 0.55, blue: 0.1, alpha: 1))
                context.cgContext.fillEllipse(in: bounds.insetBy(dx: 16, dy: 16))
            case .darkMark:
                context.cgContext.setFillColor(CGColor(gray: 0, alpha: 1))
                context.cgContext.fillEllipse(in: bounds.insetBy(dx: 20, dy: 20))
            }
        }
    }

    @Sendable nonisolated static func route(_ request: TestServer.Request) -> TestServer.Response {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        switch path {
        case "/linked", "/linked2":
            return .html("""
                <!doctype html><html><head><title>Linked</title>
                <link rel="icon" sizes="16x16" href="/small.png">
                <link rel="shortcut icon" sizes="128x128" href="/icon.png">
                <link rel="icon" type="image/svg+xml" href="/icon.svg">
                </head><body>linked</body></html>
                """)
        case "/bare":
            return .html("<!doctype html><html><head><title>Bare</title></head><body>bare</body></html>")
        case "/icon.png": return .data(png(.color), type: "image/png")
        case "/small.png": return .data(png(.opaque, side: 16), type: "image/png")
        case "/favicon.ico": return .data(png(.darkMark, side: 48), type: "image/x-icon")
        default: return .notFound
        }
    }

    func requests(_ harness: Harness, for path: String) -> Int {
        harness.server.requests.filter { $0.path == path }.count
    }

    @Test func thePagesIconIsFetchedOncePerSite() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let favicons = harness.pool.favicons
        var changes: [String?] = []
        favicons.onChange = { changes.append($0) }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        #expect(favicons.cachedIcon(site: Self.site, scope: Self.personal, pixelSize: 60) == nil)

        try await harness.load("/linked", in: tab)
        try await waitUntil("icon stored") { favicons.revision(site: Self.site, scope: Self.personal) > 0 }
        #expect(changes == [Self.site])
        // The 128 px icon (the smallest at least 60 px), not the 16 px one or the vector.
        #expect(requests(harness, for: "/icon.png") == 1)
        #expect(requests(harness, for: "/small.png") == 0)
        #expect(requests(harness, for: "/icon.svg") == 0)
        #expect(requests(harness, for: "/favicon.ico") == 0)

        let icon = try #require(await favicons.icon(site: Self.site, scope: Self.personal, pixelSize: 60))
        #expect(icon.image.cgImage?.width == 60 && icon.image.cgImage?.height == 60, "decoded at the size asked for")
        #expect(icon.style == .glyph)
        #expect(favicons.cachedIcon(site: Self.site, scope: Self.personal, pixelSize: 60) != nil, "in memory for the next row")

        // More pages of the site ask for nothing.
        try await harness.load("/linked2", in: tab)
        try await harness.load("/bare", in: tab)
        try await Task.sleep(for: .milliseconds(300))
        #expect(requests(harness, for: "/icon.png") == 1)
        #expect(requests(harness, for: "/favicon.ico") == 0)
        #expect(changes == [Self.site])
    }

    @Test func aPageWithoutLinksUsesFaviconIco() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let favicons = harness.pool.favicons
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/bare", in: tab)
        try await waitUntil("icon stored") { favicons.revision(site: Self.site, scope: Self.personal) > 0 }
        #expect(requests(harness, for: "/favicon.ico") == 1)
        let icon = try #require(await favicons.icon(site: Self.site, scope: Self.personal, pixelSize: 48))
        #expect(icon.style == .darkGlyph, "a black mark on a clear ground asks for a light tile at night")
        // For a view with no tile of its own the mark comes on one.
        let plated = try #require(await favicons.icon(site: Self.site, scope: Self.personal, pixelSize: 48, plated: true))
        #expect(plated.style == .tile)
    }

    @Test func aSiteWithNoIconIsAskedOnceAndShowsNone() async throws {
        let harness = try await Harness(route: { request in
            if request.path == "/favicon.ico" { return TestServer.Response.notFound }
            return TestServer.Response.html("<!doctype html><title>None</title><body>none</body>")
        })
        defer { harness.cleanUp() }
        let favicons = harness.pool.favicons
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/one", in: tab)
        try await waitUntil("asked") { requests(harness, for: "/favicon.ico") == 1 }
        try await harness.load("/two", in: tab)
        try await Task.sleep(for: .milliseconds(300))
        #expect(requests(harness, for: "/favicon.ico") == 1)
        #expect(await favicons.icon(site: Self.site, scope: Self.personal, pixelSize: 60) == nil)
        #expect(favicons.revision(site: Self.site, scope: Self.personal) == 0)
    }

    @Test func privateIconsStayInMemoryAndGoWithTheSession() async throws {
        let database = try AppDatabase.inMemory()
        let server = try await TestServer(route: Self.route)
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "plain-icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pool = WebViewPool(
            dataStore: .nonPersistent(), thumbnailDirectory: directory.appending(path: "Thumbnails"),
            downloadDirectory: directory.appending(path: "Downloads"), iconDatabases: { _ in database }
        )
        let host = FakeHost()
        pool.host = host
        host.pool = pool
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.isHidden = false
        defer { window.isHidden = true }
        let favicons = pool.favicons

        let secret = pool.makeTab(isPrivate: true)
        pool.attach(secret, to: window)
        secret.load(server.url("/linked"))
        try await waitUntil("private icon") { favicons.revision(site: Self.site, scope: .privateTabs) > 0 }
        #expect(await favicons.icon(site: Self.site, scope: .privateTabs, pixelSize: 60) != nil)
        #expect(try await database.favicon(forHost: Self.site) == nil, "nothing of a private tab reaches the database")
        #expect(await favicons.icon(site: Self.site, scope: Self.personal, pixelSize: 60) == nil, "nor a regular tab's row")

        pool.close(secret)
        pool.endPrivateSession()
        #expect(await favicons.icon(site: Self.site, scope: .privateTabs, pixelSize: 60) == nil)
        #expect(favicons.cachedIcon(site: Self.site, scope: .privateTabs, pixelSize: 60) == nil)

        // A regular tab's icon is stored in its profile's database, as a small PNG.
        let tab = pool.makeTab()
        pool.attach(tab, to: window)
        tab.load(server.url("/linked"))
        try await waitUntil("stored icon") { favicons.revision(site: Self.site, scope: Self.personal) > 0 }
        let stored = try #require(try await database.favicon(forHost: Self.site))
        let source = try #require(CGImageSourceCreateWithData(stored.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == FixedChoices.faviconStoredPixelSize, "scaled down before it is stored")
        #expect(stored.data.count < 20_000)

        // Clear History and Data: memory follows the database.
        try await database.clearFavicons()
        NotificationCenter.default.post(name: FaviconService.storedIconsCleared, object: nil)
        #expect(favicons.cachedIcon(site: Self.site, scope: Self.personal, pixelSize: 60) == nil)
        #expect(await favicons.icon(site: Self.site, scope: Self.personal, pixelSize: 60) == nil)
    }

    @Test func decodingReadsTheStyleFromThePixels() throws {
        let opaque = try #require(FaviconService.normalized(Self.png(.opaque)))
        #expect(FaviconService.decodeNow(opaque, pixelSize: 60, plated: false)?.style == .tile)
        let dark = try #require(FaviconService.normalized(Self.png(.darkMark)))
        #expect(FaviconService.decodeNow(dark, pixelSize: 60, plated: false)?.style == .darkGlyph)
        let color = try #require(FaviconService.normalized(Self.png(.color)))
        #expect(FaviconService.decodeNow(color, pixelSize: 60, plated: false)?.style == .glyph)
        // A tracking pixel, or anything that is no image, is no icon.
        #expect(FaviconService.normalized(Self.png(.opaque, side: 1)) == nil)
        #expect(FaviconService.normalized(Data("<html>".utf8)) == nil)
    }
}
#endif
