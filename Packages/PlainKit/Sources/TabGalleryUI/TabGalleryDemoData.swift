#if canImport(UIKit)
import UIKit

/// A stand-in for the shell's tabs, for tests, previews and the screenshot host. It keeps its own
/// list, draws fake page thumbnails and site icons off the main thread, and remembers closed
/// tabs so "Reopen Tab" works.
public final class TabGalleryDemoData: TabGalleryDataSource {
    public private(set) var tabs: [TabGalleryItem]
    public private(set) var selectedTabID: UUID?
    public var canOpenInOtherPane = false
    public var canReopenClosedTab: Bool { !closed.isEmpty }

    /// Called after the user opens a tab; the host runs the open transition from here.
    public var onSelect: ((UUID) -> Void)?
    /// Called after New Tab.
    public var onNewTab: ((UUID) -> Void)?
    /// Makes `thumbnail(for:)` wait this long, to see the gallery before images arrive.
    public var thumbnailDelay: Duration = .zero

    private var closed: [(item: TabGalleryItem, index: Int)] = []
    private var thumbnails: [UUID: UIImage] = [:]
    private var sites: [UUID: Site] = [:]

    /// - Parameters:
    ///   - count: how many tabs.
    ///   - selectedIndex: the tab the page shows.
    ///   - privateIndices: tabs that are private.
    public init(count: Int, selectedIndex: Int? = 0, privateIndices: Set<Int> = []) {
        var tabs: [TabGalleryItem] = []
        var sites: [UUID: Site] = [:]
        for index in 0..<count {
            let site = Site.all[index % Site.all.count]
            let id = UUID()
            let round = index / Site.all.count
            let title = round == 0 ? site.title : "\(site.title) (\(round + 1))"
            tabs.append(TabGalleryItem(id: id, title: title, url: site.url, isPrivate: privateIndices.contains(index)))
            sites[id] = site
        }
        self.tabs = tabs
        self.sites = sites
        if let selectedIndex, tabs.indices.contains(selectedIndex) { selectedTabID = tabs[selectedIndex].id }
    }

    // MARK: TabGalleryDataSource

    public func thumbnail(for id: UUID) async -> UIImage? {
        if thumbnailDelay > .zero { try? await Task.sleep(for: thumbnailDelay) }
        if let image = thumbnails[id] { return image }
        guard let site = sites[id], let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let image = await Self.drawPage(site, variant: index)
        thumbnails[id] = image
        return image
    }

    public func favicon(for id: UUID) async -> UIImage? {
        guard let site = sites[id] else { return nil }
        return await Self.drawIcon(site)
    }

    public func selectTab(_ id: UUID) {
        selectedTabID = id
        onSelect?(id)
    }

    public func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closed.append((tabs[index], index))
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    public func closeAllTabs() {
        closed.append(contentsOf: tabs.enumerated().map { ($0.element, $0.offset) })
        tabs.removeAll()
        selectedTabID = nil
    }

    public func moveTab(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
    }

    @discardableResult public func newTab() -> UUID {
        let item = TabGalleryItem(id: UUID(), title: "", url: nil)
        tabs.append(item)
        selectedTabID = item.id
        onNewTab?(item.id)
        return item.id
    }

    @discardableResult public func reopenClosedTab() -> UUID? {
        guard let last = closed.popLast() else { return nil }
        tabs.insert(last.item, at: min(last.index, tabs.count))
        return last.item.id
    }

    public func openInOtherPane(_ id: UUID) {}

    /// A full-size fake page for `id`, as the shell would snapshot it, for the open transition.
    public func pageImage(for id: UUID, size: CGSize) async -> UIImage? {
        guard let site = sites[id], let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        return await Self.drawPage(site, variant: index, width: size.width, aspect: size.height / max(size.width, 1))
    }

    // MARK: Drawing

    struct Site: Sendable {
        let title: String
        let url: URL
        let hue: CGFloat
        let darkPage: Bool

        init(_ title: String, _ address: String, hue: CGFloat, dark: Bool = false) {
            self.title = title
            url = URL(string: address)!
            self.hue = hue
            darkPage = dark
        }

