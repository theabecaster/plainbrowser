/// The quiet word the resting address pill puts before the host ("Not Secure — host"), naming the
/// one thing about the page the user most needs to know (docs/decisions.md, "The pill's lead
/// word"). At most one shows, so the host always keeps its room.
///
/// Precedence: Private, then Reader or Translated, then Not Secure. Private changes what Plain
/// keeps (no history, data gone at the close), so it is the one a wrong guess costs most. Reader
/// and Translated say that what is on screen is not the page as the site sent it, which the user
/// sees at once and must know how to leave. Not Secure is about the connection, and the page
/// sheet's host still says it under any other word.
public enum PillLead: Equatable, Sendable {
    case `private`
    case reader
    case translated
    case notSecure

    /// The lead for a page in this state; nil when the host stands alone.
    public static func resolve(isPrivate: Bool, isReader: Bool, isTranslated: Bool, notSecure: Bool) -> PillLead? {
        if isPrivate { return .private }
        // The reader shows the article's text; a translated page under it is not what is on screen.
        if isReader { return .reader }
        if isTranslated { return .translated }
        if notSecure { return .notSecure }
        return nil
    }

    /// The word, sentence case as the pill shows it.
    public var word: String {
        switch self {
        case .private: "Private"
        case .reader: "Reader"
        case .translated: "Translated"
        case .notSecure: "Not Secure"
        }
    }
}
