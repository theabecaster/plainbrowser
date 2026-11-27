import Foundation

// Features the user, a parent (Screen Time) or iOS itself can switch off for Plain, and what Plain
// says when one is off (docs/research/permissions-states.md, docs/ui-reference.md "Switched-off
// features"). Pure values and rules: the system is read in WebEngine (`SystemAccessMonitor`), the
// words are shown by the shell. Tested on macOS.

/// Something Plain needs from iOS that can be switched off.
public nonisolated enum SystemFeature: String, Sendable, CaseIterable, Codable {
    /// Websites' camera (WebKit's media capture).
    case camera
    /// Websites' microphone.
    case microphone
    /// Websites' location (WebKit asks Core Location, while in use).
    case location
    /// Adding images to Photos (Save Image).
    case photos
    /// Cellular data for Plain.
    case cellular
}

/// What iOS lets Plain do with a feature right now.
public nonisolated enum SystemAccess: String, Sendable, Equatable, Codable {
    /// Never asked: iOS asks the first time a site (or Save Image) needs it.
    case notDetermined
    case allowed
    /// The user turned it off for Plain (Settings > Plain).
    case denied
    /// Screen Time or a device profile doesn't allow it; the user can't turn it on in Plain's
    /// settings.
    case restricted
    /// Location Services are off for the whole phone (location only).
    case servicesOff

    /// Plain can't use the feature, and asking won't change that.
    public var isBlocked: Bool {
        switch self {
        case .denied, .restricted, .servicesOff: true
        case .notDetermined, .allowed: false
        }
    }
}

/// The one quiet line Plain shows when something the user wanted is blocked by a switched-off
/// feature: a toast (a site's request, Save Image) or the error page (cellular data).
public nonisolated struct SystemAccessNotice: Sendable, Equatable {
    public var message: String
    /// "Settings" opens Plain's page in the Settings app. False where Plain's page can't change it
    /// (Screen Time): then the line explains and offers nothing.
    public var opensSettings: Bool

    public init(message: String, opensSettings: Bool) {
        self.message = message
        self.opensSettings = opensSettings
    }
}

/// How Site Settings shows a permission a site has asked for.
public nonisolated enum SitePermissionValue: Sendable, Equatable {
    /// The user allowed this site, and iOS lets Plain use the feature (or will ask).
    case allowed
    /// The user said Don't Allow for this site.
    case notAllowed
    /// Off for Plain in Settings: no site can use it until it is turned back on there.
    case offInSettings
    /// Screen Time or a profile doesn't allow it on this phone.
    case notAllowedOnPhone

    /// The row's value, as Settings rows show theirs.
    public var label: String {
        switch self {
        case .allowed: "Allowed"
        case .notAllowed: "Not Allowed"
        case .offInSettings: "Off in Settings"
        case .notAllowedOnPhone: "Off on This iPhone"
        }
    }
}

