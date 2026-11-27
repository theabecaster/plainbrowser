import BrowserCore
import Foundation

// Which of a page's icons Plain fetches, as plain values free of UIKit and WebKit so `swift test`
// checks them on macOS (docs/decisions.md, "Site icons").

/// One icon a page offers: a `<link rel="icon">` or `<link rel="apple-touch-icon">`.
nonisolated struct FaviconCandidate: Equatable, Sendable {
    var url: URL
    /// An apple-touch-icon: an opaque square made for a Home Screen, 180 px unless it says otherwise.
    var isTouchIcon: Bool
    /// The largest side its `sizes` names, 0 when it names none.
    var declaredSize: Int

    init(url: URL, isTouchIcon: Bool, declaredSize: Int) {
        self.url = url
        self.isTouchIcon = isTouchIcon
        self.declaredSize = declaredSize
    }
}

nonisolated enum FaviconRules {
    /// The key icons are kept under: the page's host, lowercased, without a leading "www." (the
    /// host a tab's row shows). Nil for anything but a web page.
    static func siteKey(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// The largest side named by a `sizes` attribute ("32x32", "16x16 48x48"); 0 for none or "any".
    static func declaredSize(_ sizes: String) -> Int {
        var largest = 0
        for token in sizes.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }) {
            let sides = token.split(separator: "x").compactMap { Int($0) }
            guard sides.count == 2, let side = sides.max(), side > 0 else { continue }
            largest = max(largest, side)
        }
        return largest
    }

    /// A candidate from what the page reported, or nil for one Plain can't show: not HTTP(S), a
    /// plain-HTTP icon on an HTTPS page, or a vector image (ImageIO draws no SVG).
    static func candidate(href: String, isTouchIcon: Bool, sizes: String, type: String, page: URL) -> FaviconCandidate? {
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "https" || (scheme == "http" && page.scheme?.lowercased() == "http") else { return nil }
        let path = url.path().lowercased()
        guard !type.lowercased().contains("svg"), !path.hasSuffix(".svg"), !path.hasSuffix(".svgz") else { return nil }
        return FaviconCandidate(url: url, isTouchIcon: isTouchIcon, declaredSize: declaredSize(sizes))
    }

    /// The icons to try, best first, ending with the site's `/favicon.ico`.
    ///
    /// A tab's tile shows the icon at about `FixedChoices.faviconPixelSize` pixels, so the best is
    /// the smallest icon that is at least that large: sharp, and no larger a download than needed.
    /// Then the touch icon (180 px by convention), then whatever is left, largest first. At most
    /// `FixedChoices.faviconAttempts` are tried.
    static func ranked(_ candidates: [FaviconCandidate], page: URL) -> [URL] {
        let wanted = FixedChoices.faviconPixelSize
        func size(_ candidate: FaviconCandidate) -> Int {
            if candidate.declaredSize > 0 { return candidate.declaredSize }
            return candidate.isTouchIcon ? 180 : 32
        }
        let largeEnough = candidates.filter { size($0) >= wanted }
            // Smallest that is large enough first; at the same size the page's own icon before
            // the Home Screen one.
            .sorted { (size($0), $0.isTouchIcon ? 1 : 0) < (size($1), $1.isTouchIcon ? 1 : 0) }
        let small = candidates.filter { size($0) < wanted }.sorted { size($0) > size($1) }
        var urls: [URL] = []
        for candidate in largeEnough + small where !urls.contains(candidate.url) {
            urls.append(candidate.url)
        }
        if let fallback = fallbackURL(for: page), !urls.contains(fallback) {
            urls = Array(urls.prefix(FixedChoices.faviconAttempts - 1)) + [fallback]
        }
        return Array(urls.prefix(FixedChoices.faviconAttempts))
    }

    /// Whether an icon may be downloaded from `url` for `page` (checked for the first address and
    /// every redirect). The page chooses the address and the download runs outside WebKit, so:
    /// web addresses only, no credentials in the address, no plain HTTP for an HTTPS page, and no
    /// loopback, private-network or link-local host unless it is the page's own host (a page on
    /// the local network may show its own icon; a public page can't make Plain call into one).
    static func allows(_ url: URL, from page: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased(), !host.isEmpty,
              url.user() == nil, url.password() == nil else { return false }
        if scheme == "http", page.scheme?.lowercased() != "http" { return false }
        if isLocal(host), host != page.host()?.lowercased() { return false }
        return true
    }

    /// A host on this device or the local network: localhost, `.local` and `.internal` names,
    /// single-label names, and loopback, private, link-local, carrier-NAT, multicast and
    /// unspecified addresses, IPv4 in any spelling `inet_aton` reads (decimal, hex, octal, short
    /// forms) and IPv6 in any spelling, with IPv4-mapped ones judged by the IPv4 inside. A public
    /// name that resolves to a local address is not caught here: such a request carries no
    /// cookies and its answer never reaches the page, the same reach an `<img>` on the page has.
    static func isLocal(_ host: String) -> Bool {
        var name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while name.hasSuffix(".") { name.removeLast() }
        if let zone = name.firstIndex(of: "%") { name = String(name[..<zone]) }
        guard !name.isEmpty else { return true }
        var v6 = in6_addr()
        if name.contains(":") {
            guard inet_pton(AF_INET6, name, &v6) == 1 else { return true }
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isLocalIPv4(bytes[12], bytes[13])
            }
            // Unspecified and loopback (::, ::1) and the rest of ::/96, link-local fe80::/10,
            // unique local fc00::/7, multicast ff00::/8.
            if bytes[0..<12].allSatisfy({ $0 == 0 }) { return true }
            return (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || bytes[0] & 0xfe == 0xfc || bytes[0] == 0xff
        }
        var v4 = in_addr()
        if inet_aton(name, &v4) != 0 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return isLocalIPv4(bytes[0], bytes[1])
        }
        return name == "localhost" || !name.contains(".")
            || [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".intranet", ".corp", ".home"].contains { name.hasSuffix($0) }
    }

    private static func isLocalIPv4(_ a: UInt8, _ b: UInt8) -> Bool {
        a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) || a >= 224
    }

    /// `/favicon.ico` at the page's origin.
    static func fallbackURL(for page: URL) -> URL? {
        guard var components = URLComponents(url: page, resolvingAgainstBaseURL: false),
              components.host?.isEmpty == false else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}

