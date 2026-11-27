#if canImport(UIKit)
import BrowserCore
import Foundation
import ImageIO
import PerfSignposts
import Storage
import UIKit
import UniformTypeIdentifiers
import WebKit

/// A site's icon, decoded at the size a view shows it, with how it sits on its tile.
public nonisolated struct SiteIcon: Sendable {
    public let image: UIImage
    public let style: SiteIconStyle

    public init(image: UIImage, style: SiteIconStyle) {
        self.image = image
        self.style = style
    }
}

/// Whose icons: a profile's (kept in that profile's database) or the private tabs' (memory only).
public nonisolated enum SiteIconScope: Hashable, Sendable {
    case profile(ProfileID)
    case privateTabs
}

/// Site icons for everything that lists tabs (docs/decisions.md, "Site icons").
///
/// Once per site: when a page finishes and its site has no fresh icon, the page is asked for its
/// `<link rel="icon">` and `apple-touch-icon` links (one script call, nothing injected into
/// pages), the best is downloaded with `/favicon.ico` as the last resort, scaled down to
/// `FixedChoices.faviconStoredPixelSize` and stored as PNG in the tab's profile's database.
/// Private tabs' icons stay in memory and go with the private session. Views get icons decoded
/// at their exact pixel size. The download, the scaling, the database and every decode run off
/// the main thread; the main thread only assigns a ready bitmap.
public final class FaviconService {
    /// A profile's database, or nil while it is not open. Without one icons live in memory only.
    public typealias Databases = @MainActor (ProfileID) async -> AppDatabase?

    private nonisolated struct Key: Hashable, Sendable {
        let scope: SiteIconScope
        let site: String
    }

    private enum Status {
        case loading
        case stored
        /// No icon was found, at this time.
        case missing(Date)
    }

    private let databases: Databases?
    /// A site's icon arrived or changed (the site key), or every icon was cleared (nil). The
    /// shell reads its tab lists again.
    public var onChange: ((String?) -> Void)?

    private var status: [Key: Status] = [:]
    private var revisions: [Key: Int] = [:]
    /// Bumped by `clear()`, so every revision changes at once.
    private var epoch = 0
    /// Sites the database has no icon for, so a row asking again costs no read.
    private var absent: Set<Key> = []
    /// Icons kept in memory only: the private tabs', and every icon when there is no database.
    private var memoryData: [Key: Data] = [:]
    private var memoryOrder: [Key] = []
    private let cache = NSCache<CacheKey, IconBox>()
    private let privateCache = NSCache<CacheKey, IconBox>()
    private var decoding: [CacheKey: Task<SiteIcon?, Never>] = [:]

    /// Posted on the main thread after the stored icons were deleted (Clear History and Data):
    /// every window's service drops what it holds in memory.
    public nonisolated static let storedIconsCleared = Notification.Name("plain.favicons.cleared")
    private var clearObserver: (any NSObjectProtocol)?

