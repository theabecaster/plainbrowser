import Foundation

/// A profile's identity. Tabs, archived tabs and recently closed tabs carry it; the web engine
/// names the profile's website data store with it (every profile but the first).
public typealias ProfileID = UUID

/// A profile: its own open tabs, archive, history, favorites, and cookies and website data
/// (docs/decisions.md, "Profiles, no tab groups"). Everything else (settings, per-site choices,
/// private tabs, downloads) belongs to the app and is shared by every profile.
///
/// There is always one: the first, "Personal", which keeps the data Plain had before profiles
/// (the default website data store and the main database). It can be renamed, never deleted.
public struct Profile: Identifiable, Hashable, Sendable, Codable {
    public let id: ProfileID
    public var name: String

    public init(id: ProfileID = ProfileID(), name: String) {
        self.id = id
        self.name = name
    }

    /// The first profile's id. Fixed, so rows written before profiles existed belong to it.
    public static let defaultID = ProfileID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// The first profile, under its default name.
    public static var personal: Profile {
        Profile(id: defaultID, name: String(localized: "Personal"))
    }

    public var isDefault: Bool { id == Self.defaultID }

    /// `name` as Plain keeps it: runs of white space folded to one space and trimmed, cut to
    /// `FixedChoices.profileNameLimit` characters. Nil when nothing is left.
    public static func cleanName(_ name: String) -> String? {
        let joined = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(FixedChoices.profileNameLimit))
    }
}
