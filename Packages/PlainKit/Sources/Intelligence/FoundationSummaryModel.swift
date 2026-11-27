#if canImport(FoundationModels)
import BrowserCore
import Foundation
import FoundationModels
import os

/// Apple's on-device model (`SystemLanguageModel.default`), never Private Cloud Compute
/// (`FixedChoices.summariesOnDeviceOnly`). docs/research/browse-for-me.md has the facts this
/// follows: snapshots stream (not deltas), properties generate in declared order, the schema
/// counts against the context, the context size is read at run time.
///
/// Each request gets a fresh session: a summary has no history, and a used session's transcript
/// would eat the context. A prewarmed session waits for the request it was made for.
@available(iOS 27, macOS 27, *)
public final class FoundationSummaryModel: SummaryModel {
    /// Summaries transform content the user chose (pages they asked to read), which is what
    /// Apple's permissive guardrails are for: news about a war or an illness is not refused.
    private let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    private var prewarmed: (kind: SummaryKind, session: LanguageModelSession)?
    private let logger = Logger(subsystem: "dev.abrahamgonzalez.plainbrowser", category: "summary")

    public init() {}

    public func availability() async -> AIAvailability {
        let model = model
        return await Task.detached(priority: .utility) { Self.availability(of: model) }.value
    }

    nonisolated static func availability(of model: SystemLanguageModel) -> AIAvailability {
        switch model.availability {
        case .available:
            return model.supportsLocale(Locale.current) ? .available : .unsupportedLanguage
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .modelNotReady
        }
    }

    public var contextTokens: Int { model.contextSize }

    public func prewarm(_ kind: SummaryKind) {
        guard prewarmed?.kind != kind else { return }
        let session = makeSession(kind)
        session.prewarm()
        prewarmed = (kind, session)
    }

    private func makeSession(_ kind: SummaryKind) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: SummaryPrompt.instructions(kind))
    }

    private func session(for kind: SummaryKind) -> LanguageModelSession {
        if let prewarmed, prewarmed.kind == kind {
            self.prewarmed = nil
            return prewarmed.session
        }
        return makeSession(kind)
    }

    public func tokenCount(for request: SummaryRequest) async -> Int? {
        let model = model
        let kind = SummaryKind(request.subject)
        let prompt = SummaryPrompt.prompt(request)
        do {
            let instructions = try await model.tokenCount(for: Instructions(SummaryPrompt.instructions(kind)))
            let schema = try await model.tokenCount(for: GeneratedSummary.generationSchema)
            let body = try await model.tokenCount(for: Prompt(prompt))
            return instructions + schema + body
        } catch {
            logger.error("token count failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    public func write(_ request: SummaryRequest) -> AsyncThrowingStream<SummaryDraft, any Error> {
        let session = session(for: SummaryKind(request.subject))
        let prompt = SummaryPrompt.prompt(request)
        let logger = logger
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let options = GenerationOptions(
                        samplingMode: .greedy, maximumResponseTokens: FixedChoices.summaryResponseTokens
                    )
                    let stream = session.streamResponse(to: prompt, generating: GeneratedSummary.self, options: options)
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        continuation.yield(Self.draft(snapshot.content))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    let mapped = Self.map(error)
                    logger.error("summary failed: \(String(describing: mapped), privacy: .public)")
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func draft(_ partial: GeneratedSummary.PartiallyGenerated) -> SummaryDraft {
        SummaryDraft(
            sections: (partial.sections ?? []).map { section in
                SummaryDraft.Section(
                    heading: section.heading ?? "",
                    points: (section.points ?? []).map { SummaryDraft.Point(text: $0.text ?? "", sources: $0.sources ?? []) }
                )
            }
        )
    }

    static func map(_ error: any Error) -> SummaryModelError {
        if let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return .declined
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .contextSizeExceeded: return .contextExceeded
            case .rateLimited: return .unavailable
            default: return .failed
            }
        }
        if error is SystemLanguageModel.Error { return .unavailable }
        return .failed
    }
}

/// The answer's shape. Properties generate in this order, so each heading shows before its points
/// and each point's citations right after its text. No title: the screen's headline is the search
/// or the page's title, and the first bullet comes sooner without one. Names are short: the schema
/// is part of the prompt.
@available(iOS 27, macOS 27, *)
@Generable struct GeneratedSummary {
    @Guide(description: "Sections, most useful first", .count(1...4))
    var sections: [GeneratedSection]
}

@available(iOS 27, macOS 27, *)
@Generable struct GeneratedSection {
    @Guide(description: "A heading of 2 to 5 words")
    var heading: String
    @Guide(.count(1...4))
    var points: [GeneratedPoint]
}

@available(iOS 27, macOS 27, *)
@Generable struct GeneratedPoint {
    @Guide(description: "One or two plain sentences")
    var text: String
    @Guide(description: "The numbers of the sources this point comes from")
    var sources: [Int]
}
#endif