/// How an icon sits on its tile, decided from its pixels once, off the main thread.
public nonisolated enum SiteIconStyle: Sendable, Equatable {
    /// Opaque edge to edge (a touch icon, a photo): it is the tile.
    case tile
    /// A shape on a clear ground, in colors that show on paper and on Deep Lagoon alike.
    case glyph
    /// A dark shape on a clear ground: lost on a dark tile, so its tile stays light at night.
    case darkGlyph
    /// A light shape on a clear ground: lost on a light tile, so its tile stays dark by day.
    case lightGlyph

    /// The style for an icon whose pixels measure so: `clear`, the share of its pixels that are
    /// (nearly) transparent; `dark` and `light`, the shares of the others that are near black and
    /// near white.
    static func style(clear: Double, dark: Double, light: Double) -> SiteIconStyle {
        guard clear > FaviconRules.glyphClearShare else { return .tile }
        if dark >= FaviconRules.oneToneShare { return .darkGlyph }
        if light >= FaviconRules.oneToneShare { return .lightGlyph }
        return .glyph
    }
}

nonisolated extension FaviconRules {
    /// An icon with more clear pixels than this is a shape on a clear ground. A full square with
    /// its corners rounded off clears about 4%.
    static let glyphClearShare = 0.05
    /// A shape this much in one tone (near black, or near white) needs a tile that contrasts.
    static let oneToneShare = 0.8
    /// Luminance under this is near black, over `lightLuminance` near white.
    static let darkLuminance = 0.3
    static let lightLuminance = 0.82
}
