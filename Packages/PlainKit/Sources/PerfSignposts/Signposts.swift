import os

/// The signposts every user-visible interaction emits (AGENTS.md rule 5). The app emits them and
/// the UI tests measure them by these exact names, so both sides read them from here.
///
/// See them live: Instruments > os_signpost, subsystem `dev.abrahamgonzalez.plainbrowser`.
public enum Signposts {
    public static let subsystem = "dev.abrahamgonzalez.plainbrowser"
    public static let category = "perf"

    public static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// Interval from `main` entering to the search field becoming first responder.
    public static let launch: StaticString = "launch"
    /// Event: the search field became first responder at launch.
    public static let searchFieldReady: StaticString = "launch.searchFieldReady"
    /// Interval: the pool creating the warm web view after the first frame.
    public static let webViewWarmUp: StaticString = "webView.warmUp"
    /// Interval: the user submitting the address bar, until the load is handed to the web view
    /// (parsing the input, getting a web view, starting the load).
    public static let addressSubmit: StaticString = "address.submit"
    /// Interval from a navigation starting to its first content committing.
    public static let navCommit: StaticString = "nav.commit"
    /// Interval from a navigation starting to it finishing (or failing).
    public static let navFinish: StaticString = "nav.finish"

    /// `StaticString` names as `String`, for `XCTOSSignpostMetric(subsystem:category:name:)`.
    public static func name(_ name: StaticString) -> String {
        name.description
    }
}
