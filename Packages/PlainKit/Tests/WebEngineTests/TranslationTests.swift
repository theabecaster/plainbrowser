#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import WebKit
@testable import WebEngine

/// A translator that marks text instead of translating it, and counts what it was asked.
@MainActor
final class FakeTranslator: PageTranslator {
    var userLanguage = Locale.Language(identifier: "en")
    var prepareAnswer = true
    var fails = false
    private(set) var requests: [[String]] = []
    var characters: Int { requests.joined().reduce(0) { $0 + $1.count } }

    func target(for language: Locale.Language) async -> Locale.Language? {
        language.languageCode == userLanguage.languageCode ? nil : userLanguage
    }

    func prepare(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        prepareAnswer
    }

    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        requests.append(texts)
        if fails { throw CancellationError() }
        return texts.map { "EN \($0)" }
    }
}

@Suite(.serialized) @MainActor
struct TranslationTests {
    nonisolated static let french = """
        <h1 id=title>Bienvenue sur notre site</h1>
        <p id=intro>Nous sommes heureux de vous voir. <a id=link href="/b" class=lien>Lisez la suite</a> pour en savoir plus.</p>
        <p id=skip translate="no">Ne pas traduire</p><code id=code>let x = 1</code>
        <p class=notranslate id=skip2>Marque déposée</p>
        <input id=field placeholder="Votre nom" value="Jean">
        <p>La ville est belle au printemps, et les rues sont pleines de monde.</p>
        """

    @Sendable nonisolated static func route(_ request: TestServer.Request) -> TestServer.Response {
        switch request.path {
        case "/fr": return .html(Pages.page(title: "Accueil", body: french).replacingOccurrences(of: "<html>", with: "<html lang=fr>"))
        case "/fr2": return .html(Pages.page(title: "Deux", body: "<p id=two>Une autre page en français, avec beaucoup de mots pour la reconnaître.</p>"))
        case "/en": return .html(Pages.page(title: "Home", body: "<p>Welcome to our site. We are happy to see you here today, read on.</p>"))
        case "/fr-long":
            var body = "<p id=first>Le premier paragraphe de cette longue page en français.</p>"
            for i in 0..<3_000 { body += "<p id=p\(i)>Paragraphe numéro \(i), avec <a href='#\(i)'>un lien</a> et quelques mots.</p>" }
            return .html(Pages.page(title: "Longue", body: body))
        default:
            return Pages.route(request)
        }
    }

    func makeHarness(_ translator: FakeTranslator) async throws -> (Harness, Tab) {
        let harness = try await Harness(translator: translator, route: Self.route)
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        return (harness, tab)
    }

    func text(_ id: String, in harness: Harness, tab: Tab) async throws -> String? {
        try await harness.evaluate("document.getElementById('\(id)').textContent", in: tab) as? String
    }

    @Test func recognizesAForeignPage() async throws {
        let translator = FakeTranslator()
        let (harness, tab) = try await makeHarness(translator)
        defer { harness.cleanUp() }
        try await harness.load("/fr", in: tab)
        try await waitUntil("language") { tab.translationTarget != nil }
        #expect(tab.pageLanguage?.languageCode == "fr")
        #expect(tab.translationTarget?.languageCode == "en")
        try await harness.load("/en", in: tab)
        try await waitUntil("english") { tab.pageLanguage != nil }
        #expect(tab.pageLanguage?.languageCode == "en")
        #expect(tab.translationTarget == nil, "a page the user reads is not offered")
    }

    @Test func translatesInPlaceAndShowsTheOriginal() async throws {
        let translator = FakeTranslator()
        let (harness, tab) = try await makeHarness(translator)
        defer { harness.cleanUp() }
        try await harness.load("/fr", in: tab)
        try await waitUntil("language") { tab.translationTarget != nil }
        let before = try await harness.evaluate("document.body.innerHTML", in: tab) as? String
        // Mark the link element: it must be the same element afterwards (no nodes replaced).
        _ = try await harness.evaluate("document.getElementById('link').__mark = 1", in: tab)

        let start = ContinuousClock.now
        tab.translate()
        try await waitUntil("translated") { tab.translation == .translated }
        report("translate small page: first text after \(ContinuousClock.now - start)")
        try await waitUntil("title translated", timeout: .seconds(5)) {
            translator.requests.joined().contains("Bienvenue sur notre site")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await text("title", in: harness, tab: tab) == "EN Bienvenue sur notre site")
        #expect(try await text("link", in: harness, tab: tab) == "EN Lisez la suite")
        #expect(try await harness.evaluate("document.getElementById('link').__mark === 1 && document.getElementById('link').getAttribute('href') === '/b'", in: tab) as? Bool == true)
        #expect(try await text("skip", in: harness, tab: tab) == "Ne pas traduire")
        #expect(try await text("skip2", in: harness, tab: tab) == "Marque déposée")
        #expect(try await text("code", in: harness, tab: tab) == "let x = 1")
        #expect(try await harness.evaluate("document.getElementById('field').value", in: tab) as? String == "Jean")

        tab.showOriginal()
        #expect(tab.translation == .original)
        try await Task.sleep(for: .milliseconds(100))
        let after = try await harness.evaluate("document.body.innerHTML", in: tab) as? String
        #expect(after == before, "every original text is back exactly")
    }