    init(databases: Databases?) {
        self.databases = databases
        cache.totalCostLimit = FixedChoices.faviconMemoryBytes
        privateCache.totalCostLimit = FixedChoices.faviconMemoryBytes / 4
        clearObserver = NotificationCenter.default.addObserver(
            forName: Self.storedIconsCleared, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    isolated deinit {
        if let clearObserver { NotificationCenter.default.removeObserver(clearObserver) }
    }

    // MARK: Reading

    /// The key a page's icon is kept under, nil for anything but a web page.
    public nonisolated static func site(of url: URL?) -> String? {
        FaviconRules.siteKey(for: url)
    }

    /// Changes when `site`'s icon arrives or changes, so a list knows to show it.
    public func revision(site: String, scope: SiteIconScope) -> Int {
        epoch &* 100_000 &+ revisions[Key(scope: scope, site: site), default: 0]
    }

    /// The icon if it is decoded in memory now. Never touches the disk.
    /// - Parameter plated: for a view with no tile of its own: a shape on a clear ground comes on
    ///   a light rounded tile, so a dark mark shows on any ground.
    public func cachedIcon(site: String, scope: SiteIconScope, pixelSize: Int, plated: Bool = false) -> SiteIcon? {
        let key = CacheKey(
            scope: scope, site: site, revision: revision(site: site, scope: scope), pixelSize: pixelSize, plated: plated
        )
        return cache(for: scope).object(forKey: key)?.icon
    }

    /// The icon decoded at `pixelSize` square, or nil when the site has none (yet). Reads and
    /// decodes off the main thread; rows asking for the same icon share one decode.
    public func icon(site: String, scope: SiteIconScope, pixelSize: Int, plated: Bool = false) async -> SiteIcon? {
        let key = Key(scope: scope, site: site)
        let cacheKey = CacheKey(
            scope: scope, site: site, revision: revision(site: site, scope: scope), pixelSize: pixelSize, plated: plated
        )
        if let box = cache(for: scope).object(forKey: cacheKey) { return box.icon }
        if let task = decoding[cacheKey] { return await task.value }
        if absent.contains(key) { return nil }
        if case .missing = status[key] { return nil }
        let task = Task<SiteIcon?, Never> { [weak self] in
            guard let self, let data = await self.storedData(for: key) else { return nil }
            let signposter = Signposts.signposter
            let interval = signposter.beginInterval(Signposts.faviconDecode, id: signposter.makeSignpostID())
            defer { signposter.endInterval(Signposts.faviconDecode, interval) }
            return await Self.decode(data, pixelSize: pixelSize, plated: plated)
        }
        decoding[cacheKey] = task
        let icon = await task.value
        decoding[cacheKey] = nil
        if let icon {
            cache(for: scope).setObject(IconBox(icon), forKey: cacheKey, cost: pixelSize * pixelSize * 4)
        }
        return icon
    }

    private func cache(for scope: SiteIconScope) -> NSCache<CacheKey, IconBox> {
        scope == .privateTabs ? privateCache : cache
    }

    /// The stored PNG for `key`: from memory, else from its profile's database.
    private func storedData(for key: Key) async -> Data? {
        if let data = memoryData[key] { return data }
        guard case let .profile(profile) = key.scope, let database = await databases?(profile) else { return nil }
        let before = revisions[key, default: 0]
        let data = (try? await database.favicon(forHost: key.site))?.data
        // Nothing stored and nothing arrived meanwhile: remember it, so the next row does not ask.
        if data == nil, revisions[key, default: 0] == before { absent.insert(key) }
        return data
    }

    // MARK: Fetching

    /// A main-frame load finished in `tab`: its site's icon is fetched unless one is stored and
    /// fresh, or the site was asked not long ago. One dictionary lookup for a site already seen.
    func pageDidFinish(_ webView: WKWebView, tab: Tab) {
        guard let page = webView.url, let site = FaviconRules.siteKey(for: page) else { return }
        let key = Key(scope: tab.isPrivate ? .privateTabs : .profile(tab.profileID), site: site)
        switch status[key] {
        case .loading, .stored: return
        case let .missing(date) where Date.now.timeIntervalSince(date) < FixedChoices.faviconRetryAge: return
        default: break
        }
        status[key] = .loading
        if status.count > 4_000 { trimStatus(keeping: key) }
        Task { [weak self, weak webView] in await self?.load(key, page: page, webView: webView) }
    }

    private func load(_ key: Key, page: URL, webView: WKWebView?) async {
        var database: AppDatabase?
        if case let .profile(profile) = key.scope { database = await databases?(profile) }
        var existing: Data?
        if let database, let stored = try? await database.favicon(forHost: key.site) {
            if Date.now.timeIntervalSince(stored.updatedAt) < FixedChoices.faviconRefreshAge {
                status[key] = .stored
                return
            }
            existing = stored.data
        } else if let data = memoryData[key] {
            existing = data
        }
        // The page went elsewhere while the database answered: its next load asks again.
        guard let webView, FaviconRules.siteKey(for: webView.url) == key.site else {
            status[key] = nil
            return
        }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.faviconFetch, id: signposter.makeSignpostID())
        let candidates = await Self.reportedIcons(in: webView, page: page)
        let data = await Self.fetch(FaviconRules.ranked(candidates, page: page))
        signposter.endInterval(Signposts.faviconFetch, interval, "\(data == nil ? "none" : "stored")")
        // Cleared or forgotten meanwhile (Clear History and Data, the private session's end): an
        // icon fetched before that is not kept after it.
        guard case .loading = status[key] else { return }
        guard let data else {
            // A failed refresh keeps the icon there was.
            status[key] = existing == nil ? .missing(.now) : .stored
            return
        }
        if let database {
            try? await database.saveFavicon(Favicon(host: key.site, data: data, updatedAt: .now))
        } else {
            keepInMemory(data, for: key)
        }
        status[key] = .stored
        absent.remove(key)
        guard data != existing else { return }
        revisions[key, default: 0] += 1
        onChange?(key.site)
    }

    private func keepInMemory(_ data: Data, for key: Key) {
        if memoryData.updateValue(data, forKey: key) == nil { memoryOrder.append(key) }
        while memoryOrder.count > FixedChoices.faviconPrivateSites {
            let oldest = memoryOrder.removeFirst()
            memoryData[oldest] = nil
            status[oldest] = nil
        }
    }

    /// A long session visited thousands of sites: forget which were settled (they are asked again
    /// on their next visit, one database read each).
    private func trimStatus(keeping key: Key) {
        status = status.filter { entry in
            if entry.key == key || memoryData[entry.key] != nil { return true }
            if case .loading = entry.value { return true }
            return false
        }
        absent = []
    }

    // MARK: Forgetting

    /// The private session ended: its icons go with it.
    func endPrivateSession() {
        let isPrivate: (Key) -> Bool = { $0.scope == .privateTabs }
        memoryData = memoryData.filter { !isPrivate($0.key) }
        memoryOrder.removeAll(where: isPrivate)
        status = status.filter { !isPrivate($0.key) }
        revisions = revisions.filter { !isPrivate($0.key) }
        absent = absent.filter { !isPrivate($0) }
        privateCache.removeAllObjects()
    }

    /// Clear History and Data removed the stored icons: memory follows, and lists show letters
    /// until the sites are visited again.
    func clear() {
        status = [:]
        revisions = [:]
        absent = []
        memoryData = [:]
        memoryOrder = []
        cache.removeAllObjects()
        privateCache.removeAllObjects()
        epoch += 1
        onChange?(nil)
    }

    /// A deleted profile's icons leave memory (its database is deleted by the shell).
    public func forget(profile: ProfileID) {
        let scope = SiteIconScope.profile(profile)
        status = status.filter { $0.key.scope != scope }
        revisions = revisions.filter { $0.key.scope != scope }
        absent = absent.filter { $0.scope != scope }
        memoryData = memoryData.filter { $0.key.scope != scope }
        memoryOrder.removeAll { $0.scope == scope }
    }

    /// Decoded icons are dropped on a memory warning; they decode again from the database.
    func dropMemoryCache() {
        cache.removeAllObjects()
        privateCache.removeAllObjects()
    }

    // MARK: The page's icons

    /// Asked once per site: the page's icon links. Nothing is injected into pages for it.
    private static let reportSource = """
        const out = [];
        for (const link of document.querySelectorAll('link[rel][href]')) {
          const rel = (link.getAttribute('rel') || '').toLowerCase().split(/\\s+/);
          const touch = rel.includes('apple-touch-icon') || rel.includes('apple-touch-icon-precomposed');
          if (!touch && !rel.includes('icon')) continue;
          out.push({ href: link.href, touch: touch, sizes: link.getAttribute('sizes') || '',
                     type: link.getAttribute('type') || '' });
          if (out.length >= 16) break;
        }
        return out;
        """

    private static func reportedIcons(in webView: WKWebView, page: URL) async -> [FaviconCandidate] {
        let reported: [ReportedIcon] = await withWebKitTimeout(fallback: [], timeout: .seconds(1)) { done in
            webView.callAsyncJavaScript(reportSource, arguments: [:], in: nil, in: UserScripts.world) { result in
                let entries = (try? result.get()) as? [[String: Any]] ?? []
                done(entries.compactMap { entry in
                    guard let href = entry["href"] as? String else { return nil }
                    return ReportedIcon(
                        href: href, isTouchIcon: entry["touch"] as? Bool ?? false,
                        sizes: entry["sizes"] as? String ?? "", type: entry["type"] as? String ?? ""
                    )
                })
            }
        }
        return reported.compactMap {
            FaviconRules.candidate(href: $0.href, isTouchIcon: $0.isTouchIcon, sizes: $0.sizes, type: $0.type, page: page)
        }
    }

    private nonisolated struct ReportedIcon: Sendable {
        let href: String
        let isTouchIcon: Bool
        let sizes: String
        let type: String
    }

    // MARK: Off the main thread

    /// No cookies, no cache, no credentials: an icon request says nothing about the person.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = FixedChoices.faviconTimeout
        configuration.timeoutIntervalForResource = FixedChoices.faviconTimeout * 2
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    /// The first of `urls` that downloads and decodes, as a PNG no larger than
    /// `FixedChoices.faviconStoredPixelSize`.
    @concurrent
    private nonisolated static func fetch(_ urls: [URL]) async -> Data? {
        for url in urls {
            var request = URLRequest(url: url)
            request.setValue("image/png,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
            guard let (bytes, response) = try? await session.bytes(for: request) else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
            let limit = FixedChoices.faviconMaxBytes
            guard response.expectedContentLength <= Int64(limit) else { continue }
            var data = Data()
            data.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(limit)))))
            var tooLarge = false
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > limit {
                        tooLarge = true
                        break
                    }
                }
            } catch {
                continue
            }
            guard !tooLarge, let stored = normalized(data) else { continue }
            return stored
        }
        return nil
    }

    /// The largest image in `data` (an .ico holds several), scaled down to the stored size, as PNG.
    nonisolated static func normalized(_ data: Data) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        var best = (index: -1, side: 0)
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            if min(width, height) > best.side { best = (index, min(width, height)) }
        }
        // A tracking pixel is no icon.
        guard best.index >= 0, best.side >= 8 else { return nil }
        let thumbnail = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: FixedChoices.faviconStoredPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, best.index, thumbnail) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Decodes a stored icon at `pixelSize` square and reads its style from the pixels.
    @concurrent
    nonisolated static func decode(_ data: Data, pixelSize: Int, plated: Bool) async -> SiteIcon? {
        decodeNow(data, pixelSize: pixelSize, plated: plated)
    }

    nonisolated static func decodeNow(_ data: Data, pixelSize: Int, plated: Bool) -> SiteIcon? {
        guard pixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let thumbnail = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail),
              let bitmap = Bitmap(side: pixelSize) else { return nil }
        // Aspect fit, centered; a 16 px icon is scaled up smoothly rather than left tiny.
        let scale = CGFloat(pixelSize) / CGFloat(max(image.width, image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let side = CGFloat(pixelSize)
        bitmap.context.interpolationQuality = .high
        bitmap.context.draw(
            image, in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
        )
        let style = bitmap.style()
        guard plated else {
            guard let result = bitmap.context.makeImage() else { return nil }
            return SiteIcon(image: UIImage(cgImage: result), style: style)
        }
        // On a tile of its own: a light rounded square under a shape, rounded corners on a full one.
        guard let plate = Bitmap(side: pixelSize), let drawn = bitmap.context.makeImage() else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        plate.context.addPath(CGPath(roundedRect: bounds, cornerWidth: side * 0.22, cornerHeight: side * 0.22, transform: nil))
        plate.context.clip()
        if style == .tile {
            plate.context.draw(drawn, in: bounds)
        } else {
            plate.context.setFillColor(
                style == .lightGlyph ? CGColor(red: 0.04, green: 0.13, blue: 0.2, alpha: 1) : CGColor(gray: 0.97, alpha: 1)
            )
            plate.context.fill(bounds)
            plate.context.interpolationQuality = .high
            plate.context.draw(drawn, in: bounds.insetBy(dx: side * 0.14, dy: side * 0.14))
        }
        guard let result = plate.context.makeImage() else { return nil }
        return SiteIcon(image: UIImage(cgImage: result), style: .tile)
    }
}

