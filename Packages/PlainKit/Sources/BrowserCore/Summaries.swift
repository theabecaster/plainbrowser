import Foundation

// On-device summaries (docs/plan.md, section 8): Browse for Me and Summarize Page. These are the
// plain values the pipeline (Intelligence), the summary screen (FeatureUI) and the shell share,
// and the rules that need no model, web view or UI, so they are tested on macOS.

/// Whether the on-device model can run here, in the terms the rules need. Only `.available` shows
/// the AI entries (docs/state-rules.md §4 and §6): the others leave them out, never dimmed.
public enum AIAvailability: Sendable, Equatable {
    case available
    /// The phone can't run Apple Intelligence.
    case deviceNotEligible
    /// Apple Intelligence is off in Settings.
    case appleIntelligenceOff
    /// The model is still downloading or preparing; the entries appear by themselves once it is
    /// ready.
    case modelNotReady
    /// The model doesn't support the phone's language.
    case unsupportedLanguage

    public var isAvailable: Bool { self == .available }
}

/// What a summary is about.
public enum SummarySubject: Sendable, Equatable {
    /// Browse for Me: the query, read from the top results.
    case search(String)
    /// Summarize Page: the page on screen.
    case page(title: String, url: URL)
}

/// A page a summary reads. Once the model starts writing, the pages read are numbered 1, 2, 3…
/// in their results order, as the summary cites them; skipped ones get no number.
public struct SummarySource: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// Picked, not loading yet.
        case waiting
        case reading
        /// Its text is in the summary's prompt.
        case read
        /// Too slow, not readable or failed: left out, and said so.
        case skipped
    }

    /// 1-based, as the summary cites it; nil until writing starts, and for a skipped page.
    public var number: Int?
    public var url: URL
    public var title: String
    public var state: State

    public var id: URL { url }

    /// The site as the pill shows it: the host without `www.`.
    public var site: String { BrowseForMe.siteName(url) }

    public init(url: URL, title: String, state: State = .waiting, number: Int? = nil) {
        self.number = number
        self.url = url
        self.title = title
        self.state = state
    }
}

/// The summary as it streams: a title, then sections of points, each point citing sources by
/// number. Every field may still be growing while the model writes.
public struct SummaryDraft: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var text: String
        /// Source numbers (1-based), in the order cited, each once.
        public var sources: [Int]

        public init(text: String, sources: [Int] = []) {
            self.text = text
            self.sources = sources
        }
    }

    public struct Section: Sendable, Equatable {
        public var heading: String
        public var points: [Point]

        public init(heading: String, points: [Point] = []) {
            self.heading = heading
            self.points = points
        }
    }

    public var title: String
    public var sections: [Section]

    public init(title: String = "", sections: [Section] = []) {
        self.title = title
        self.sections = sections
    }

    /// Nothing written yet.
    public var isEmpty: Bool {
        title.isEmpty && sections.allSatisfy { $0.heading.isEmpty && $0.points.allSatisfy(\.text.isEmpty) }
    }

    /// The draft with citations the sources can answer for: numbers outside `1...sourceCount`
    /// dropped, each number once, and none at all for a single source (a page's own summary cites
    /// nothing). Whitespace trimmed; empty points and sections without points or heading dropped.
    public func cleaned(sourceCount: Int) -> SummaryDraft {
        func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = SummaryDraft(title: trim(title))
        for section in sections {
            var cleaned = Section(heading: trim(section.heading))
            for point in section.points {
                let text = trim(point.text)
                guard !text.isEmpty else { continue }
                var seen = Set<Int>()
                let sources = sourceCount > 1
                    ? point.sources.filter { (1...sourceCount).contains($0) && seen.insert($0).inserted }
                    : []
                cleaned.points.append(Point(text: text, sources: sources))
            }
            if !cleaned.heading.isEmpty || !cleaned.points.isEmpty { result.sections.append(cleaned) }
        }
        return result
    }
}

/// Why a summary couldn't be written. Each has Plain's own sentence (docs/ui-reference.md,
/// wording: never the model's or WebKit's text).
public enum SummaryFailure: Sendable, Equatable {
    /// The results page gave no results to read.
    case noResults
    /// No result page could be read within the time budget.
    case nothingReadable
    /// The phone is offline.
    case offline
    /// The model declined the topic (Apple's guardrails) or refused.
    case declined
    /// The pages or the question are in a language the model doesn't support.
    case unsupportedLanguage
    /// The model became unavailable on the way (Apple Intelligence turned off, the app left).
    case unavailable
    /// Anything else.
    case failed

    public var message: String {
        switch self {
        case .noResults: "No results to read for this search."
        case .nothingReadable: "None of the results could be read in time."
        case .offline: "You're offline. Connect to the internet and try again."
        case .declined: "Apple Intelligence can't summarize this."
        case .unsupportedLanguage: "Apple Intelligence doesn't support this language yet."
        case .unavailable: "Apple Intelligence isn't available right now."
        case .failed: "The summary couldn't be written."
        }
    }

    /// A second try can help: a slow network or a passing failure. The model's own answers
    /// (declined, unsupported, unavailable) would come out the same.
    public var canRetry: Bool {
        switch self {
        case .nothingReadable, .offline, .failed: true
        case .noResults, .declined, .unsupportedLanguage, .unavailable: false
        }
    }
}

/// Where a summary is on its way, for the honest progress line.
public enum SummaryStage: Sendable, Equatable {
    /// Loading and reading the results page of `engine` (its name).
    case searching(engine: String)
    /// Reading the sources.
    case reading
    /// The model is writing; the draft grows.
    case writing
    case done
    case failed(SummaryFailure)

    public var isFinished: Bool {
        switch self {
        case .done, .failed: true
        default: false
        }
    }
}

/// Everything the summary screen shows, as one value: the pipeline sends a new one at each step.
public struct SummaryProgress: Sendable, Equatable {
    public var subject: SummarySubject
    public var stage: SummaryStage
    /// The pages read, in citation order. Empty for a page's own summary.
    public var sources: [SummarySource]
    public var draft: SummaryDraft

    public init(subject: SummarySubject, stage: SummaryStage, sources: [SummarySource] = [], draft: SummaryDraft = SummaryDraft()) {
        self.subject = subject
        self.stage = stage
        self.sources = sources
        self.draft = draft
    }

    /// The sources the summary was written from, in citation order.
    public var citedSources: [SummarySource] {
        sources.filter { $0.number != nil }.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
    }

    /// The source a citation number points to.
    public func source(numbered number: Int) -> SummarySource? {
        sources.first { $0.number == number }
    }
}