    @Test func translatesWhatThePageAdds() async throws {
        let translator = FakeTranslator()
        let (harness, tab) = try await makeHarness(translator)
        defer { harness.cleanUp() }
        try await harness.load("/fr", in: tab)
        try await waitUntil("language") { tab.translationTarget != nil }
        tab.translate()
        try await waitUntil("translated") { tab.translation == .translated }
        _ = try await harness.evaluate("""
            const p = document.createElement('p'); p.id = 'late'; p.textContent = 'Un nouveau paragraphe arrive';
            document.body.prepend(p);
            document.getElementById('intro').firstChild.nodeValue = 'Le texte a changé. ';
            const keep = document.createElement('span'); keep.id = 'keep'; keep.textContent = 'Toujours en français';
            document.getElementById('skip').append(keep);
            """, in: tab)
        try await waitUntil("late text translated", timeout: .seconds(5)) {
            translator.requests.joined().contains("Un nouveau paragraphe arrive")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await text("late", in: harness, tab: tab) == "EN Un nouveau paragraphe arrive")
        try await waitUntil("changed text translated", timeout: .seconds(5)) {
            translator.requests.joined().contains("Le texte a changé.")
        }
        #expect(try await text("keep", in: harness, tab: tab) == "Toujours en français", "added inside translate=no stays")
        #expect(!translator.requests.joined().contains("Toujours en français"))
    }

    @Test func aFailureBringsThePageBack() async throws {
        let translator = FakeTranslator()
        translator.fails = true
        let (harness, tab) = try await makeHarness(translator)
        defer { harness.cleanUp() }
        var failed: Tab?
        harness.pool.onTranslationFailed = { failed = $0 }
        try await harness.load("/fr", in: tab)
        try await waitUntil("language") { tab.translationTarget != nil }
        tab.translate()
        try await waitUntil("failed") { failed != nil }
        #expect(tab.translation == .original)
        #expect(try await text("title", in: harness, tab: tab) == "Bienvenue sur notre site")
    }

    @Test func aDeclinedDownloadLeavesThePage() async throws {
        let translator = FakeTranslator()
        translator.prepareAnswer = false
        let (harness, tab) = try await makeHarness(translator)
        defer { harness.cleanUp() }
        try await harness.load("/fr", in: tab)
        try await waitUntil("language") { tab.translationTarget != nil }
        tab.translate()
        try await waitUntil("back to original") { tab.translation == .original }
        #expect(translator.requests.isEmpty)
    }

    @Test func theTabKeepsTranslatingThenStopsAtShowOriginal() async throws {
        let translator = FakeTranslator()
        let (harness, tab) = try await makeHarness(translator)
        defer { harness.cleanUp() }
        try await harness.load("/fr", in: tab)
        try await waitUntil("language") { tab.translationTarget != nil }
        tab.translate()
        try await waitUntil("translated") { tab.translation == .translated }
        try await harness.load("/fr2", in: tab)
        try await waitUntil("next page translated") { tab.translation == .translated }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await text("two", in: harness, tab: tab)?.hasPrefix("EN ") == true)
        tab.showOriginal()
        try await harness.load("/fr", in: tab)
        try await waitUntil("language") { tab.translationTarget != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.translation == .original)
    }

    /// A long page: only text near the screen is translated at first; the rest follows as it
    /// scrolls near.
    @Test func longPageTranslatesWhatIsNearTheScreen() async throws {
        let translator = FakeTranslator()
        let (harness, tab) = try await makeHarness(translator)
        defer { harness.cleanUp() }
        try await harness.load("/fr-long", in: tab)
        try await waitUntil("language") { tab.translationTarget != nil }
        let start = ContinuousClock.now
        tab.translate()
        try await waitUntil("translated") { tab.translation == .translated }
        let firstText = ContinuousClock.now - start
        try await Task.sleep(for: .milliseconds(500))
        let nearCharacters = translator.characters
        let nearRequests = translator.requests.count
        report("translate 3,000 paragraphs: first text after \(firstText); near the screen \(nearRequests) requests, \(nearCharacters) characters")
        #expect(try await text("first", in: harness, tab: tab)?.hasPrefix("EN ") == true)
        #expect(try await text("p2900", in: harness, tab: tab)?.hasPrefix("EN ") == false, "far below waits")
        #expect(nearCharacters < 20_000)
        // Scroll to the end: that text is translated next.
        _ = try await harness.evaluate("document.getElementById('p2900').scrollIntoView()", in: tab)
        try await waitUntil("far text translated", timeout: .seconds(5)) {
            translator.requests.joined().contains { $0.hasPrefix("Paragraphe numéro 2900,") }
        }
        // What the page script costs in the page's process: the collection pass on start.
        let collect = try await harness.evaluate("""
            (() => { const t = performance.now(); let n = 0;
              const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
              while (w.nextNode()) n++; return performance.now() - t; })()
            """, in: tab) as? Double ?? 0
        report(String(format: "walk of the long page's text nodes in the page: %.1f ms", collect))
        let restart = try await harness.pool.existingWebView(for: tab)!.evaluateJavaScript(
            "(() => { __plainTranslate.restore(); const t = performance.now(); __plainTranslate.start(); return performance.now() - t; })()",
            in: nil, contentWorld: PageTranslation.world) as? Double ?? -1
        report(String(format: "translator start (collect and watch) on the long page: %.1f ms", restart))
    }

    @Test func recognizerPrefersTheTextOverAWrongDeclaration() {
        let french = "Nous sommes heureux de vous voir. Lisez la suite pour en savoir plus sur notre ville."
        #expect(PageLanguageRecognizer.recognize(sample: french, declared: "en")?.languageCode == "fr")
        #expect(PageLanguageRecognizer.recognize(sample: "Hi", declared: "de")?.languageCode == "de")
        #expect(PageLanguageRecognizer.recognize(sample: "", declared: "") == nil)
    }
}
#endif
