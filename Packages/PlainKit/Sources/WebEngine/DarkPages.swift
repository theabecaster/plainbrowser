#if canImport(UIKit)
import BrowserCore
import UIKit
import WebKit

/// What dark pages is doing on a tab's page (`Tab.darkPages`), for the current document only. The
/// shell maps it to the indicator in the pill and the Site Settings item (docs/state-rules.md,
/// sections 3 and 4) and offers the suggestion on `.available`.
public enum DarkPagesState: String, Sendable, Equatable {
    /// Nothing to do: the app is light, the page is not a web page, or the page is still deciding.
    case inactive
    /// The site has its own dark design (or asked to stay light), so it is left alone.
    case native
    /// Plain darkens the page.
    case darkened
    /// The page could use it, and the user turned dark pages off for this site.
    case offForSite = "off"
    /// The page could use it, but the switch is off and the site has no choice of its own.
    case available

    /// The state rules' view of it.
    public var page: DarkPagesPage {
        switch self {
        case .inactive, .native: .none
        case .darkened: .darkened
        case .offForSite: .off
        case .available: .available
        }
    }
}

/// The default page appearance and each site's own, remembered automatically like the other
/// per-site choices. The engine builds each page's script from `choices` and the pool sets each
/// web view's colors from them, so it must answer from memory, complete at launch (the shell keeps
/// a launch copy), with writes behind it.
public protocol PageAppearanceStore: AnyObject {
    var choices: PageAppearanceChoices { get }
    /// Sets `site`'s own appearance, or clears it (nil: the site follows the default).
    func setAppearance(_ appearance: PageAppearance?, forSite site: String)
}

/// Page appearance kept in memory: tests and previews.
public final class InMemoryPageAppearanceStore: PageAppearanceStore {
    public var choices: PageAppearanceChoices

    public init(defaultAppearance: PageAppearance? = FixedChoices.defaultPageAppearance) {
        choices = PageAppearanceChoices(defaultAppearance: defaultAppearance)
    }

    public func setAppearance(_ appearance: PageAppearance?, forSite site: String) {
        choices.sites[site] = appearance
    }
}

/// A private session's choices over the persistent ones: the default and the regular sites read
/// through, the session's own site choices kept in memory and dropped with it. Nothing a private
/// tab picks is saved, and it never changes the default.
final class LayeredPageAppearanceStore: PageAppearanceStore {
    private let base: any PageAppearanceStore
    private var own: [String: PageAppearance?] = [:]

    init(base: any PageAppearanceStore) {
        self.base = base
    }

    var choices: PageAppearanceChoices {
        var choices = base.choices
        for (site, appearance) in own { choices.sites[site] = appearance }
        return choices
    }

    func setAppearance(_ appearance: PageAppearance?, forSite site: String) {
        own[site] = .some(appearance)
    }
}

/// Dark pages: while the app is dark, a page without a dark design of its own is darkened, as
/// Safari does, where the user turned it on: the switch (Settings > Appearance > Dark Pages, off
/// by default) or a site's own choice. The research and the choice of technique are in
/// docs/research/dark-mode.md; the opt-in in docs/research/dark-pages-optin.md.
///
/// One user script per page, main frame only, at document start, in the engine's content world
/// (the page can't see or undo it); same-origin frames get it on request (`frameScript`) and
/// follow the page. It never touches a site that has a dark design: it looks for
/// a `color-scheme` that includes dark (or `only light`, a site's way of saying "never darken
/// me"), for `prefers-color-scheme: dark` rules in the style sheets it can read, and for a light
/// background with the page's own colors. Only a page that fails all three is darkened.
///
/// Darkening goes color by color, by role (`DarkPagesEngine.swift`): light backgrounds turn dark,
/// dark text turns light, and what is already dark (a black hero, a dark card) or already light
/// (white text on it) stays exactly as made. Pictures, video, canvases, other origins' frames,
/// emoji and colored logos are never changed; only black-and-white logo pictures are inverted, as
/// Safari does.
///
/// Where it applies, while the app is dark and the page has not been judged yet, a guard keeps the
/// page's background dark, so a page never flashes white before it is darkened. Where it doesn't
/// apply, nothing of Plain's touches the page: after load, one light check (sliced, only while
/// the page is visible) says whether the page could use it, for the indicator, Site Settings and
/// the suggestion. The script follows `prefers-color-scheme` live, so switching the app or iOS
/// between light and dark applies or removes the darkening without a reload.
enum DarkPages {
    /// The message handler the script reports its state to (`DarkPagesState` raw values).
    static let handlerName = "plainDarkPages"

