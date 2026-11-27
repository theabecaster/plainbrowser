import Foundation

/// Browse for Me's rules that need no web view or model (docs/decisions.md, "Browse for Me result
/// source"): which results page to read, which of its links are organic results, and how much of
/// each page fits the model's context.
public enum BrowseForMe {
    // MARK: Results pages

    /// How to find the organic results on one engine's results page, run as CSS selectors in a
    /// hidden web view (`Intelligence.ResultsPageReader`).
    public struct Recipe: Sendable, Equatable, Codable {
        /// The result links, in page order.
        public var links: String
        /// Containers of ads: a link inside one is never a result.
        public var ads: String

        public init(links: String, ads: String) {
            self.links = links
            self.ads = ads
        }
    }

    /// One results page to read: the engine's own when Plain can parse it, else DuckDuckGo's
    /// lite page.
    public struct ResultsPage: Sendable, Equatable {
        /// The engine's name, for the progress line ("Searching DuckDuckGo").
        public var engineName: String
        public var url: URL
        public var recipe: Recipe
        /// The page may build its results with script (Bing); DuckDuckGo's lite page
        /// is plain HTML, so it loads with JavaScript off.
        public var needsJavaScript: Bool
        /// The engine's own hosts: links to them are navigation, never results.
        public var engineHosts: [String]
    }

    /// DuckDuckGo's lite page: plain HTML, light and stable, the default source. Its results are
    /// `a.result-link`; sponsored rows carry `result-sponsored`, and ad links go through `y.js`.
    static let duckDuckGoLite = Recipe(links: "a.result-link", ads: ".result-sponsored")

    /// The recipes for engines whose own results page Plain reads, by engine id. Checked against
    /// the live pages in a hidden view (2026-11-27): Bing's titles are `h2`s inside the result's
    /// link, and its links go straight to the sites. Not here, so their users get DuckDuckGo's
    /// lite page (docs/research/browse-for-me.md): Google answers a hidden view with its "turn on
    /// JavaScript" page and no results; Brave links its results through encrypted `/go/v1#…`
    /// redirects that can't be read without following them.
    static let recipes: [String: (recipe: Recipe, hosts: [String])] = [
        SearchEngine.bing.id: (
            Recipe(links: "#b_results > li.b_algo a:has(h2)", ads: ".b_ad, .b_adTop, .b_adBottom"),
            ["bing.com", "microsoft.com"]
        ),
    ]

    /// The results pages to try for `query`, in order: the user's engine when Plain has a recipe
    /// for it (Bing), then DuckDuckGo's lite page. Every other engine, DuckDuckGo's own included,
    /// goes straight to the lite page.
    public static func resultsPages(for query: String, engine: SearchEngine) -> [ResultsPage] {
        var pages: [ResultsPage] = []
        if let (recipe, hosts) = recipes[engine.id], let url = engine.resultsURL(for: query) {
            pages.append(ResultsPage(engineName: engine.name, url: url, recipe: recipe, needsJavaScript: true, engineHosts: hosts))
        }
        if let lite = liteURL(for: query) {
            pages.append(ResultsPage(
                engineName: SearchEngine.duckDuckGo.name, url: lite, recipe: duckDuckGoLite, needsJavaScript: false,
                engineHosts: ["duckduckgo.com"]
            ))
        }
        return pages
    }

