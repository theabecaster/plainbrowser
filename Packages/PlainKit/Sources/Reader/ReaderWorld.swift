/// Reader mode runs Mozilla's readability.js in its own `WKContentWorld`, so page scripts can
/// neither see nor tamper with it. The script and the UI arrive after v0.1 (docs/plan.md, section 7).
public enum ReaderWorld {
    /// The name of the content world Readability runs in.
    public static let contentWorldName = "dev.abrahamgonzalez.plainbrowser.reader"
}
