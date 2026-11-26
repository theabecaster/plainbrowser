/// Every value Plain decides for the user instead of offering a setting (AGENTS.md, "Opinionated
/// and simple"). Each one has its reason next to it. Code reads these instead of repeating them.
public enum FixedChoices {
    /// The search engine on first launch: the one most people already expect (docs/plan.md,
    /// section 11).
    public static let defaultSearchEngine = SearchEngine.google

    /// Tab gallery width, in points, from which it shows the wide grid. Below it the gallery is
    /// a phone-sized card list; above it there is room for twice the columns.
    public static let tabGalleryWideWidth: Double = 640

    /// Tab gallery columns below and above `tabGalleryWideWidth`. Always even, so on the Duo's
    /// inner screen no card straddles the fold (docs/plan.md, section 6).
    public static let tabGalleryColumns = (narrow: 2, wide: 4)
}
