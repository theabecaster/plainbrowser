import Foundation

// Dark Pages' choices and its one suggestion, as plain values (docs/research/dark-pages-optin.md,
// "State model"). The engine darkens; these say whether it may, and whether to ask.

/// What the user chose for one site. A site's choice beats the switch either way.
public enum DarkPagesSiteChoice: String, Sendable, Equatable, Codable {
    /// Follow Settings > Appearance > Dark Pages.
    case automatic
    /// Darkened here even while the switch is off.
    case on
    /// Never darkened here: the user found it broken, or just prefers the site as made.
    case off
}

/// The switch and the sites with a choice of their own: everything the engine needs to know
/// whether dark pages applies to a site, at document start.
public struct DarkPagesChoices: Sendable, Equatable, Codable {
    /// Settings > Appearance > Dark Pages.
    public var enabled: Bool
    public var onSites: Set<String>
    public var offSites: Set<String>

    public init(enabled: Bool = FixedChoices.darkPagesDefaultEnabled, onSites: Set<String> = [], offSites: Set<String> = []) {
        self.enabled = enabled
        // A site in both (never written so, but read from two tables): off wins, the safe side.
        self.onSites = onSites.subtracting(offSites)
        self.offSites = offSites
    }

    public func choice(for site: String) -> DarkPagesSiteChoice {
        if offSites.contains(site) { return .off }
        if onSites.contains(site) { return .on }
        return .automatic
    }

    /// Whether dark pages applies to `site` (it still darkens only a light page in dark colors).
    public func applies(to site: String) -> Bool {
        switch choice(for: site) {
        case .on: true
        case .off: false
        case .automatic: enabled
        }
    }

    public mutating func setChoice(_ choice: DarkPagesSiteChoice, for site: String) {
        onSites.remove(site)
        offSites.remove(site)
        switch choice {
        case .automatic: break
        case .on: onSites.insert(site)
        case .off: offSites.insert(site)
        }
    }

    /// The choice a tap on the indicator (or the Site Settings item) makes: off where dark pages
    /// applies; where it doesn't, back to automatic when the switch would darken the site, on for
    /// this site when the switch is off.
    public func toggled(for site: String) -> DarkPagesSiteChoice {
        if applies(to: site) { return .off }
        return enabled ? .automatic : .on
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
    /// Turn On, the switch turned on in Settings, or a per-site choice made by hand.
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

        public init(page: DarkPagesPage, isPrivate: Bool, settingsLoaded: Bool, isBarShowing: Bool, isBusy: Bool) {
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
        moment.page == .available && !moment.isPrivate && moment.settingsLoaded && moment.isBarShowing
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
