#if DEBUG
import BrowserCore
import Foundation
import Reader

/// A stand-in model for tests and simulator UI tests (`-PlainTestSummaries`): it writes a fixed
/// summary word by word at a steady pace, citing the sources it was given, so the screen's
/// streaming, citations and finish can be checked without Apple's model.
@MainActor public final class ScriptedSummaryModel: SummaryModel {
    public var answer: AIAvailability
    public var contextTokens: Int
    /// Pause between words.
    public var pace: Duration
    /// Thrown after the first point, when set.
    public var failure: SummaryModelError?
    /// Each request the model was asked to write, for tests.
    public private(set) var requests: [SummaryRequest] = []
    public private(set) var prewarmed: [SummaryKind] = []

    public init(
        availability: AIAvailability = .available, contextTokens: Int = 8_192, pace: Duration = .milliseconds(12),
        failure: SummaryModelError? = nil
    ) {
        answer = availability
        self.contextTokens = contextTokens
        self.pace = pace
        self.failure = failure
    }

    public func availability() async -> AIAvailability { answer }

    public func prewarm(_ kind: SummaryKind) { prewarmed.append(kind) }

    /// Four characters a token, like English.
    public func tokenCount(for request: SummaryRequest) async -> Int? {
        (SummaryPrompt.instructions(SummaryKind(request.subject)).count + SummaryPrompt.prompt(request).count) / 4 + 300
    }

    public func write(_ request: SummaryRequest) -> AsyncThrowingStream<SummaryDraft, any Error> {
        requests.append(request)
        let script = Self.script(for: request)
        let pace = pace
        let failure = failure
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    var draft = SummaryDraft()
                    for (sectionIndex, section) in script.sections.enumerated() {
                        draft.sections.append(SummaryDraft.Section(heading: section.heading))
                        continuation.yield(draft)
                        for point in section.points {
                            draft.sections[sectionIndex].points.append(SummaryDraft.Point(text: ""))
                            let last = draft.sections[sectionIndex].points.count - 1
                            for word in point.text.split(separator: " ") {
                                let text = draft.sections[sectionIndex].points[last].text
                                draft.sections[sectionIndex].points[last].text = text + (text.isEmpty ? "" : " ") + word
                                continuation.yield(draft)
                                try await Task.sleep(for: pace)
                            }
                            draft.sections[sectionIndex].points[last].sources = point.sources
                            continuation.yield(draft)
                            if let failure { throw failure }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The fixed summary: three sections, citing every source given at least once.
    static func script(for request: SummaryRequest) -> SummaryDraft {
        let count = max(1, request.sources.count)
        func cite(_ index: Int) -> [Int] { [index % count + 1, (index + 1) % count + 1].uniqued() }
        let title: String
        switch request.subject {
        case .search(let query): title = "What to know about \(query)"
        case .page(let pageTitle, _): title = pageTitle
        }
        return SummaryDraft(title: title, sections: [
            .init(heading: "The short answer", points: [
                .init(text: "The pages agree on the main point and explain it in plain terms.", sources: cite(0)),
                .init(text: "Most of them add a practical example a reader can try today.", sources: cite(1)),
            ]),
            .init(heading: "Details", points: [
                .init(text: "One source goes deeper into how it works and why it matters.", sources: cite(2)),
                .init(text: "Another notes a common mistake and how to avoid it.", sources: cite(3)),
            ]),
            .init(heading: "Where they differ", points: [
                .init(text: "The sources differ on timing, so check the latest one.", sources: cite(4)),
            ]),
        ])
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// Results and pages without a network, for tests and simulator UI tests: a results page with
/// six results (one an ad, one a video site), pages that read after a short delay, one page too
/// slow for the budget and one with no text, so every source state shows.
@MainActor public final class ScriptedBrowsing: ResultsReading, PageReading {
    public var resultsDelay: Duration
    public var pageDelay: Duration
    /// Pages that never answer within any budget.
    public var slowHosts: Set<String>
    /// Pages with no readable text.
    public var emptyHosts: Set<String>
    /// When set, every results page fails with it.
    public var resultsError: (any Error)?
    /// Pages being read now, and the most at once, for tests of the memory bound.
    public private(set) var reading = 0
    public private(set) var mostAtOnce = 0
    public private(set) var cancelledReads = 0
    public private(set) var pagesAsked: [URL] = []

    public init(
        resultsDelay: Duration = .milliseconds(250), pageDelay: Duration = .milliseconds(400),
        slowHosts: Set<String> = ["slow.example"], emptyHosts: Set<String> = ["empty.example"]
    ) {
        self.resultsDelay = resultsDelay
        self.pageDelay = pageDelay
        self.slowHosts = slowHosts
        self.emptyHosts = emptyHosts
    }

    public static let links: [BrowseForMe.Link] = [
        .init(href: "https://ads.example/buy", title: "Sponsored: Buy now", isAd: true),
        .init(href: "https://www.field-notes.example/guide", title: "A field guide"),
        .init(href: "https://www.youtube.com/watch?v=1", title: "A video"),
        .init(href: "https://slow.example/story", title: "A slow story"),
        .init(href: "https://handbook.example/chapter", title: "The handbook chapter"),
        .init(href: "https://empty.example/app", title: "An app shell"),
        .init(href: "https://journal.example/2026/notes", title: "Notes from the journal"),
        .init(href: "https://weekly.example/issue", title: "This week's issue"),
        .init(href: "https://archive.example/entry", title: "An archive entry"),
    ]

    public func links(on page: BrowseForMe.ResultsPage) async throws -> [BrowseForMe.Link] {
        try await Task.sleep(for: resultsDelay)
        if let resultsError { throw resultsError }
        return Self.links
    }

    public func text(of url: URL) async throws -> ReaderText? {
        pagesAsked.append(url)
        reading += 1
        mostAtOnce = max(mostAtOnce, reading)
        defer { reading -= 1 }
        let host = url.host() ?? ""
        do {
            try await Task.sleep(for: slowHosts.contains(host) ? .seconds(600) : pageDelay)
        } catch {
            cancelledReads += 1
            throw error
        }
        if emptyHosts.contains(host) { return nil }
        let paragraph = "This page about \(host) explains the topic in clear steps, with examples and a short history. "
        return ReaderText(title: "Page at \(host)", text: String(repeating: paragraph, count: 12), url: url)
    }
}
#endif
