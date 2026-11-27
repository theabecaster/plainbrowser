import CoreGraphics
import Foundation

/// Desktop or mobile site.
nonisolated public enum ContentMode: String, Sendable, Codable, Equatable {
    case mobile, desktop
}

/// Pure decisions the navigation handlers make. No WebKit types, so they test without a web view.
nonisolated enum NavigationRules {
    enum SchemeKind: Equatable {
        /// http and https.
        case web
        /// Handled inside the web view: about, blob, data, javascript, and test schemes the pool
        /// registered.
        case inPage
        /// Another app's scheme (`mailto:`, `tel:`, `itms-apps:`, ...).
        case external
    }

    static let inPageSchemes: Set<String> = ["about", "blob", "data", "javascript", "file"]

    static func schemeKind(of url: URL, extraInPageSchemes: Set<String> = []) -> SchemeKind {
        guard let scheme = url.scheme?.lowercased() else { return .inPage }
        if scheme == "http" || scheme == "https" { return .web }
        if inPageSchemes.contains(scheme) || extraInPageSchemes.contains(scheme) { return .inPage }
        return .external
    }

    /// An `http://` address WebKit's HTTPS-first try can't help: a local or private host (an IP
    /// address, `localhost`, `.local`, `.localhost`, `.internal`, `.home.arpa`, or a one-word
    /// intranet name), or an explicit port other than 80. None of these has a public certificate,
    /// and a server on an HTTP port that gets a TLS hello usually just waits, so the upgrade sat
    /// on a blank page for seconds before falling back. These load as asked; every other
    /// `http://` address still tries HTTPS first (`FixedChoices.httpsUpgradeAlwaysOn`).
    static func keepsHTTPAsRequested(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host()?.lowercased(), !host.isEmpty else {
            return false
        }
        if let port = url.port, port != 80 { return true }
        let bare = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        if bare.contains(":") { return true }  // IPv6 literal
        if bare.split(separator: ".").count == 4, bare.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        if !bare.contains(".") { return true }  // localhost, an intranet name
        let localSuffixes = [".local", ".localhost", ".internal", ".home.arpa", ".lan"]
        return localSuffixes.contains { bare.hasSuffix($0) }
    }

    /// Desktop on a pane whose shorter side is at least `EngineChoices.desktopMinimumSide`.
    static func contentMode(forPaneSize size: CGSize) -> ContentMode {
        min(size.width, size.height) >= EngineChoices.desktopMinimumSide ? .desktop : .mobile
    }

    /// True when a `Content-Disposition` header asks for a download.
    static func isAttachment(contentDisposition: String?) -> Bool {
        guard let value = contentDisposition?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return value == "attachment" || value.hasPrefix("attachment;") || value.hasPrefix("attachment ")
    }

    enum ResponseDecision: Equatable { case allow, download, cancel }

    /// Main frame: attachments and types WebKit can't show become downloads; PDFs and anything
    /// else WebKit renders show inline. Subframes download only on an explicit attachment, so an
    /// ad iframe can't drop a file by serving an odd type.
    static func responseDecision(isMainFrame: Bool, canShowMIMEType: Bool, contentDisposition: String?)
        -> ResponseDecision
    {
        if isAttachment(contentDisposition: contentDisposition) { return .download }
        if canShowMIMEType { return .allow }
        return isMainFrame ? .download : .cancel
    }

    /// WebKit shows these inline as a PDF page.
    static func isPDF(mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        return mimeType == "application/pdf" || mimeType == "text/pdf" || mimeType == "application/x-pdf"
    }

    /// The site key for remembered choices: the host without a leading `www.`.
    static func siteKey(for url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Whether a tapped link leaves the current site (universal links open only then, like Safari).
    static func isCrossSite(from current: URL?, to target: URL) -> Bool {
        guard let targetSite = siteKey(for: target) else { return false }
        return siteKey(for: current) != targetSite
    }

    static let certificateErrorCodes: Set<Int> = [
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorSecureConnectionFailed,
    ]

    static func isCertificateError(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && certificateErrorCodes.contains(error.code)
            && error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] != nil
    }

    /// Errors that are not worth an error page: a cancelled load (the user stopped it or a new
    /// navigation replaced it) and WebKit's "frame load interrupted" after a download decision.
    static func isSilentError(_ error: NSError) -> Bool {
        (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
    }

    /// A download file name that is safe to write: no path separators, no leading dots, not empty.
    static func sanitizedFilename(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "download" : String(cleaned.prefix(200))
    }
}

/// Counts events per key within a sliding window: popups, dialogs, external-app prompts and crash
/// reloads per tab.
nonisolated struct RateLimiter {
    let limit: Int
    let window: Duration
    private var events: [UUID: [ContinuousClock.Instant]] = [:]

    init(limit: Int, window: Duration) {
        self.limit = limit
        self.window = window
    }

    /// Records an event and returns whether it is within the limit.
    mutating func allow(_ key: UUID, at now: ContinuousClock.Instant = .now) -> Bool {
        var recent = events[key, default: []].filter { now - $0 < window }
        guard recent.count < limit else {
            events[key] = recent
            return false
        }
        recent.append(now)
        events[key] = recent
        return true
    }

    mutating func reset(_ key: UUID) {
        events[key] = nil
    }
}
