#if canImport(UIKit)
import BrowserCore
import Foundation
import PerfSignposts
import UIKit

/// Settings > Appearance on screen: every window of every scene (the browser, its sheets and
/// menus, the intro) gets the choice as its `overrideUserInterfaceStyle`, and System is
/// `.unspecified`, so the windows follow iOS. Web views follow their window, so sites with a dark
/// design switch with the app (`WebViewPool.interfaceStyle` covers pages off screen).
///
/// The database is the one store of the setting. It opens after the first frame, so a copy of
/// the last applied choice is kept in user defaults and read as a scene connects (one defaults
/// read, like the intro's flag): the first frame already has the user's colors instead of
/// flashing the system's and switching a moment later. The database value replaces the copy as
/// soon as it is read.
public enum AppAppearance {
    /// The user-defaults key of the launch copy.
    static let launchKey = "PlainAppearance"
    /// The crossfade when the choice changes: one whole-screen change, at the top of the motion
    /// table's 0.15–0.3 s range so the colors visibly settle rather than blink.
    static let crossfadeDuration: TimeInterval = 0.3

    /// The choice to show before the database is read: the last one applied.
    public static func launchAppearance(defaults: UserDefaults = .standard) -> Appearance {
        defaults.string(forKey: launchKey).flatMap(Appearance.init(rawValue:)) ?? FixedChoices.defaultAppearance
    }

    public static func style(for appearance: Appearance) -> UIUserInterfaceStyle {
        switch appearance {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Gives a new window the launch choice before it shows, so it never draws in other colors.
    public static func prepare(_ window: UIWindow) {
        window.overrideUserInterfaceStyle = current ?? style(for: launchAppearance())
    }

    /// The style last applied in this process, so windows made later (a new scene, the browser
    /// after the intro) match the ones on screen.
    private static var current: UIUserInterfaceStyle?

    /// Applies `appearance` to every window of every connected scene and keeps the launch copy.
    /// A window whose colors change crossfades; one already showing them is left alone.
    static func apply(_ appearance: Appearance, defaults: UserDefaults = .standard) {
        let style = style(for: appearance)
        current = style
        if defaults.string(forKey: launchKey) != appearance.rawValue {
            defaults.set(appearance.rawValue, forKey: launchKey)
        }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows where window.overrideUserInterfaceStyle != style {
            let before = window.traitCollection.userInterfaceStyle
            let resolved = style == .unspecified ? window.windowScene?.traitCollection.userInterfaceStyle : style
            guard window.isHidden == false, resolved != before else {
                // Nothing visible changes: no crossfade, just follow the new choice.
                window.overrideUserInterfaceStyle = style
                continue
            }
            Signposts.signposter.emitEvent(Signposts.appearanceChange)
            UIView.transition(
                with: window, duration: crossfadeDuration,
                options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
            ) {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
#endif
