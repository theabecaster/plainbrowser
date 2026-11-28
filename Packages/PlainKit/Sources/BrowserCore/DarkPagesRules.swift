import Foundation

// Page appearance and its one suggestion, as plain values (docs/decisions.md, "Page appearance";
// docs/research/dark-pages-optin.md). How websites look, separate from Plain's own Appearance
// (System, Light, Dark), which only ever colors Plain. The engine darkens; these say what each
// site gets and whether to ask.

/// How a website is shown.
public enum PageAppearance: String, Sendable, Equatable, Codable, CaseIterable {
    /// As the site made it: a site with a light and a dark design follows Plain's colors, one with
    /// a single design shows it. Plain changes nothing.
    case off
    /// Dark: the site's own dark design where it has one, Plain's darkening where it doesn't.
    case dark
    /// Light: the site's own light design. A site made only in dark stays as it is: there is no
    /// faithful way to lighten a dark design (docs/decisions.md).
    case light
}

/// The default for every site, and the sites with a choice of their own.
public struct PageAppearanceChoices: Sendable, Equatable, Codable {
    /// The default for every site that has no choice of its own; nil until the user first picks
    /// one (it then behaves as `.off`).
    public var defaultAppearance: PageAppearance?
    /// Each site's own choice (an exception to the default).
    public var sites: [String: PageAppearance]

    public init(defaultAppearance: PageAppearance? = nil, sites: [String: PageAppearance] = [:]) {
        self.defaultAppearance = defaultAppearance
        self.sites = sites
    }

    /// What `site` gets: its own choice, else the default.
    public func appearance(for site: String) -> PageAppearance {
        sites[site] ?? defaultAppearance ?? .off
    }

    /// Whether `site` has a choice of its own (the control says "This Site").
    public func hasOwnChoice(_ site: String) -> Bool { sites[site] != nil }

    /// Whether Plain may darken `site`'s pages (it still darkens only a page without a dark design).
    public func darkens(_ site: String) -> Bool { appearance(for: site) == .dark }

    /// The sites with each choice of their own, for the engine's script.
    public func sites(choosing appearance: PageAppearance) -> Set<String> {
        Set(sites.filter { $0.value == appearance }.keys)
    }

    /// What a pick from the control did.
    public enum Outcome: Sendable, Equatable {
        /// The first pick ever: it became the default for every site.
        case becameDefault(previous: PageAppearance?)
        /// It applies to this site only.
        case thisSite
    }

    /// A pick from the control on a page of `site` (docs/decisions.md, "Page appearance"):
    /// - The first pick ever, while there is no default yet, becomes the default for every site
    ///   (the choice is learned: "save it for other pages").
    /// - After that, a pick is for this site only; picking what the default already is clears the
    ///   site's own choice, so it follows the default again.
    @discardableResult
    public mutating func choose(_ appearance: PageAppearance, for site: String) -> Outcome {
        guard let current = defaultAppearance else {
            defaultAppearance = appearance
            sites[site] = nil
            return .becameDefault(previous: nil)
        }
        sites[site] = appearance == current ? nil : appearance
        return .thisSite
    }

    /// Undoes a first pick that became the default: the default goes back to `previous` and the
    /// pick stays for `site` only ("This Site Only" on the toast).
    public mutating func keepForThisSiteOnly(_ appearance: PageAppearance, site: String, previous: PageAppearance?) {
        defaultAppearance = previous
        sites[site] = appearance == (previous ?? .off) ? nil : appearance
    }

    /// "Use for All Sites": what `site` shows becomes the default. Other sites' own choices stay.
    public mutating func useForAllSites(from site: String) {
        defaultAppearance = appearance(for: site)
        sites[site] = nil
        // Every other site's own choice stays, even one that now matches: it was the user's
        // answer for that site, and it must survive the next change of the default.
    }
}