    /// The area past a darkened page's edges: white as dark pages turns it
    /// (`FixedChoices.darkPagesBackgroundLightness`, about #181818), so overscroll matches the page.
    static let overscrollColor = UIColor(white: 24 / 255, alpha: 1)

    /// The script for one kind of tab, with the default and the sites' own page appearances.
    static func userScript(choices: PageAppearanceChoices) -> WKUserScript {
        WKUserScript(
            source: source(choices: choices), injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: UserScripts.world
        )
    }

    /// The first line of every dark-pages script, so the pool can tell it from the others.
    private static let marker = "// Plain dark pages"

    static func isDarkPagesScript(_ script: WKUserScript) -> Bool {
        script.source.hasPrefix(marker)
    }

    /// Tells the page's script whether dark pages applies to it now, and whether its site is off
    /// by the user's hand, then waits two animation frames so the change is on screen, and answers
    /// with the document's token (nil without an engine). For `callAsyncJavaScript`.
    static func setChoiceBody(applies: Bool, siteOff: Bool) -> String {
        """
        const engine = globalThis.__plainDarkPages;
        if (!engine) return null;
        engine.setChoice(\(applies), \(siteOff));
        await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
        return engine.doc;
        """
    }

    /// The same without waiting, for pages off screen.
    static func setChoiceSource(applies: Bool, siteOff: Bool) -> String {
        "globalThis.__plainDarkPages && globalThis.__plainDarkPages.setChoice(\(applies), \(siteOff));"
    }

    /// Asks a page dark pages doesn't apply to to check itself again (its address changed without
    /// a new document: a single-page app).
    static let recheckSource = "globalThis.__plainDarkPages && globalThis.__plainDarkPages.recheck();"

    static func source(choices: PageAppearanceChoices) -> String {
        // Dark darkens; Off and Light never do (Light pages are shown in light colors anyway).
        let on = choices.sites(choosing: .dark).sorted().map(jsString).joined(separator: ",")
        let off = choices.sites(choosing: .off).union(choices.sites(choosing: .light)).sorted().map(jsString).joined(separator: ",")
        // In a frame (put there by `frameScript`'s request) the engine runs only when the top
        // page's engine is reachable: a frame of the same origin, in the same world. It follows
        // the top page's choice (TOP). Only HTML documents: an image or a PDF shows in WebKit's
        // own viewer.
        return """
            \(marker)
            (() => {
              if (!/^https?:$/.test(location.protocol) || globalThis.__plainDarkPages) return;
              if (document.contentType && !/html/i.test(document.contentType)) return;
              let TOP = null;
              if (window !== window.top) {
                try { TOP = window.top.__plainDarkPages || null; } catch (e) {}
                if (!TOP) return;
              }
              const ENABLED = \(choices.defaultAppearance == .dark);
              const ON_SITES = new Set([\(on)]);
              const OFF_SITES = new Set([\(off)]);
              \(engineConstants)
              \(engineBody)
            })();
            """
    }

    /// Same-origin frames (an article's embedded page, a comment thread, a widget) are darkened
    /// with the page. Every frame gets this one-line check at document start, not the engine: a
    /// frame of another origin can't reach the top page and stops at once, so ad and video frames
    /// cost nothing. A frame that can asks the app for the engine (`frameRequest`), and holds its
    /// background dark meanwhile while the top page is dark or still being judged. The top page
    /// asks again for frames that were there before it turned dark.
    static let frameScript = WKUserScript(
        source: """
            // Plain dark frames
            (() => {
              if (window === window.top || !/^https?:$/.test(location.protocol)) return;
              let top = null;
              try { top = window.top.__plainDarkPages || null; } catch (e) {}
              if (!top) return;
              let asked = false;
              const ask = () => {
                if (asked || globalThis.__plainDarkPages) return;
                asked = true;
                try { webkit.messageHandlers.\(handlerName).postMessage({ \(frameRequest): true }); } catch (e) {}
              };
              globalThis.__plainDarkFrame = ask;
              if (!top.framesWanted) return;
              const guard = new CSSStyleSheet();
              guard.replaceSync('html, body { background-color: rgb(24, 24, 24) !important; }');
              document.adoptedStyleSheets = [...document.adoptedStyleSheets, guard];
              globalThis.__plainDarkFrameGuard = guard;
              ask();
            })();
            """,
        injectionTime: .atDocumentStart, forMainFrameOnly: false, in: UserScripts.world
    )

    /// The key of a frame's request for the engine.
    static let frameRequest = "frame"

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
