#if canImport(UIKit)
import BrowserCore
import Foundation
import Intelligence
import Reader
import UIKit
import WebEngine

/// The browser's side of the on-device model: whether it can run (so the rules show Browse for Me
/// and Summarize Page or leave them out), and the pieces each summary run is made of.
///
/// The answer is read off the main thread at start and each time the app becomes active, since
/// Apple Intelligence can be turned on, or its model finish downloading, while Plain is away.
/// Until the first answer the entries stay out: no entry appears and then vanishes.
final class SummaryService {
    let model: any SummaryModel
    private(set) var availability: AIAvailability = .modelNotReady
    /// The answer changed: the shell recomputes its rules.
    var onAvailabilityChange: () -> Void = {}
    private let pool: WebViewPool
    private var observer: (any NSObjectProtocol)?
    private var refreshing: Task<Void, Never>?
    #if DEBUG
    private var scripted: ScriptedBrowsing?
    #endif

    init(pool: WebViewPool) {
        self.pool = pool
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-PlainAIUnavailable") {
            model = ScriptedSummaryModel(availability: .deviceNotEligible)
            return
        }
        // UI tests and screenshots: a scripted model and scripted pages, no network, no Apple
        // Intelligence (the simulator's would be the Mac's).
        if arguments.contains("-PlainTestSummaries") {
            // Slower when the test leaves the app mid-summary, so the summary is still on its way.
            let leaves = arguments.contains("-PlainAIGoesAwayInBackground")
            model = ScriptedSummaryModel(pace: .milliseconds(leaves ? 400 : 40))
            scripted = ScriptedBrowsing()
            return
        }
        #endif
        model = FoundationSummaryModel()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        #if DEBUG
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        #endif
    }

    /// Reads the first answer and follows the app becoming active.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        #if DEBUG
        // `-PlainAIGoesAwayInBackground` (with `-PlainTestSummaries`): the scripted model stops
        // being ready while Plain is in the background, as a model whose assets went away would,
        // so a UI test can check what an open summary and the entries do on the way back.
        if ProcessInfo.processInfo.arguments.contains("-PlainAIGoesAwayInBackground"), let scripted = model as? ScriptedSummaryModel {
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { scripted.answer = .modelNotReady }
            }
        }
        #endif
        refresh()
    }

    #if DEBUG
    private var backgroundObserver: (any NSObjectProtocol)?
    #endif

    func refresh() {
        refreshing?.cancel()
        refreshing = Task { [weak self, model] in
            let answer = await model.availability()
            guard let self, !Task.isCancelled else { return }
            if answer != availability {
                availability = answer
                onAvailabilityChange()
            }
            // The model downloading or preparing can finish while Plain is open: look again now
            // and then, so the entries appear by themselves without a trip out of the app.
            guard answer == .modelNotReady else { return }
            try? await Task.sleep(for: FixedChoices.aiNotReadyRecheck)
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            refresh()
        }
    }

    var isAvailable: Bool { availability.isAvailable }

    /// A Browse for Me run's readers: a fresh hidden browsing context (its own in-memory store).
    func makeBrowsing() -> any ResultsReading & PageReading {
        #if DEBUG
        if let scripted { return scripted }
        #endif
        return HiddenBrowsing(pool: pool)
    }
}
#endif
