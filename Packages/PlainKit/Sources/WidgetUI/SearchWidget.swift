#if os(iOS)
import DesignSystem
import PlainShared
import SwiftUI
import WidgetKit

/// One timeline entry: the favorites to show. The app reloads the timeline when favorites change
/// (`SystemSync`), so there is one entry and no refresh schedule.
public struct SearchEntry: TimelineEntry, Sendable {
    public let date: Date
    public let content: SearchWidgetContent

    public init(date: Date = .now, content: SearchWidgetContent) {
        self.date = date
        self.content = content
    }
}

/// Reads the favorites the app shares through the App Group. Nothing else: no network, no
/// database, no refresh until the app asks for one.
public struct SearchProvider: TimelineProvider {
    private let read: @Sendable () -> SearchWidgetContent

    /// - Parameter read: the favorites now (tests pass a fixed list).
    public init(read: @escaping @Sendable () -> SearchWidgetContent = { SearchWidgetContent(file: .shared) }) {
        self.read = read
    }

    public func placeholder(in context: Context) -> SearchEntry {
        SearchEntry(content: .sample)
    }

    public func getSnapshot(in context: Context, completion: @escaping (SearchEntry) -> Void) {
        completion(snapshot(isPreview: context.isPreview))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<SearchEntry>) -> Void) {
        completion(timeline())
    }

    /// The gallery shows the sample until the user has favorites; the Home Screen shows theirs.
    public func snapshot(isPreview: Bool) -> SearchEntry {
        let content = read()
        return SearchEntry(content: isPreview && content.favorites.isEmpty ? .sample : content)
    }

    public func timeline() -> Timeline<SearchEntry> {
        Timeline(entries: [SearchEntry(content: read())], policy: .never)
    }
}

/// The search widget: Home Screen (small, medium), StandBy (small, shown large) and the Lock
/// Screen (circular, rectangular, inline). Every tap opens Plain's search field, except a
/// favorite, which opens its page.
public struct SearchWidget: Widget {
    public static let kind = "dev.abrahamgonzalez.plainbrowser.search"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SearchProvider()) { entry in
            SearchWidgetView(entry: entry)
        }
        .configurationDisplayName("Search")
        .description("Search the web or open a favorite.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}
#endif