    static func liteURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: SearchEngine.queryValueAllowed) ?? query
        return URL(string: "https://lite.duckduckgo.com/lite/?q=\(encoded)")
    }

    // MARK: Organic results

    /// A link the results page offered, as the hidden view read it.
    public struct Link: Sendable, Equatable, Codable {
        public var href: String
        public var title: String
        /// The link sits inside one of the recipe's ad containers.
        public var isAd: Bool

        public init(href: String, title: String, isAd: Bool = false) {
            self.href = href
            self.title = title
            self.isAd = isAd
        }
    }

    /// A result to read.
    public struct Result: Sendable, Equatable {
        public var url: URL
        public var title: String

        public init(url: URL, title: String) {
            self.url = url
            self.title = title
        }
    }

    /// The organic results among `links`, in page order: ads and their redirects out, the
    /// engine's own pages out, engines' redirect links unwrapped, sites whose pages hold no
    /// readable text out (`FixedChoices.browseSkippedSites`), and one page per site, so five
    /// sources are five points of view. At most `limit`.
    public static func organicResults(
        _ links: [Link], engineHosts: [String], limit: Int = FixedChoices.browseCandidates
    ) -> [Result] {
        var results: [Result] = []
        var sites = Set<String>()
        for link in links where !link.isAd {
            guard results.count < limit, let raw = URL(string: link.href), let url = unwrap(raw),
                  let host = url.host()?.lowercased(), isWeb(url)
            else { continue }
            if isAdRedirect(raw) || isAdRedirect(url) { continue }
            if engineHosts.contains(where: { matches(host, $0) }) { continue }
            if FixedChoices.browseSkippedSites.contains(where: { matches(host, $0) }) { continue }
            let site = siteName(url)
            guard sites.insert(site).inserted else { continue }
            let title = link.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            results.append(Result(url: url, title: title.isEmpty ? site : title))
        }
        return results
    }

    /// The destination of an engine's redirect link: DuckDuckGo's `/l/?uddg=`, Google's
    /// `/url?q=` and Bing's `/ck/a?…&u=a1<base64>`. Other links are returned as they are.
    public static func unwrap(_ url: URL) -> URL? {
        guard let host = url.host()?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return url }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let path = url.path()
        if matches(host, "duckduckgo.com"), path.hasPrefix("/l/"), let target = value("uddg") {
            return URL(string: target)
        }
        if matches(host, "google.") || matches(host, "google.com"), path == "/url" {
            return (value("q") ?? value("url")).flatMap(URL.init(string:))
        }
        if matches(host, "bing.com"), path.hasPrefix("/ck/"), let encoded = value("u"), encoded.hasPrefix("a1") {
            var base64 = String(encoded.dropFirst(2)).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))
        }
        return url
    }

    /// Ad clicks that go through an engine: DuckDuckGo's `y.js`, Bing's `aclick`, Google's
    /// `/aclk` and `googleadservices.com`.
    static func isAdRedirect(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let path = url.path()
        if matches(host, "duckduckgo.com"), path.hasPrefix("/y.js") { return true }
        if matches(host, "bing.com"), path.hasPrefix("/aclick") { return true }
        if matches(host, "google.") || matches(host, "google.com"), path.hasPrefix("/aclk") { return true }
        return matches(host, "googleadservices.com") || matches(host, "doubleclick.net")
    }

    static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    /// `host` is `domain` or under it. A domain ending in a dot ("google.") matches every
    /// country domain of the name ("google.com", "www.google.co.uk").
    static func matches(_ host: String, _ domain: String) -> Bool {
        if domain.hasSuffix(".") {
            let name = String(domain.dropLast())
            return host.split(separator: ".").contains { $0 == name }
        }
        return host == domain || host.hasSuffix("." + domain)
    }

    /// A site's name as the pill shows it: the host without `www.`.
    public static func siteName(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Fitting the model's context

    /// How many characters of source text a prompt can carry: the context window less the
    /// instructions, the answer's room and a margin, at a conservative characters-per-token
    /// rate (`FixedChoices.summaryCharactersPerToken`). The model then counts the real prompt.
    public static func sourceCharacters(contextTokens: Int) -> Int {
        let tokens = contextTokens - FixedChoices.summaryReservedTokens - FixedChoices.summaryResponseTokens
        return max(0, Int(Double(tokens) * FixedChoices.summaryCharactersPerToken))
    }

    /// Splits `budget` characters between `texts`: a short text keeps all of itself and its
    /// unused share goes to the longer ones, so no room is wasted. Each text is cut at a
    /// paragraph or sentence end where it can be (`excerpt`).
    public static func fit(_ texts: [String], budget: Int) -> [String] {
        guard !texts.isEmpty else { return [] }
        var shares = Array(repeating: 0, count: texts.count)
        var left = max(0, budget)
        var open = Array(texts.indices)
        // Water-filling: every open text gets an equal share; the ones that need less close.
        while !open.isEmpty, left > 0 {
            let share = left / open.count
            guard share > 0 else { break }
            var stillOpen: [Int] = []
            for index in open {
                let need = texts[index].count - shares[index]
                let given = min(need, share)
                shares[index] += given
                left -= given
                if shares[index] < texts[index].count { stillOpen.append(index) }
            }
            open = stillOpen
        }
        return texts.indices.map { excerpt(texts[$0], limit: shares[$0]) }
    }

    /// The start of `text`, at most `limit` characters, ending at the last paragraph or sentence
    /// end that fits when one is near the limit.
    public static func excerpt(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 0 else { return "" }
        let cut = text.prefix(limit)
        let floor = cut.index(cut.startIndex, offsetBy: Int(Double(limit) * 0.75))
        for mark in ["\n\n", ". ", "\n"] {
            if let range = cut.range(of: mark, options: .backwards), range.lowerBound >= floor {
                return String(cut[..<range.lowerBound]) + (mark == ". " ? "." : "")
            }
        }
        return String(cut)
    }

    /// A long page brought to `limit` characters for Summarize Page: its opening (where articles
    /// put what matters) and then paragraphs spread evenly over the rest, in their own order, so
    /// the summary covers the whole page in one pass of the model. A page that fits is returned
    /// whole.
    public static func condense(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let opening = Int(Double(limit) * FixedChoices.summaryOpeningShare)
        var kept: [Int] = []
        var used = 0
        var index = 0
        while index < paragraphs.count, used + paragraphs[index].count + 2 <= opening {
            kept.append(index)
            used += paragraphs[index].count + 2
            index += 1
        }
        if kept.isEmpty { return excerpt(text, limit: limit) }
        let rest = Array(index..<paragraphs.count)
        if !rest.isEmpty {
            // Every nth of the remaining paragraphs, n chosen so the picks fill what is left.
            let average = max(1, rest.reduce(0) { $0 + paragraphs[$1].count + 2 } / rest.count)
            let room = max(0, limit - used)
            let picks = max(1, min(rest.count, room / average))
            let step = Double(rest.count) / Double(picks)
            var position = step / 2
            while Int(position) < rest.count {
                let paragraph = rest[Int(position)]
                if used + paragraphs[paragraph].count + 2 <= limit {
                    kept.append(paragraph)
                    used += paragraphs[paragraph].count + 2
                }
                position += step
            }
        }
        return kept.map { paragraphs[$0] }.joined(separator: "\n\n")
    }
}