/// A square RGBA bitmap the icon is drawn into: decoded once, and readable for its style.
private nonisolated struct Bitmap {
    let context: CGContext
    let side: Int

    init?(side: Int) {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        self.context = context
        self.side = side
    }

    func style() -> SiteIconStyle {
        guard let data = context.data else { return .tile }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var clear = 0
        var solid = 0
        var dark = 0
        var light = 0
        for index in 0..<(side * side) {
            let offset = index * 4
            let alpha = Double(pixels[offset + 3])
            if alpha < 26 {
                clear += 1
                continue
            }
            // Half-clear edge pixels say little about the shape's tone.
            guard alpha > 128 else { continue }
            solid += 1
            let luminance = (0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])) / alpha
            if luminance < FaviconRules.darkLuminance { dark += 1 }
            if luminance > FaviconRules.lightLuminance { light += 1 }
        }
        let total = Double(side * side)
        let shape = Double(max(solid, 1))
        return SiteIconStyle.style(clear: Double(clear) / total, dark: Double(dark) / shape, light: Double(light) / shape)
    }
}

private nonisolated final class CacheKey: NSObject {
    private let scope: SiteIconScope
    private let site: String
    private let revision: Int
    private let pixelSize: Int
    private let plated: Bool

    init(scope: SiteIconScope, site: String, revision: Int, pixelSize: Int, plated: Bool) {
        self.scope = scope
        self.site = site
        self.revision = revision
        self.pixelSize = pixelSize
        self.plated = plated
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(scope)
        hasher.combine(site)
        hasher.combine(revision)
        hasher.combine(pixelSize)
        hasher.combine(plated)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CacheKey else { return false }
        return scope == other.scope && site == other.site && revision == other.revision
            && pixelSize == other.pixelSize && plated == other.plated
    }
}

private nonisolated final class IconBox {
    let icon: SiteIcon
    init(_ icon: SiteIcon) { self.icon = icon }
}
#endif
