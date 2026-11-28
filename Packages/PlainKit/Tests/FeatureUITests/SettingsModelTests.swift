import BrowserCore
@testable import FeatureUI
import Foundation
import Storage
import Testing

@MainActor
@Suite struct SettingsModelTests {
    let database: AppDatabase
    let clearer = RecordingClearer()

    init() throws {
        database = try AppDatabase.inMemory()
    }

    func makeModel() -> SettingsModel {
        SettingsModel(store: database, clearer: clearer, about: testAbout)
    }

    @Test func loadsDefaultsThenSavedValues() async throws {
        let model = makeModel()
        await model.load()
        #expect(model.isLoaded)
        #expect(model.settings == .defaults)

        try await database.saveSettings(BrowserSettings(searchEngine: .kagi, tabLayout: .right, archiveAfter: .never))
        await model.load()
        #expect(model.settings.searchEngine == .kagi)
        #expect(model.settings.tabLayout == .right)
        #expect(model.settings.archiveAfter == .never)
    }

    @Test func everyChoiceIsSavedInOrder() async throws {
        let model = makeModel()
        await model.load()
        model.selectSearchEngine(.duckDuckGo)
        model.setTabLayout(.right)
        model.setArchiveAfter(.twelveHours)
        model.setArchiveAfter(.oneWeek)
        model.setAppearance(.dark)
        model.setAppearance(.light)
        await model.waitForSaves()
        let saved = try await database.settings()
        #expect(saved == BrowserSettings(searchEngine: .duckDuckGo, tabLayout: .right, archiveAfter: .oneWeek, appearance: .light))
    }

    @Test func darkPagesSwitchIsSavedAndOffByDefault() async throws {
        let model = makeModel()
        await model.load()
        #expect(!model.settings.darkPages)
        #expect(model.isDarkPagesAvailable)
        model.setDarkPages(true)
        await model.waitForSaves()
        #expect(try await database.settings().darkPages)
        #expect(try await database.settings().appearance == .system, "Dark Pages never touches Appearance")
        model.setAppearance(.light)
        #expect(!model.isDarkPagesAvailable, "nothing to darken while Plain is set to Light")
        #expect(model.settings.darkPages, "the switch keeps its value")
    }

    /// Two windows' Settings (or Settings and the Dark Pages suggestion): each change is saved over
    /// what is stored, so neither writes the other's old value back.
    @Test func twoModelsNeverUndoEachOther() async throws {
        let first = makeModel(), second = makeModel()
        await first.load()
        await second.load()
        first.setDarkPages(true)
        second.setTabLayout(.right)
        await first.waitForSaves()
        await second.waitForSaves()
        let stored = try await database.settings()
        #expect(stored.darkPages && stored.tabLayout == .right)
    }

    @Test func customEngineIsValidatedNamedAndSaved() async throws {
        let model = makeModel()
        await model.load()

        model.customTemplate = "https://search.example.com/find"
        #expect(model.useCustomTemplate() == false)
        #expect(model.customError?.contains("%s") == true)
        #expect(model.settings.searchEngine == .google)

        model.customTemplate = "not a url %s"
        #expect(model.useCustomTemplate() == false)
        #expect(model.customError != nil)

        model.customTemplate = "www.search.example.com/find?q=%s"
        #expect(model.customError == nil, "typing clears the error")
        #expect(model.useCustomTemplate())
        #expect(model.settings.searchEngine.isCustom)
        #expect(model.settings.searchEngine.name == "search.example.com")
        #expect(model.settings.searchEngine.template == "https://www.search.example.com/find?q=%s")
        #expect(model.engineChoices.last == model.settings.searchEngine)

        await model.waitForSaves()
        #expect(try await database.settings().searchEngine.template == "https://www.search.example.com/find?q=%s")

        // Switching away keeps the custom engine on offer.
        model.selectSearchEngine(.google)
        await model.waitForSaves()
        let reloaded = makeModel()
        await reloaded.load()
        #expect(reloaded.settings.searchEngine == .google)
        #expect(reloaded.engineChoices.last?.isCustom == true)
        #expect(reloaded.customTemplate == "https://www.search.example.com/find?q=%s")
    }

