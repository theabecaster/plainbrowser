#if canImport(UIKit)
import BrowserCore
import NaturalLanguage
import os
import PerfSignposts
import WebKit

/// One page's translation state, kept on its slot.
struct SlotTranslation {
    /// Bumped for every new document, so answers about an older page are dropped.
    var page = 0
    /// The pair the page is being translated with.
    var pair: (source: Locale.Language, target: Locale.Language)?
    /// Bumped by every Translate Page, so an older attempt's download answer can't start it.
    var attempt = 0
    var interval: OSSignpostIntervalState?
}

// MARK: - Translate Page (PageTranslation)

extension WebViewPool {
    /// A new main-frame document: its language is unknown again and it shows the site's text.
    func translationPageDidCommit(_ slot: Slot) {
        slot.translation.page += 1
        slot.translation.pair = nil
        endTranslateInterval(slot, "new page")
        guard let tab = slot.tab else { return }
        tab.set(\.pageLanguage, nil)
        tab.set(\.translationTarget, nil)
        tab.set(\.translation, .original)
    }

    /// The language check reported. Recognized off the main thread, then the shell's translator
    /// says whether the user needs it translated. A tab that is following a translation
    /// (`FixedChoices.translationFollowsTab`) translates a page in the same language at once.
    func receivePageLanguage(declared: String, sample: String, in slot: Slot) {
        guard let translator, let tab = slot.tab else { return }
        let page = slot.translation.page
        Task { [weak self, weak slot, weak tab] in
            let language = await Task.detached(priority: .utility) {
                PageLanguageRecognizer.recognize(sample: sample, declared: declared)
            }.value
            guard let slot, let tab, slot.translation.page == page, slot.tab === tab else { return }
            tab.set(\.pageLanguage, language)
            guard let language else { return }
            let target = await translator.target(for: language)
            guard slot.translation.page == page, slot.tab === tab else { return }
            tab.set(\.translationTarget, target)
            Signposts.signposter.emitEvent(
                Signposts.pageLanguage, "\(target == nil ? "read" : "foreign", privacy: .public)"
            )
            if let target, let follow = tab.followsTranslation,
               follow.source.languageCode == language.languageCode, follow.target == target {
                self?.translate(tab)
            }
        }
    }

    /// Translate Page: makes the language pair ready (the system may ask to download it), then
    /// injects the translator and starts it. The page reports when the first text is translated.
    func translate(_ tab: Tab) {
        guard let translator, let slot = slot(for: tab), let source = tab.pageLanguage,
              let target = tab.translationTarget, tab.translation == .original
        else { return }
        let page = slot.translation.page
        slot.translation.attempt += 1
        let attempt = slot.translation.attempt
        tab.set(\.translation, .translating)
        tab.followsTranslation = (source, target)
        slot.translation.pair = (source, target)
        endTranslateInterval(slot, "restarted")
        slot.translation.interval = Signposts.signposter.beginInterval(Signposts.translatePage)
        Task { [weak self, weak slot, weak tab] in
            let ready = await translator.prepare(from: source, to: target)
            guard let self, let slot, let tab, slot.translation.page == page, slot.translation.attempt == attempt,
                  tab.translation == .translating
            else { return }
            guard ready else {
                tab.set(\.translation, .original)
                tab.followsTranslation = nil
                slot.translation.pair = nil
                self.endTranslateInterval(slot, "not ready")
                return
            }
            slot.webView.evaluateJavaScript(
                PageTranslation.translatorSource + PageTranslation.startSource, in: nil, in: PageTranslation.world
            ) { _ in }
        }
    }

    /// Show Original: the page's own text comes back at once, without a reload, and the tab stops
    /// following the translation.
    func showOriginal(_ tab: Tab) {
        guard let slot = slot(for: tab) else { return }
        Signposts.signposter.emitEvent(Signposts.showOriginal)
        tab.followsTranslation = nil
        slot.translation.pair = nil
        endTranslateInterval(slot, "show original")
        tab.set(\.translation, .original)
        slot.webView.evaluateJavaScript(PageTranslation.restoreSource, in: nil, in: PageTranslation.world) { _ in }
    }

    /// A message from the page's translation scripts. Only `translate` has a reply: the
    /// translations, or nil when they failed (the page then puts its text back and reports).
    func receiveTranslationMessage(_ body: [String: Any], in slot: Slot) async -> Any? {
        switch body["type"] as? String {
        case "language":
            receivePageLanguage(declared: body["lang"] as? String ?? "", sample: body["sample"] as? String ?? "", in: slot)
            return nil
        case "translate":
            guard let translator, let pair = slot.translation.pair, let texts = body["texts"] as? [String] else { return nil }
            let page = slot.translation.page
            let translations = try? await translator.translate(texts, from: pair.source, to: pair.target)
            guard slot.translation.page == page, slot.translation.pair != nil else { return nil }
            return translations
        case "translated":
            guard let tab = slot.tab, slot.translation.pair != nil else { return nil }
            tab.set(\.translation, .translated)
            endTranslateInterval(slot, "translated")
            return nil
        case "failed":
            guard let tab = slot.tab, slot.translation.pair != nil else { return nil }
            tab.set(\.translation, .original)
            tab.followsTranslation = nil
            slot.translation.pair = nil
            endTranslateInterval(slot, "failed")
            onTranslationFailed?(tab)
            return nil
        default:
            return nil
        }
    }

    private func endTranslateInterval(_ slot: Slot, _ outcome: StaticString) {
        guard let interval = slot.translation.interval else { return }
        slot.translation.interval = nil
        Signposts.signposter.endInterval(Signposts.translatePage, interval, "\(outcome)")
    }

    /// Receives the translation scripts' messages, with replies. The controller keeps it strongly,
    /// so it holds the slot weakly.
    final class TranslationMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
        private weak var slot: Slot?

        init(slot: Slot) {
            self.slot = slot
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) async -> (Any?, String?) {
            guard message.frameInfo.isMainFrame, let slot, let pool = slot.tab?.pool,
                  let body = message.body as? [String: Any]
            else { return (nil, nil) }
            return (await pool.receiveTranslationMessage(body, in: slot), nil)
        }
    }
}

/// Recognizes a page's language from a sample of its text, with its `<html lang>` as the fallback
/// (docs/research/translate.md, section 2). Off the main thread.
nonisolated enum PageLanguageRecognizer {
    /// Shorter samples say too little for the recognizer; the declared language decides.
    static let minimumSample = 40

    static func recognize(sample: String, declared: String) -> Locale.Language? {
        let declaredCode = PageLanguage.declared(declared)
        if sample.count >= minimumSample {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sample)
            if let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
               language != .undetermined, confidence >= FixedChoices.translateDetectionConfidence {
                return Locale.Language(identifier: language.rawValue)
            }
        }
        return declaredCode.map { Locale.Language(identifier: $0) }
    }
}
#endif