public nonisolated enum SystemAccessRules {
    /// The line for a request that needs `features`, or nil when none of them is blocked (iOS will
    /// ask, or already allows them). Names only the blocked ones, in Plain's words.
    public static func notice(
        for features: [SystemFeature], access: (SystemFeature) -> SystemAccess
    ) -> SystemAccessNotice? {
        var seen = Set<SystemFeature>()
        let blocked = features.filter { seen.insert($0).inserted && access($0).isBlocked }
        guard !blocked.isEmpty else { return nil }
        // Screen Time wins: Plain's page in Settings can't change it, so no button.
        if blocked.contains(where: { access($0) == .restricted }) {
            let restricted = blocked.filter { access($0) == .restricted }
            let verb = restricted.count > 1 ? "aren't" : "isn't"
            return SystemAccessNotice(message: "\(names(restricted)) \(verb) allowed on this iPhone", opensSettings: false)
        }
        if blocked == [.location], access(.location) == .servicesOff {
            return SystemAccessNotice(message: "Location Services are off", opensSettings: true)
        }
        let verb = blocked.count > 1 ? "are" : "is"
        return SystemAccessNotice(message: "\(names(blocked)) \(verb) off for Plain", opensSettings: true)
    }

    /// Save Image when Plain may not add to Photos.
    public static func photosNotice(_ access: SystemAccess) -> SystemAccessNotice? {
        switch access {
        case .denied: SystemAccessNotice(message: "Saving to Photos is off for Plain", opensSettings: true)
        case .restricted: SystemAccessNotice(message: "Saving to Photos isn't allowed on this iPhone", opensSettings: false)
        case .notDetermined, .allowed, .servicesOff: nil
        }
    }

    /// A site permission's row in Site Settings: the site's remembered answer under what iOS
    /// allows. Nil when the site never asked (no row).
    public static func siteValue(remembered: Bool?, system: SystemAccess) -> SitePermissionValue? {
        guard let remembered else { return nil }
        switch system {
        case .restricted: return .notAllowedOnPhone
        case .denied, .servicesOff: return .offInSettings
        case .notDetermined, .allowed: return remembered ? .allowed : .notAllowed
        }
    }

    /// "Camera", "Camera and microphone".
    static func names(_ features: [SystemFeature]) -> String {
        let words = features.enumerated().map { index, feature in
            let word = name(feature)
            return index == 0 ? word : word.lowercased()
        }
        return ListFormatter.localizedString(byJoining: words)
    }

    static func name(_ feature: SystemFeature) -> String {
        switch feature {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .photos: "Photos"
        case .cellular: "Cellular data"
        }
    }
}

/// Which explanations a site has had, so each shows once per site until what iOS allows changes:
/// a site that asks for the location on every page gets one line, not one per page. Kept in
/// memory only, so Plain keeps no record of which sites asked.
public nonisolated struct SystemAccessNoticeMemory: Sendable {
    private var shown: Set<String> = []

    public init() {}

    /// True the first time `site` is told about `notice` for these features in their current
    /// state; false after that.
    public mutating func shouldShow(
        _ features: [SystemFeature], site: String, access: (SystemFeature) -> SystemAccess
    ) -> Bool {
        let blocked = features.filter { access($0).isBlocked }
        guard !blocked.isEmpty else { return false }
        let keys = blocked.map { "\($0.rawValue) \(access($0).rawValue) \(site)" }
        guard keys.contains(where: { !shown.contains($0) }) else { return false }
        shown.formUnion(keys)
        return true
    }

    /// What iOS allows for `features` changed: their sites may be told again.
    public mutating func forget(_ features: Set<SystemFeature>) {
        let prefixes = features.map { $0.rawValue + " " }
        shown = shown.filter { key in !prefixes.contains { key.hasPrefix($0) } }
    }
}

/// Why the network is unreachable for Plain when it is Plain's own switch, not the connection.
public nonisolated enum NetworkBlock: Sendable, Equatable {
    /// Cellular data is off for Plain, and there is no Wi-Fi.
    case cellularOffForPlain
    /// Wireless data is off for Plain (the WLAN switch some regions have).
    case wifiOffForPlain

    public var notice: SystemAccessNotice {
        switch self {
        case .cellularOffForPlain: SystemAccessNotice(message: "Cellular data is off for Plain.", opensSettings: true)
        case .wifiOffForPlain: SystemAccessNotice(message: "Wi-Fi is off for Plain.", opensSettings: true)
        }
    }

    /// From what the path monitor and Core Telephony report when a load failed for want of the
    /// network. `cellularDenied` is the path's own reason; `cellularRestricted` is Core
    /// Telephony's answer for Plain (`CTCellularData`), which also covers a phone with cellular
    /// that is simply out of Wi-Fi.
    public static func from(
        cellularDenied: Bool, wifiDenied: Bool, cellularRestricted: Bool, hasWiFi: Bool
    ) -> NetworkBlock? {
        if wifiDenied { return .wifiOffForPlain }
        if cellularDenied || (cellularRestricted && !hasWiFi) { return .cellularOffForPlain }
        return nil
    }
}
