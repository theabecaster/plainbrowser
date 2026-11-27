#if canImport(UIKit)
import BrowserCore
import Foundation
import os
import SwiftUI
import Translation
import UIKit
import WebEngine

/// Translate Page's engine: Apple's Translation framework, on the device
/// (`FixedChoices.translationOnDevice`; docs/research/translate.md). The web engine finds the
/// text and puts translations back; this only answers which language to use and translates.
///
/// Sessions are made without a view (`TranslationSession(installedSource:target:)`, iOS 26), so
/// translating needs no SwiftUI. Only a language that isn't downloaded yet needs the system's
/// download sheet, which the framework shows only from a SwiftUI `translationTask`: a 1-point
/// invisible host is added to the browser for that one question and removed after it.
///
/// The framework doesn't run in the simulator; UI tests use `TestPageTranslator`.
final class AppleTranslator: PageTranslator {
    /// Where the download sheet is shown from (the browser).
    weak var presenter: UIViewController?
    private let logger = Logger(subsystem: "dev.abrahamgonzalez.plainbrowser", category: "translate")
    /// Each page language's answer, for this launch: the check runs on every page load.
    private var targets: [String: Locale.Language?] = [:]
    /// One session per pair, reused for every batch.
    private var sessions: [String: SessionBox] = [:]

    func target(for language: Locale.Language) async -> Locale.Language? {
        let key = language.maximalIdentifier
        if let known = targets[key] { return known }
        let preferred = Locale.preferredLanguages
        var answer: Locale.Language?
        if !PageLanguage.isRead(key, preferred: preferred) {
            let availability = LanguageAvailability()
            for identifier in preferred {
                let candidate = Locale.Language(identifier: identifier)
                if await availability.status(from: language, to: candidate) != .unsupported {
                    answer = candidate
                    break
                }
            }
        }
        targets[key] = answer
        return answer
    }

    func prepare(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return true
        case .supported: return await askToDownload(source, target)
        case .unsupported: return false
        @unknown default: return false
        }
    }

    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        let key = "\(source.maximalIdentifier)>\(target.maximalIdentifier)"
        let box = sessions[key] ?? SessionBox(source: source, target: target)
        sessions[key] = box
        do {
            return try await box.translate(texts)
        } catch {
            // A language deleted in Settings since the page was checked: ask again, once.
            logger.notice("translation failed: \(String(describing: error), privacy: .public)")
            sessions[key] = nil
            guard await askToDownload(source, target) else { throw error }
            let fresh = SessionBox(source: source, target: target)
            sessions[key] = fresh
            return try await fresh.translate(texts)
        }
    }

    /// The system's download sheet for the pair. True once both languages are on the device.
    private func askToDownload(_ source: Locale.Language, _ target: Locale.Language) async -> Bool {
        guard let presenter, presenter.view.window != nil else { return false }
        return await withCheckedContinuation { continuation in
            var host: UIHostingController<DownloadPrompt>?
            let prompt = DownloadPrompt(configuration: .init(source: source, target: target)) { ready in
                guard let shown = host else { return }
                host = nil
                shown.willMove(toParent: nil)
                shown.view.removeFromSuperview()
                shown.removeFromParent()
                continuation.resume(returning: ready)
            }
            let controller = UIHostingController(rootView: prompt)
            controller.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            controller.view.backgroundColor = .clear
            controller.view.isUserInteractionEnabled = false
            host = controller
            presenter.addChild(controller)
            presenter.view.addSubview(controller.view)
            controller.didMove(toParent: presenter)
        }
    }

    /// Asks the framework to make the pair ready; the sheet is the system's.
    private struct DownloadPrompt: View {
        let configuration: TranslationSession.Configuration
        let done: @MainActor (Bool) -> Void

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(configuration) { session in
                    let ready = await SessionBox(session).prepare()
                    await done(ready)
                }
        }
    }
}

/// A session and its pair. The framework's session is not `Sendable`; it is only ever used from
/// `translate`, one batch at a time per page, and the framework does the work off the main thread.
private nonisolated final class SessionBox: @unchecked Sendable {
    let session: TranslationSession

    init(source: Locale.Language, target: Locale.Language) {
        session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
    }

    /// The session SwiftUI's `translationTask` hands over, for the download question.
    init(_ session: TranslationSession) {
        self.session = session
    }

    /// Shows the system's download sheet when needed; true once the pair is ready.
    func prepare() async -> Bool {
        (try? await session.prepareTranslation()) != nil
    }

    func translate(_ texts: [String]) async throws -> [String] {
        let responses = try await session.translations(from: texts.map { TranslationSession.Request(sourceText: $0) })
        return responses.map(\.targetText)
    }
}

#if DEBUG
/// A stand-in for UI tests and screenshots in the simulator, where Apple's framework doesn't run
/// (`-PlainTestTranslator`): French reads as English from a small phrase book, anything else is
/// marked, so a translated page is easy to recognize.
final class TestPageTranslator: PageTranslator {
    static let phrases: [String: String] = [
        "Le marché du samedi": "The Saturday market",
        "Chaque samedi matin, la place du village se remplit d'étals colorés.": "Every Saturday morning, the village square fills with colorful stalls.",
        "Les producteurs locaux vendent des fruits, des légumes et du fromage.": "Local farmers sell fruit, vegetables and cheese.",
        "Lire la suite": "Read more",
        "Les horaires": "Opening hours",
        "Le marché ouvre à huit heures et ferme à midi.": "The market opens at eight and closes at noon.",
        "Venez tôt pour trouver le meilleur pain de la région.": "Come early to find the best bread in the region.",
        "Accueil": "Home",
    ]

    func target(for language: Locale.Language) async -> Locale.Language? {
        language.languageCode == "en" ? nil : Locale.Language(identifier: "en")
    }

    func prepare(from source: Locale.Language, to target: Locale.Language) async -> Bool { true }

    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(150))
        return texts.map { Self.phrases[$0] ?? "[EN] \($0)" }
    }
}
#endif
#endif