        static let all: [Site] = [
            Site("Swift.org - Concurrency", "https://www.swift.org/documentation/concurrency/", hue: 0.03),
            Site("Hacker News", "https://news.ycombinator.com", hue: 0.07),
            Site("The Verge", "https://www.theverge.com", hue: 0.83, dark: true),
            Site("Wikipedia, the free encyclopedia", "https://en.wikipedia.org/wiki/Main_Page", hue: 0.6),
            Site("GitHub: Let's build from here", "https://github.com", hue: 0.62, dark: true),
            Site("Apple Developer Documentation", "https://developer.apple.com/documentation", hue: 0.58),
            Site("Weather - Miami, FL", "https://weather.com/weather/today", hue: 0.55),
            Site("Recipes: Cuban Black Beans", "https://cooking.nytimes.com/recipes/black-beans", hue: 0.0),
            Site("MDN Web Docs", "https://developer.mozilla.org/en-US/", hue: 0.75, dark: true),
            Site("Maps", "https://maps.apple.com", hue: 0.33),
            Site("Stack Overflow - UICollectionView", "https://stackoverflow.com/questions/tagged/uicollectionview", hue: 0.08),
            Site("BBC News - Home", "https://www.bbc.com/news", hue: 0.0),
            Site("Arc Search Review", "https://www.macstories.net/reviews/arc-search", hue: 0.12),
            Site("Figma", "https://www.figma.com", hue: 0.9, dark: true),
            Site("YouTube", "https://www.youtube.com", hue: 0.0),
            Site("Reddit - r/iOSProgramming", "https://www.reddit.com/r/iOSProgramming/", hue: 0.05),
            Site("Linear", "https://linear.app", hue: 0.68, dark: true),
            Site("Amazon.com: Kindle", "https://www.amazon.com/kindle", hue: 0.1),
            Site("Netflix", "https://www.netflix.com", hue: 0.0, dark: true),
            Site("Notion", "https://www.notion.so", hue: 0.0),
        ]
    }

    @concurrent private nonisolated static func drawPage(
        _ site: Site, variant: Int, width: CGFloat = 200, aspect: CGFloat = 2.17
    ) async -> UIImage {
        let size = CGSize(width: width, height: (width * aspect).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let k = width / 200
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let page = site.darkPage ? UIColor(white: 0.09, alpha: 1) : UIColor(white: 0.995, alpha: 1)
            let ink = site.darkPage ? UIColor(white: 0.32, alpha: 1) : UIColor(white: 0.84, alpha: 1)
            let strongInk = site.darkPage ? UIColor(white: 0.82, alpha: 1) : UIColor(white: 0.16, alpha: 1)
            let brand = UIColor(hue: site.hue, saturation: 0.62, brightness: site.darkPage ? 0.75 : 0.82, alpha: 1)
            page.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            // Site header.
            brand.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 26 * k))
            UIColor.white.withAlphaComponent(0.9).setFill()
            UIBezierPath(roundedRect: CGRect(x: 10 * k, y: 8 * k, width: 50 * k, height: 10 * k), cornerRadius: 3 * k).fill()
            var y = 38 * k
            // Headline.
            strongInk.setFill()
            for line in 0..<2 {
                let w = (line == 0 ? 170 : 110) * k
                UIBezierPath(roundedRect: CGRect(x: 12 * k, y: y, width: w, height: 11 * k), cornerRadius: 3 * k).fill()
                y += 16 * k
            }
            y += 6 * k
            // A picture for most layouts.
            if variant % 3 != 1 {
                let hero = UIColor(hue: site.hue, saturation: 0.35, brightness: site.darkPage ? 0.4 : 0.9, alpha: 1)
                hero.setFill()
                UIBezierPath(roundedRect: CGRect(x: 12 * k, y: y, width: size.width - 24 * k, height: 92 * k), cornerRadius: 6 * k).fill()
                y += 104 * k
            }
            // Body text.
            ink.setFill()
            var line = 0
            while y < size.height - 10 * k {
                let w = (line % 5 == 4 ? 96 : 176 - CGFloat((line * 37) % 23)) * k
                UIBezierPath(roundedRect: CGRect(x: 12 * k, y: y, width: w, height: 6 * k), cornerRadius: 2 * k).fill()
                y += line % 5 == 4 ? 18 * k : 11 * k
                line += 1
            }
        }
    }

    @concurrent private nonisolated static func drawIcon(_ site: Site) async -> UIImage {
        let size = CGSize(width: 32, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(hue: site.hue, saturation: 0.62, brightness: 0.8, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7).fill()
            let letter = String(site.title.prefix(1)) as NSString
            let font = UIFont.systemFont(ofSize: 19, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let textSize = letter.size(withAttributes: attributes)
            letter.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
    }
}
#endif
