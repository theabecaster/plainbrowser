import Foundation

/// Persists the sites where the user turned blocking off ("Turn off on this site" in the page
/// menu). Blocking is always on everywhere else; there is no global switch (docs/plan.md, 4b).
///
/// The store owns persistence only. `ContentBlocker` keeps the set in memory and calls `save`
/// after every change, one save at a time, in order.
public protocol SiteAllowListStore: Sendable {
    func loadAllowedSites() async throws -> Set<String>
    func saveAllowedSites(_ sites: Set<String>) async throws
}

/// How a page's host maps to an allow-list entry.
///
/// A site is a host without a leading `www.`. An entry covers that host and its subdomains, so
/// turning blocking off on `www.example.com` also covers `example.com` and `m.example.com`, but
/// turning it off on `m.example.com` does not cover `example.com`.
public enum SiteKey {
    /// The allow-list key for `host`, or nil when there is no host (for example `about:blank`).
    public static func site(forHost host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// Whether `host` belongs to one of `sites`: equal to an entry or a subdomain of one.
    public static func host(_ host: String?, isIn sites: Set<String>) -> Bool {
        guard !sites.isEmpty, var candidate = site(forHost: host) else { return false }
        while true {
            if sites.contains(candidate) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
    }
}
