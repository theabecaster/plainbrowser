import BrowserCore
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

/// Whether this app can change its icon, so the intro's icon step and Settings > App Icon show.
///
/// Decided from the system's capability, never the device model: `supportsAlternateIcons`, and
/// `ProcessInfo.isiOSAppOnMac` too, since an iPhone app on a Mac has a Dock icon the app cannot
/// change (macOS has no alternate icons; docs/research/notes.md, "Alternate app icons"). Where it
/// is false the picker would be a control that can do nothing (docs/state-rules.md), so neither
/// surface shows it.
public nonisolated enum AppIconSupport {
    /// The Debug override, `-PlainAlternateIcons off` (or `on`): honored only in Debug builds and
    /// isolated runs (`TestIsolation`), so a UI test can see the unsupported case on a simulator.
    public static let overrideArgument = "-PlainAlternateIcons"

    public static func isSupported(systemSupports: Bool, isiOSAppOnMac: Bool, arguments: [String]) -> Bool {
        #if DEBUG
        if TestIsolation.mode(for: arguments) != .off, let index = arguments.firstIndex(of: overrideArgument),
           index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "off": return false
            case "on": return true
            default: break
            }
        }
        #endif
        return systemSupports && !isiOSAppOnMac
    }
}

#if os(iOS)
import PerfSignposts
import UIKit

/// Reads and changes the Home Screen icon. The system shows its own "You have changed the icon"
/// alert after a change; Plain adds nothing on top.
///
/// An isolated test run (`TestIsolation`) never changes the Home Screen icon: the choice is kept in
/// memory for the run, so the picker behaves the same and the owner's icon stays.
@MainActor
public enum AppIcons {
    public static var current: AppIconChoice {
        if TestIsolation.isActive { return isolatedChoice }
        return AppIconChoice(alternateIconName: UIApplication.shared.alternateIconName)
    }

    /// Whether the icon can change here (`AppIconSupport`): the intro's icon step and Settings >
    /// App Icon show only then.
    public static var isSupported: Bool {
        AppIconSupport.isSupported(
            systemSupports: UIApplication.shared.supportsAlternateIcons,
            isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    /// The icon an isolated run has "set", starting from the default.
    private static var isolatedChoice = AppIconChoice.dawn

    /// Switches the icon. Returns false when the system refused (it then keeps the old icon).
    @discardableResult
    public static func set(_ choice: AppIconChoice) async -> Bool {
        guard choice != current else { return true }
        guard isSupported else { return false }
        if TestIsolation.isActive {
            isolatedChoice = choice
            return true
        }
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
