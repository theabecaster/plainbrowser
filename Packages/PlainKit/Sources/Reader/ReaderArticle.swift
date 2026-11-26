import Foundation

/// A page's main article, as Readability extracted it.
public struct ReaderArticle: Sendable, Equatable, Codable {
    /// The article title.
    public var title: String
    /// The author line, if the page names one.
    public var byline: String?
    /// The publication's name, if the page names one.
    public var siteName: String?
    /// The article body as cleaned HTML. Readability has removed scripts and made links and image
    /// sources absolute. Show it only in the reader web view, where page JavaScript is off.
    public var contentHTML: String
    /// The length of the article's text, in characters.
    public var textLength: Int
    /// The page's language (`<html lang>`), if it has one.
    public var lang: String?
    /// The text direction (`ltr` or `rtl`), if the page sets one.
    public var dir: String?
    /// A short summary: the page's description, or the first paragraph.
    public var excerpt: String?
    /// The address of the page the article came from.
    public var url: URL?

    public init(
        title: String, byline: String? = nil, siteName: String? = nil, contentHTML: String,
        textLength: Int, lang: String? = nil, dir: String? = nil, excerpt: String? = nil, url: URL? = nil
    ) {
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.contentHTML = contentHTML
        self.textLength = textLength
        self.lang = lang
        self.dir = dir
        self.excerpt = excerpt
        self.url = url
    }
}
