#if canImport(UIKit)
import BrowserCore
import UIKit
import WebKit

/// What dark pages is doing on a tab's page (`Tab.darkPages`). The page menu offers "Turn Off
/// Dark Pages for This Site" only on `.darkened`, and "Turn On" only on `.offForSite`
/// (docs/state-rules.md, section 4).
public enum DarkPagesState: String, Sendable, Equatable {
    /// Nothing to do: the app is light, the page is not a web page, or the page is still deciding.
    case inactive
    /// The site has its own dark design (or asked to stay light), so it is left alone.
    case native
    /// Plain darkens the page.
    case darkened
    /// The user turned dark pages off for this site; the page shows as the site made it.
    case offForSite = "off"
}

/// The sites where the user turned dark pages off, remembered automatically like the other
/// per-site choices. The engine builds each page's script from `offSites`, so it must answer
/// from memory: load the stored list at launch and write changes behind it.
public protocol SiteDarkPagesStore: AnyObject {
    var offSites: Set<String> { get }
    func setDarkPagesOff(_ off: Bool, forSite site: String)
}

/// Dark pages choices kept in memory: the default until Storage provides a persistent store.
public final class InMemorySiteDarkPagesStore: SiteDarkPagesStore {
    public private(set) var offSites: Set<String> = []

    public init() {}

    public func setDarkPagesOff(_ off: Bool, forSite site: String) {
        if off { offSites.insert(site) } else { offSites.remove(site) }
    }
}

/// A private session's choices over the persistent ones: read through, written in memory.
final class LayeredDarkPagesStore: SiteDarkPagesStore {
    private let base: any SiteDarkPagesStore
    private var own: [String: Bool] = [:]

    init(base: any SiteDarkPagesStore) {
        self.base = base
    }

    var offSites: Set<String> {
        var sites = base.offSites
        for (site, off) in own {
            if off { sites.insert(site) } else { sites.remove(site) }
        }
        return sites
    }

    func setDarkPagesOff(_ off: Bool, forSite site: String) {
        own[site] = off
    }
}

/// Dark pages: while the app is dark, a page without a dark design of its own is darkened, as
/// Safari does. The research and the choice of technique are in docs/research/dark-mode.md.
///
/// One user script per page, main frame only, at document start, in the engine's content world
/// (the page can't see or undo it). It never touches a site that has a dark design: it looks for
/// a `color-scheme` that includes dark (or `only light`, a site's way of saying "never darken
/// me"), for `prefers-color-scheme: dark` rules in the style sheets it can read, and for a light
/// background with the page's own colors. Only a page that fails all three is darkened.
///
/// Darkening goes color by color, by role (`DarkPagesEngine.swift`): light backgrounds turn dark,
/// dark text turns light, and what is already dark (a black hero, a dark card) or already light
/// (white text on it) stays exactly as made. Pictures, video, canvases, frames, emoji and colored
/// logos are never changed.
///
/// While the app is dark and the page has not been judged yet, a guard keeps the page's
/// background dark, so a page never flashes white before it is darkened; it goes as soon as the
/// page shows it has dark styles of its own. The script follows `prefers-color-scheme` live, so
/// switching the app or iOS between light and dark applies or removes the darkening without a
/// reload.
enum DarkPages {
    /// The message handler the script reports its state to (`DarkPagesState` raw values).
    static let handlerName = "plainDarkPages"

    /// The area past a darkened page's edges: white as dark pages turns it
    /// (`FixedChoices.darkPagesBackgroundLightness`, about #181818), so overscroll matches the page.
    static let overscrollColor = UIColor(white: 24 / 255, alpha: 1)

    /// The script for one kind of tab, with the sites where dark pages is off.
    static func userScript(offSites: Set<String>) -> WKUserScript {
        WKUserScript(
            source: source(offSites: offSites), injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: UserScripts.world
        )
    }

    /// The first line of every dark-pages script, so the pool can tell it from the others.
    private static let marker = "// Plain dark pages"

    static func isDarkPagesScript(_ script: WKUserScript) -> Bool {
        script.source.hasPrefix(marker)
    }

    /// Asks the page's script to turn off (true) or back on (false) for this page now.
    static func setOffSource(_ off: Bool) -> String {
        "globalThis.__plainDarkPages && globalThis.__plainDarkPages.setOff(\(off));"
    }

    static func source(offSites: Set<String>) -> String {
        let sites = offSites.sorted().map(jsString).joined(separator: ",")
        guard FixedChoices.darkPagesOn else { return marker }
        return """
            \(marker)
            (() => {
              if (window !== window.top || !/^https?:$/.test(location.protocol)) return;
              const OFF_SITES = new Set([\(sites)]);
              \(engineConstants)
              \(engineBody)
            })();
            """
    }

    private static func jsString(_ text: String) -> String {
        let escaped = text.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "\\": return "\\\\"
            case "\"": return "\\\""
            default:
                return scalar.isASCII && scalar.value >= 0x20 ? String(scalar) : String(format: "\\u%04x", scalar.value)
            }
        }.joined()
        return "\"\(escaped)\""
    }
}
#endif