    @Test func customEngineErrors() throws {
        #expect(throws: SearchEngine.TemplateError.notAWebURL) { try SettingsModel.customEngine(from: "") }
        #expect(throws: SearchEngine.TemplateError.notAWebURL) { try SettingsModel.customEngine(from: "ftp://x.example/?q=%s") }
        #expect(throws: SearchEngine.TemplateError.missingPlaceholder) { try SettingsModel.customEngine(from: "https://x.example/") }
        #expect(try SettingsModel.customEngine(from: " http://x.example/?q=%s ").template == "http://x.example/?q=%s")
    }

    @Test func choicesWaitForTheFirstLoad() async throws {
        try await database.saveSettings(BrowserSettings(searchEngine: .kagi, tabLayout: .right, archiveAfter: .never))
        let model = makeModel()
        model.setArchiveAfter(.oneWeek)
        model.selectSearchEngine(.bing)
        model.customTemplate = "https://x.example/?q=%s"
        #expect(model.useCustomTemplate() == false)
        await model.waitForSaves()
        #expect(try await database.settings().searchEngine == .kagi, "nothing saved before loading")
        await model.load()
        #expect(model.settings.archiveAfter == .never)
    }

    @Test func failedSaveShowsWhatIsStoredSoItCanBeRetried() async throws {
        let model = SettingsModel(store: FlakySettings(database: database, failSaves: true), clearer: clearer, about: testAbout)
        await model.load()
        model.setTabLayout(.right)
        #expect(model.settings.tabLayout == .right)
        await model.waitForSaves()
        await model.waitForSaves()
        #expect(model.errorMessage != nil)
        #expect(model.settings.tabLayout == FixedChoices.defaultTabLayout, "back to the stored value, so choosing again saves again")
    }

    @Test func aLoadWaitsForSavesStillRunning() async throws {
        let model = SettingsModel(
            store: FlakySettings(database: database, failSaves: false, saveDelay: .milliseconds(50)),
            clearer: clearer, about: testAbout
        )
        await model.load()
        model.setTabLayout(.right)
        await model.load()
        #expect(model.settings.tabLayout == .right)
    }

    @Test func clearHistoryAndDataCallsTheClearer() async {
        let model = makeModel()
        await model.clearHistoryAndData()
        #expect(await clearer.count == 1)
        #expect(model.isClearing == false)
        #expect(model.errorMessage == nil)
    }

    @Test func clearFailureShowsAMessage() async {
        let model = SettingsModel(store: database, clearer: FailingClearer(), about: testAbout)
        await model.clearHistoryAndData()
        #expect(model.errorMessage != nil)
        #expect(model.isClearing == false)
    }

    @Test func wordingIsTitleCaseAndFootersAreSentences() {
        #expect(TabLayout.allCases.map(\.title) == ["Above", "Left", "Right"])
        #expect(ArchiveAfter.allCases.map(\.title) == ["After 12 Hours", "After 1 Day", "After 1 Week", "Never"])
        for archive in ArchiveAfter.allCases {
            #expect(archive.footer.hasSuffix("."))
            #expect(archive.footer.filter { $0 == "." }.count == 1)
        }
    }
}

let testAbout = AboutInfo(name: "Plain", version: "1.0", build: "1", documents: [])

/// Settings in a real database, with saves that fail on demand.
final class FlakySettings: SettingsStoring {
    let database: AppDatabase
    let failSaves: Bool
    let saveDelay: Duration
    init(database: AppDatabase, failSaves: Bool, saveDelay: Duration = .zero) {
        self.database = database
        self.failSaves = failSaves
        self.saveDelay = saveDelay
    }
    func settings() async throws -> BrowserSettings { try await database.settings() }
    func savedCustomSearchEngine() async throws -> SearchEngine? { try await database.savedCustomSearchEngine() }
    func saveSettings(_ settings: BrowserSettings) async throws {
        try await Task.sleep(for: saveDelay)
        if failSaves { throw URLError(.unknown) }
        try await database.saveSettings(settings)
    }
}

actor RecordingClearer {
    private(set) var count = 0
    func clearHistoryAndData() async throws { count += 1 }
}

extension RecordingClearer: BrowsingDataClearing {}

struct FailingClearer: BrowsingDataClearing {
    struct Failure: Error {}
    func clearHistoryAndData() async throws { throw Failure() }
}
