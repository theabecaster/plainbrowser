import BrowserCore
import Foundation

/// Whether the first-run intro shows on this launch, and the flag that remembers it was seen.
///
/// The app reads `shouldShow` once as its scene connects. After the intro was seen that is the
/// only intro code on the launch path: one defaults read, and none of the intro's views or layers
/// are made.
public nonisolated enum IntroGate {
    /// The user-defaults key. Also a launch argument (`-PlainIntroSeen YES`), which the argument
    /// domain turns into the same value: the perf and smoke tests pass it, in Release too.
    public static let seenKey = "PlainIntroSeen"

    /// Launch arguments, Debug builds only:
    /// - `-PlainShowIntro`: show the intro even when it was seen (screenshots, the intro's UI test).
    /// - `-PlainInMemoryStore`, `-PlainTestStore`: UI tests of the browser; no intro unless
    ///   `-PlainShowIntro` is also given.
    public static func shouldShow(arguments: [String], defaults: UserDefaults = .standard) -> Bool {
        guard FixedChoices.introShownOnce else { return false }
        #if DEBUG
        if arguments.contains("-PlainShowIntro") { return true }
        if arguments.contains("-PlainInMemoryStore") || arguments.contains("-PlainTestStore") { return false }
        #endif
        return !defaults.bool(forKey: seenKey)
    }

    /// Records that the intro was finished or skipped, so it never shows again.
    public static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}

/// The intro's default-browser step and the empty-tab card share one switch:
/// `FixedChoices.defaultBrowserPromptsEnabled`, plus a Debug launch argument to see them.
public nonisolated enum DefaultBrowserPrompts {
    /// User-defaults key: the empty-tab card was dismissed, so it stays away.
    public static let cardDismissedKey = "PlainDefaultBrowserCardDismissed"

    /// `-PlainForceDefaultBrowserPrompts` (Debug builds) shows both while the entitlement is missing.
    public static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        if arguments.contains("-PlainForceDefaultBrowserPrompts") { return true }
        #endif
        return FixedChoices.defaultBrowserPromptsEnabled
    }

    /// Whether the empty start screen should show the card: prompts on, and not dismissed before.
    public static func showsEmptyTabCard(
        arguments: [String] = ProcessInfo.processInfo.arguments, defaults: UserDefaults = .standard
    ) -> Bool {
        isEnabled(arguments: arguments) && !defaults.bool(forKey: cardDismissedKey)
    }

    public static func dismissEmptyTabCard(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: cardDismissedKey)
    }
}
