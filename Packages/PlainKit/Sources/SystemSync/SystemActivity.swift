import Foundation
import PlainShared
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

/// The command behind an activity the system hands the app: a web page continued from another
/// device (Handoff), or a tapped Spotlight result.
public enum SystemActivity {
    public static func command(from activity: NSUserActivity) -> PlainCommand? {
        if activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL {
            return PlainLink.command(from: url).flatMap { if case .open = $0 { $0 } else { nil } }
        }
        #if canImport(CoreSpotlight)
        if activity.activityType == CSSearchableItemActionType,
           let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
           let url = SpotlightItem.url(fromIdentifier: identifier) {
            return .open(url)
        }
        #endif
        return nil
    }
}
