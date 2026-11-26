import Foundation

/// The app icon colorways (Brand/tools/gen_icon.py, `COLORWAYS`). Dawn is the app icon; the others
/// are alternate icons, compiled from `Brand/AppIcon-<Name>.icon` and named in project.yml
/// (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`).
public nonisolated enum AppIconChoice: String, CaseIterable, Sendable, Identifiable {
    case dawn = "Dawn"
    case night = "Night"
    case coral = "Coral"
    case paper = "Paper"

    public var id: String { rawValue }

    /// The label under the icon.
    public var title: String { rawValue }

    /// The name `UIApplication.setAlternateIconName` takes; nil is the app icon itself.
    public var alternateIconName: String? {
        self == .dawn ? nil : "AppIcon-\(rawValue)"
    }

    /// The choice the system reports as the current icon (`UIApplication.alternateIconName`).
    public init(alternateIconName: String?) {
        self = Self.allCases.first { $0.alternateIconName == alternateIconName } ?? .dawn
    }

    /// The rendered preview (Brand/tools/icon_previews.sh), 180 px.
    public var previewURL: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "png", subdirectory: "AppIcons")
    }

    /// Words for VoiceOver: what the colorway looks like.
    public var accessibilityDescription: String {
        switch self {
        case .dawn: "Dawn: paper ring on a blue lagoon, the default"
        case .night: "Night: paper ring on deep blue, with a moonrise"
        case .coral: "Coral: paper ring on coral, with a blue fold"
        case .paper: "Paper: ink ring on cream paper"
        }
    }
}

#if os(iOS)
import PerfSignposts
import UIKit

/// Reads and changes the Home Screen icon. The system shows its own "You have changed the icon"
/// alert after a change; Plain adds nothing on top.
@MainActor
public enum AppIcons {
    public static var current: AppIconChoice {
        AppIconChoice(alternateIconName: UIApplication.shared.alternateIconName)
    }

    /// Switches the icon. Returns false when the system refused (it then keeps the old icon).
    @discardableResult
    public static func set(_ choice: AppIconChoice) async -> Bool {
        guard UIApplication.shared.supportsAlternateIcons, choice != current else { return true }
        let interval = Signposts.signposter.beginInterval(Signposts.appIconChange)
        defer { Signposts.signposter.endInterval(Signposts.appIconChange, interval) }
        do {
            try await UIApplication.shared.setAlternateIconName(choice.alternateIconName)
            return true
        } catch {
            return false
        }
    }

    /// The preview image. The bundle lookup, the read and the decode all run off the main thread.
    public static func preview(_ choice: AppIconChoice) async -> UIImage? {
        await load(choice)
    }

    @concurrent private static func load(_ choice: AppIconChoice) async -> UIImage? {
        guard let url = choice.previewURL, let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return await image.byPreparingForDisplay()
    }
}
#endif
