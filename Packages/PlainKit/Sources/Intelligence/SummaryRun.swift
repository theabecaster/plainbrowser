import BrowserCore
import Foundation
import os
import PerfSignposts
import Reader

/// Reads a results page's links in a hidden view (`HiddenResultsReader`).
@MainActor public protocol ResultsReading: AnyObject, Sendable {
    /// The links on `page`, in page order. Throws `BrowseReadError` or a `URLError` when the page
    /// can't be read, `CancellationError` when cancelled (the view is torn down either way).
    func links(on page: BrowseForMe.ResultsPage) async throws -> [BrowseForMe.Link]
}

/// Reads one page's text in a hidden view (`HiddenPageReader`).
@MainActor public protocol PageReading: AnyObject, Sendable {
    /// The page's readable text, or nil when it has none. Throws when it can't load; cancelling
    /// tears its view down at once.
    func text(of url: URL) async throws -> ReaderText?
}

/// A results page that loaded but can't be used.
public enum BrowseReadError: Error, Equatable {
    /// The engine showed a challenge (a captcha, "unusual traffic").
    case blocked
}

/// How long each step may take. Real runs use `FixedChoices`; tests shorten them.
public struct SummaryBudgets: Sendable {
    public var results: Duration
    public var reading: Duration
    public var firstSourceGrace: Duration

    public init(
        results: Duration = FixedChoices.browseResultsTimeout, reading: Duration = FixedChoices.browseReadBudget,
        firstSourceGrace: Duration = FixedChoices.browseFirstSourceGrace
    ) {
        self.results = results
        self.reading = reading
        self.firstSourceGrace = firstSourceGrace
    }
}

/// One summary, from the tap to the last word: Browse for Me (results page, sources in parallel,
/// then the model) or Summarize Page (the page's text, then the model). Every step reports a new
/// `SummaryProgress` through `onProgress`, on the main actor. `cancel()` stops everything at once
/// and tears down every hidden view; nothing is reported after it.
///
/// It owns no web view itself: the readers make and release them through the pool, at most
/// `FixedChoices.browseSources` at a time, each released as soon as its text is read.
@MainActor public final class SummaryRun {
    public enum Input: Sendable {
        case search(String, engine: SearchEngine)
        case page(ReaderText, title: String, url: URL)
    }

    private let input: Input
    private let model: any SummaryModel
    private let results: (any ResultsReading)?
    private let pages: (any PageReading)?
    private let budgets: SummaryBudgets
    private let onProgress: (SummaryProgress) -> Void
    private var task: Task<Void, Never>?
    private(set) public var progress: SummaryProgress
    private var signpost: (state: OSSignpostIntervalState, firstWords: OSSignpostIntervalState)?
    /// The read texts, by index into `progress.sources`.
    private var texts: [Int: ReaderText] = [:]

    public init(
        _ input: Input, model: any SummaryModel, results: (any ResultsReading)? = nil, pages: (any PageReading)? = nil,
        budgets: SummaryBudgets = SummaryBudgets(), onProgress: @escaping (SummaryProgress) -> Void
    ) {
        self.input = input
        self.model = model
        self.results = results
        self.pages = pages
        self.budgets = budgets
        self.onProgress = onProgress
        switch input {
        case .search(let query, let engine):
            progress = SummaryProgress(subject: .search(query), stage: .searching(engine: engine.name))
        case .page(_, let title, let url):
            progress = SummaryProgress(subject: .page(title: title, url: url), stage: .writing)
        }
    }

    public var isRunning: Bool { task != nil }

    public func start() {
        guard task == nil else { return }
        let signposter = Signposts.signposter
        signpost = (signposter.beginInterval(Signposts.summary), signposter.beginInterval(Signposts.summaryFirstWords))
        model.prewarm(SummaryKind(progress.subject))
        onProgress(progress)
        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops the run: hidden views are torn down, the model stops writing, nothing more is reported.
    public func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        endSignposts(.cancelled)
    }

    /// Waits for the run to finish (tests).
    public func finished() async {
        await task?.value
    }

    private func run() async {
        switch input {
        case .search(let query, let engine):
            guard let found = await search(query, engine: engine), !Task.isCancelled else { return }
            await read(found)
            guard !Task.isCancelled else { return }
            let read = numberReadSources()
            guard !read.isEmpty else { return finish(.failed(.nothingReadable)) }
            update { $0.stage = .writing }
            await write(SummaryRequest(subject: progress.subject, sources: read))
        case .page(let text, let title, let url):
            let source = SourceText(number: 1, title: title, site: BrowseForMe.siteName(url), text: text.text)
            await write(SummaryRequest(subject: progress.subject, sources: [source]), condense: true)
        }
    }

    // MARK: Results

