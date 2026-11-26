import PerfSignposts

// The tab gallery's signposts (AGENTS.md: every user-visible interaction gets one). Same
// subsystem and category as the rest of `Signposts`, so they show up in the same Instruments lane.
// Kept next to the gallery while it is built in its own lane; they move into PerfSignposts when the
// shell wires the gallery in.
extension Signposts {
    /// Interval: the page zooming into its card, until the gallery is settled.
    public static let galleryShow: StaticString = "gallery.show"
    /// Interval: a card zooming into its page, until the page is settled.
    public static let galleryOpenTab: StaticString = "gallery.openTab"
    /// Interval: a card flicked away (or closed from its button or menu), until the cards reflow.
    public static let galleryCardClose: StaticString = "gallery.cardClose"
    /// Interval: one scroll of the gallery, from the finger down until it stops moving.
    public static let galleryScroll: StaticString = "gallery.scroll"
    /// Interval: applying a new tab list to the gallery (diff and layout).
    public static let galleryReload: StaticString = "gallery.reload"
    /// Events: gallery actions with no motion of their own.
    public static let galleryNewTab: StaticString = "gallery.newTab"
    public static let galleryReopen: StaticString = "gallery.reopen"
    public static let galleryCloseAll: StaticString = "gallery.closeAll"
    public static let galleryReorder: StaticString = "gallery.reorder"
    public static let galleryMenu: StaticString = "gallery.menu"
    public static let galleryCopyLink: StaticString = "gallery.copyLink"
    public static let galleryShare: StaticString = "gallery.share"
    public static let galleryOtherPane: StaticString = "gallery.otherPane"
}