/// The one suggestion to turn Dark Pages on: shown on a light page in dark colors until the user
/// answers it. Kept in user defaults (it is not a setting), and kept through Clear History and
/// Data: it records an answer, not browsing.
public enum DarkPagesSuggestion: Sendable, Equatable, Codable {
    case neverAsked
    /// Shown and not answered (it left by itself, or something replaced it), last on `site` in
    /// app session `session`.
    case ignored(site: String, session: Int)
    /// No Thanks.
    case declined
    /// Turn On, a default chosen in Settings, or a page appearance picked by hand.
    case accepted

    /// Whether it may show on a page of `site` now. The page itself (dark colors, light, no
    /// design of its own, a regular tab, nothing else up) is the shell's and the engine's to check;
    /// this is only the answer so far. After being ignored, it waits for another site in a later
    /// session ("next time"): help shouldn't repeat within a session (NN/g).
    public func mayShow(onSite site: String, session: Int) -> Bool {
        switch self {
        case .neverAsked: true
        case .ignored(let last, let lastSession): last != site && session > lastSession
        case .declined, .accepted: false
        }
    }

    /// It showed on `site`: until answered, it counts as ignored.
    public func shown(onSite site: String, session: Int) -> DarkPagesSuggestion {
        switch self {
        case .neverAsked, .ignored: .ignored(site: site, session: session)
        case .declined, .accepted: self
        }
    }

    public var isAnswered: Bool { self == .declined || self == .accepted }

    /// Everything the shell knows when the suggestion's moment comes.
    public struct Moment: Sendable, Equatable {
        /// The page on screen: only `.available` asks (light colors are always `.none`).
        public var page: DarkPagesPage
        public var isPrivate: Bool
        /// The saved settings were read, so Turn On saves over what the user really has.
        public var settingsLoaded: Bool
        /// The bar shows whole (not collapsed or hidden), so the card has the pill to sit by.
        public var isBarShowing: Bool
        /// The keyboard, a sheet, the gallery, a menu, the reader, Find or another toast is up.
        public var isBusy: Bool
        /// The user already chose how websites look (a default page appearance): nothing to ask.
        public var hasDefault: Bool

        public init(
            page: DarkPagesPage, isPrivate: Bool, settingsLoaded: Bool, isBarShowing: Bool, isBusy: Bool,
            hasDefault: Bool = false
        ) {
            self.hasDefault = hasDefault
            self.page = page
            self.isPrivate = isPrivate
            self.settingsLoaded = settingsLoaded
            self.isBarShowing = isBarShowing
            self.isBusy = isBusy
        }
    }

    /// Whether the suggestion shows now on a page of `site`. Never in light colors (the page is
    /// never `.available` there), never in a private tab (the answer is app-wide and remembered),
    /// never over something else.
    public func shouldShow(onSite site: String, session: Int, at moment: Moment) -> Bool {
        moment.page == .available && !moment.hasDefault && !moment.isPrivate && moment.settingsLoaded && moment.isBarShowing
            && !moment.isBusy && mayShow(onSite: site, session: session)
    }
}

/// Where the suggestion's state lives: a user-defaults key (`TestIsolation.defaults` in an
/// isolated run, so tests never touch the owner's answer).
public final class DarkPagesSuggestionStore: @unchecked Sendable {
    static let key = "PlainDarkPagesSuggestion"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = TestIsolation.defaults) {
        self.defaults = defaults
    }

    public var state: DarkPagesSuggestion {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let state = try? JSONDecoder().decode(DarkPagesSuggestion.self, from: data) else { return .neverAsked }
            return state
        }
        set {
            guard newValue != state, let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    static let sessionKey = "PlainDarkPagesSession"

    /// The app session the suggestion counts in: one per launch and per return from the
    /// background, kept across launches so "a later session" survives a relaunch.
    public var session: Int { defaults.integer(forKey: Self.sessionKey) }

    public func beginSession() {
        defaults.set(session + 1, forKey: Self.sessionKey)
    }

    /// An answer is final: once answered, nothing moves it back.
    public func answer(_ accepted: Bool) {
        guard !state.isAnswered else { return }
        state = accepted ? .accepted : .declined
    }
}
