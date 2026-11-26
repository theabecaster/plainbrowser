#if canImport(UIKit)
import Foundation
import Security

/// Certificates the user chose to trust on the certificate-error interstitial, per host, until the
/// app quits (like Safari). Only the exact leaf certificate they saw is trusted, so a different
/// bad certificate for the same host shows the interstitial again.
final class ServerTrustExceptions {
    private var leaves: [String: Data] = [:]

    func allow(_ trust: SecTrust, forHost host: String) {
        guard let leaf = Self.leaf(of: trust) else { return }
        leaves[host.lowercased()] = leaf
    }

    func matches(_ trust: SecTrust, forHost host: String) -> Bool {
        guard let allowed = leaves[host.lowercased()] else { return false }
        return Self.leaf(of: trust) == allowed
    }

    func contains(host: String) -> Bool {
        leaves[host.lowercased()] != nil
    }

    private static func leaf(of trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        return SecCertificateCopyData(leaf) as Data
    }
}

/// Permission answers kept in memory. The default until Storage provides a persistent store, and
/// the store for private tabs.
public actor InMemorySitePermissionStore: SitePermissionStore {
    private var answers: [String: Bool] = [:]

    public init() {}

    public func isAllowed(_ permission: SitePermission, forSite site: String) -> Bool? {
        answers["\(permission.rawValue) \(site)"]
    }

    public func setAllowed(_ allowed: Bool, _ permission: SitePermission, forSite site: String) {
        answers["\(permission.rawValue) \(site)"] = allowed
    }
}

/// Desktop/mobile choices kept in memory. The default until Storage provides a persistent store,
/// and the store for private tabs.
public final class InMemorySiteContentModeStore: SiteContentModeStore {
    private var modes: [String: ContentMode] = [:]

    public init() {}

    public func contentMode(forSite site: String) -> ContentMode? {
        modes[site]
    }

    public func setContentMode(_ mode: ContentMode?, forSite site: String) {
        modes[site] = mode
    }
}

/// Page zooms kept in memory. The default until Storage provides a persistent store, and the
/// store for private tabs.
public final class InMemorySitePageZoomStore: SitePageZoomStore {
    private var zooms: [String: Double] = [:]

    public init() {}

    public func pageZoom(forSite site: String) -> Double? {
        zooms[site]
    }

    public func setPageZoom(_ zoom: Double?, forSite site: String) {
        zooms[site] = zoom
    }
}
#endif