    /// The organic results of the first results page that has any, or nil after reporting why
    /// none could be found.
    private func search(_ query: String, engine: SearchEngine) async -> [BrowseForMe.Result]? {
        guard let results else {
            finish(.failed(.noResults))
            return nil
        }
        var offline = false
        for page in BrowseForMe.resultsPages(for: query, engine: engine) {
            update { $0.stage = .searching(engine: page.engineName) }
            let signposter = Signposts.signposter
            let state = signposter.beginInterval(Signposts.summaryResults, "\(page.engineName)")
            do {
                let links = try await Self.within(budgets.results) { try await results.links(on: page) }
                let organic = BrowseForMe.organicResults(links ?? [], engineHosts: page.engineHosts)
                signposter.endInterval(Signposts.summaryResults, state, "\(organic.count) results")
                if !organic.isEmpty { return organic }
            } catch is CancellationError {
                signposter.endInterval(Signposts.summaryResults, state, "cancelled")
                return nil
            } catch {
                signposter.endInterval(Signposts.summaryResults, state, "failed")
                if let error = error as? URLError, Self.offlineCodes.contains(error.code) { offline = true }
            }
            if Task.isCancelled { return nil }
        }
        finish(.failed(offline ? .offline : .noResults))
        return nil
    }

    private static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed]

    // MARK: Sources

    /// Reads up to `FixedChoices.browseSources` results in parallel within the read budget. A
    /// result that fails early is replaced by the next one while the budget lasts; past it,
    /// whatever was read is used, or, with nothing read, the first page to arrive within the
    /// grace period.
    private func read(_ found: [BrowseForMe.Result]) async {
        guard let pages else { return }
        update { progress in
            progress.stage = .reading
            progress.sources = found.prefix(FixedChoices.browseSources).map { SummarySource(url: $0.url, title: $0.title) }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + budgets.reading
        let replaceBefore = deadline - .seconds(1)
        let minimum = FixedChoices.browseMinimumText
        let limit = FixedChoices.summaryMaxPageText
        let graceTimer = -2, budgetTimer = -1
        var next = progress.sources.count
        inFlight = 0
        await withTaskGroup(of: (Int, ReaderText?).self) { group in
            for index in progress.sources.indices {
                let url = startReading(index)
                group.addTask { await Self.readOne(index, url, with: pages) }
            }
            group.addTask {
                try? await Task.sleep(until: deadline, clock: clock)
                return (budgetTimer, nil)
            }
            while let (index, text) = await group.next() {
                if index == budgetTimer {
                    if texts.isEmpty, inFlight > 0 {
                        let grace = budgets.firstSourceGrace
                        group.addTask {
                            try? await Task.sleep(for: grace)
                            return (graceTimer, nil)
                        }
                        continue
                    }
                    break
                }
                if index == graceTimer { break }
                inFlight -= 1
                if let text, text.text.count >= minimum {
                    texts[index] = ReaderText(
                        title: text.title, siteName: text.siteName, text: String(text.text.prefix(limit)), lang: text.lang,
                        url: text.url, isArticle: text.isArticle
                    )
                    update { $0.sources[index].state = .read }
                    // Past the budget, the first page read is enough to write from.
                    if clock.now >= deadline { break }
                } else {
                    update { $0.sources[index].state = .skipped }
                    if next < found.count, clock.now < replaceBefore, !Task.isCancelled {
                        let result = found[next]
                        next += 1
                        update { $0.sources.append(SummarySource(url: result.url, title: result.title)) }
                        let index = progress.sources.count - 1
                        let url = startReading(index)
                        group.addTask { await Self.readOne(index, url, with: pages) }
                    }
                }
                if inFlight == 0 { break }
            }
            group.cancelAll()
        }
        guard !Task.isCancelled else { return }
        update { progress in
            for index in progress.sources.indices where progress.sources[index].state != .read {
                progress.sources[index].state = .skipped
            }
        }
    }

    /// One source's text, or nil when it can't be read (a failure is a skip, not an error).
    private static func readOne(_ index: Int, _ url: URL, with pages: any PageReading) async -> (Int, ReaderText?) {
        (index, try? await pages.text(of: url))
    }

    /// Reads in flight now.
    private var inFlight = 0

    /// Marks a source as being read and returns its address.
    private func startReading(_ index: Int) -> URL {
        update { $0.sources[index].state = .reading }
        inFlight += 1
        return progress.sources[index].url
    }

    /// Numbers the read sources 1, 2, 3… in results order and returns their texts.
    private func numberReadSources() -> [SourceText] {
        var read: [SourceText] = []
        update { progress in
            var number = 0
            for index in progress.sources.indices {
                guard progress.sources[index].state == .read, let text = texts[index] else { continue }
                number += 1
                progress.sources[index].number = number
                let source = progress.sources[index]
                let title = source.title.isEmpty ? text.title : source.title
                read.append(SourceText(number: number, title: title, site: source.site, text: text.text))
            }
        }
        texts = [:]
        return read
    }

    // MARK: Writing

    private func write(_ request: SummaryRequest, condense: Bool = false) async {
        let signposter = Signposts.signposter
        let fitState = signposter.beginInterval(Signposts.summaryFit)
        var fitted = await fit(request, condense: condense, scale: 1)
        signposter.endInterval(Signposts.summaryFit, fitState)
        guard !Task.isCancelled else { return }
        let writeState = signposter.beginInterval(Signposts.summaryWrite)
        var retried = false
        while true {
            do {
                for try await draft in model.write(fitted) {
                    guard !Task.isCancelled else { break }
                    let cleaned = draft.cleaned(sourceCount: request.sources.count)
                    if !firstWordsShown, !cleaned.isEmpty, let signpost {
                        signposter.endInterval(Signposts.summaryFirstWords, signpost.firstWords)
                        firstWordsShown = true
                    }
                    update { $0.draft = cleaned }
                }
                signposter.endInterval(Signposts.summaryWrite, writeState, "done")
                guard !Task.isCancelled else { return }
                return finish(.done)
            } catch SummaryModelError.contextExceeded where !retried && progress.draft.isEmpty {
                // The estimate was off for this text: once more with half the room.
                retried = true
                fitted = await fit(request, condense: condense, scale: 0.5)
            } catch {
                signposter.endInterval(Signposts.summaryWrite, writeState, "failed")
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                let failure = Self.failure(for: error)
                // A summary cut short (the answer's room ran out) is still worth reading; one the
                // model declined is not shown at all.
                if failure == .failed, !progress.draft.isEmpty { return finish(.done) }
                update { $0.draft = SummaryDraft() }
                return finish(.failed(failure))
            }
        }
    }

    /// Whether the first words reached the screen (the first-words interval then ends there).
    private var firstWordsShown = false

    static func failure(for error: any Error) -> SummaryFailure {
        switch error as? SummaryModelError {
        case .declined: .declined
        case .unsupportedLanguage: .unsupportedLanguage
        case .unavailable: .unavailable
        default: .failed
        }
    }

    /// The request with each source cut to its share of the context: the estimate first, then the
    /// model's own count, shrinking once if the real prompt is over.
    private func fit(_ request: SummaryRequest, condense: Bool, scale: Double) async -> SummaryRequest {
        let contextTokens = model.contextTokens
        let budget = Int(Double(BrowseForMe.sourceCharacters(contextTokens: contextTokens)) * scale)
        let texts = request.sources.map(\.text)
        var fitted = request.with(texts: await Self.fit(texts, budget: budget, condense: condense))
        let limit = contextTokens - FixedChoices.summaryResponseTokens
        if let count = await model.tokenCount(for: fitted), count > limit {
            let ratio = Double(limit) / Double(count) * 0.9
            fitted = request.with(texts: await Self.fit(texts, budget: Int(Double(budget) * ratio), condense: condense))
        }
        return fitted
    }

    /// Fitting walks up to five pages of text: off the main thread.
    @concurrent private static func fit(_ texts: [String], budget: Int, condense: Bool) async -> [String] {
        if condense, texts.count == 1 { return [BrowseForMe.condense(texts[0], limit: budget)] }
        return BrowseForMe.fit(texts, budget: budget)
    }

    // MARK: Reporting

    private func update(_ change: (inout SummaryProgress) -> Void) {
        // After `cancel()` the run's task sees the cancellation: nothing more reaches the screen.
        guard !Task.isCancelled else { return }
        change(&progress)
        onProgress(progress)
    }

    private func finish(_ stage: SummaryStage) {
        update { $0.stage = stage }
        endSignposts(stage == .done ? .done : .failed)
        task = nil
    }

    private enum Ending { case done, failed, cancelled }

    private func endSignposts(_ ending: Ending) {
        guard let signpost else { return }
        let signposter = Signposts.signposter
        if !firstWordsShown { signposter.endInterval(Signposts.summaryFirstWords, signpost.firstWords, "none") }
        switch ending {
        case .done: signposter.endInterval(Signposts.summary, signpost.state, "done")
        case .failed: signposter.endInterval(Signposts.summary, signpost.state, "failed")
        case .cancelled: signposter.endInterval(Signposts.summary, signpost.state, "cancelled")
        }
        self.signpost = nil
    }

    /// `operation`'s result, or nil when it takes longer than `limit` (it is then cancelled).
    static func within<Value: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable @MainActor () async throws -> Value
    ) async throws -> Value? {
        try await withThrowingTaskGroup(of: Optional<Value>.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }
}
