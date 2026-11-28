import BrowserCore
import Foundation

/// One page's text in a summary's prompt, numbered as the summary cites it.
public struct SourceText: Sendable, Equatable {
    public var number: Int
    public var title: String
    public var site: String
    public var text: String

    public init(number: Int, title: String, site: String, text: String) {
        self.number = number
        self.title = title
        self.site = site
        self.text = text
    }
}

/// What the model is asked to write.
public struct SummaryRequest: Sendable, Equatable {
    public var subject: SummarySubject
    public var sources: [SourceText]

    public init(subject: SummarySubject, sources: [SourceText]) {
        self.subject = subject
        self.sources = sources
    }

    /// The same request with each source's text replaced by `texts` (after fitting).
    func with(texts: [String]) -> SummaryRequest {
        var copy = self
        for index in copy.sources.indices where index < texts.count { copy.sources[index].text = texts[index] }
        return copy
    }
}

/// Why the model wrote nothing, in the terms the screen needs (`SummaryFailure`).
public enum SummaryModelError: Error, Equatable {
    /// Apple's guardrails or the model declined the content.
    case declined
    case unsupportedLanguage
    /// The prompt didn't fit the context, even after fitting.
    case contextExceeded
    /// The model can't run now (assets missing, Apple Intelligence unavailable).
    case unavailable
    /// The system held the model back for now (rate limited, for example while Plain was in the
    /// background): a second try can work.
    case busy
    case failed
}

/// The kinds of summary, each with its own fixed instructions (so a session can be prewarmed
/// with them before the sources arrive).
public enum SummaryKind: Sendable, Equatable {
    case browse, page

    public init(_ subject: SummarySubject) {
        switch subject {
        case .search: self = .browse
        case .page: self = .page
        }
    }
}

/// Writes summaries. `FoundationSummaryModel` is Apple's on-device model; tests and UI tests use
/// `ScriptedSummaryModel`.
@MainActor public protocol SummaryModel: AnyObject, Sendable {
    /// Whether the model can run now. Reads the system's answer; the caller keeps it.
    func availability() async -> AIAvailability
    /// Loads the model and its instructions for `kind` ahead of a request that is a few seconds
    /// away (Browse for Me prewarms while the pages load).
    func prewarm(_ kind: SummaryKind)
    /// The model's context window, in tokens.
    var contextTokens: Int { get }
    /// The tokens `request` takes with its instructions and schema, or nil when the model can't
    /// count (the fit then stays with its estimate).
    func tokenCount(for request: SummaryRequest) async -> Int?
    /// Streams the summary as it is written: each element is the whole draft so far. Throws
    /// `SummaryModelError` or `CancellationError`.
    func write(_ request: SummaryRequest) -> AsyncThrowingStream<SummaryDraft, any Error>
}
