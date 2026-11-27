import Foundation

/// Something the system asks Plain to do: from an App Intent (Shortcuts, Siri, Spotlight, a
/// Control Center control), a widget tap, a Spotlight result or a Handoff. The app turns each into
/// one browser action (`BrowserViewController.perform`).
public enum PlainCommand: Hashable, Sendable {
    /// The search field, focused, in a new tab (the widget, the "Search in Plain" control).
    case focusSearch
    /// Search for the text with the engine chosen in Settings, in a new tab.
    case search(String)
    /// Open a web page in a new tab.
    case open(URL)
    case newTab
    case newPrivateTab
    /// The tab switcher.
    case showTabs
}

/// The `plainbrowser:` links widgets use to reach the app (`widgetURL`, `Link`), and the reverse:
/// a link the app receives turned back into a command. A plain `http` or `https` link is an open.
///
/// The scheme is registered in the app's Info.plist, so any app can use these links. Each one does
/// only what a tap in Plain does (open a page, a tab, the search field), so that is safe.
public enum PlainLink {
    public static let scheme = "plainbrowser"

    public static func url(for command: PlainCommand) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        switch command {
        case .focusSearch: components.host = "search"
        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .open(let url):
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        case .newTab: components.host = "new-tab"
        case .newPrivateTab: components.host = "private-tab"
        case .showTabs: components.host = "tabs"
        }
        // Every part above is valid, so this never fails.
        return components.url!
    }

    /// The command `url` stands for, or nil when it is neither a Plain link nor a web page.
    public static func command(from url: URL) -> PlainCommand? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" { return .open(url) }
        guard scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let value = { (name: String) in components.queryItems?.first { $0.name == name }?.value }
        switch components.host?.lowercased() {
        case "search":
            guard let query = value("q")?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return .focusSearch
            }
            return .search(query)
        case "open":
            // Only web pages: a Plain link never opens another scheme.
            guard let address = value("url"), let page = URL(string: address),
                  let pageScheme = page.scheme?.lowercased(), pageScheme == "http" || pageScheme == "https"
            else { return nil }
            return .open(page)
        case "new-tab": return .newTab
        case "private-tab": return .newPrivateTab
        case "tabs": return .showTabs
        default: return nil
        }
    }
}
