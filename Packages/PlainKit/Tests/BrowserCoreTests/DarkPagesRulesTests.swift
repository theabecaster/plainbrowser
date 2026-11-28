import BrowserCore
import Foundation
import Testing

/// Dark Pages' choices and its one suggestion (docs/research/dark-pages-optin.md, "State model").
@Suite struct DarkPagesRulesTests {
    // MARK: Page appearance

    @Test func startsUnchosenAndShowsSitesAsMade() {
        #expect(FixedChoices.defaultPageAppearance == nil)
        #expect(PageAppearanceChoices().appearance(for: "example.com") == .off)
        #expect(!PageAppearanceChoices().darkens("example.com"))
        #expect(BrowserSettings.defaults.pageAppearance == nil)
    }

    @Test func theFirstPickBecomesTheDefaultForEverySite() {
        var choices = PageAppearanceChoices()
        #expect(choices.choose(.dark, for: "a.example") == .becameDefault(previous: nil))
        #expect(choices.defaultAppearance == .dark)
        #expect(choices.appearance(for: "new.example") == .dark, "the default applies to a new site")
        #expect(!choices.hasOwnChoice("a.example"))
    }

    @Test func laterPicksAreForThatSiteOnly() {
        var choices = PageAppearanceChoices(defaultAppearance: .dark)
        #expect(choices.choose(.off, for: "broken.example") == .thisSite)
        #expect(choices.appearance(for: "broken.example") == .off)
        #expect(choices.hasOwnChoice("broken.example"))
        #expect(choices.defaultAppearance == .dark, "a site's fix never changes the default")
        #expect(choices.appearance(for: "other.example") == .dark)
        // Picking what the default already is: the site follows the default again.
        choices.choose(.dark, for: "broken.example")
        #expect(!choices.hasOwnChoice("broken.example"))
    }

    @Test func aSiteExceptionSurvivesADefaultChange() {
        var choices = PageAppearanceChoices(defaultAppearance: .dark)
        choices.choose(.off, for: "broken.example")
        choices.choose(.light, for: "news.example")
        choices.useForAllSites(from: "news.example")
        #expect(choices.defaultAppearance == .light)
        #expect(!choices.hasOwnChoice("news.example"))
        #expect(choices.appearance(for: "broken.example") == .off, "another site's own choice stays")
        #expect(choices.appearance(for: "new.example") == .light)
    }

    @Test func thisSiteOnlyUndoesAFirstPick() {
        var choices = PageAppearanceChoices()
        guard case .becameDefault(let previous) = choices.choose(.light, for: "a.example") else {
            Issue.record("the first pick becomes the default")
            return
        }
        choices.keepForThisSiteOnly(.light, site: "a.example", previous: previous)
        #expect(choices.defaultAppearance == nil)
        #expect(choices.appearance(for: "a.example") == .light)
        #expect(choices.appearance(for: "b.example") == .off)
    }

    @Test func onlyDarkDarkens() {
        let choices = PageAppearanceChoices(defaultAppearance: .dark, sites: ["l.example": .light, "o.example": .off])
        #expect(choices.darkens("x.example"))
        #expect(!choices.darkens("l.example"))
        #expect(!choices.darkens("o.example"))
        #expect(choices.sites(choosing: .light) == ["l.example"])
    }

    // MARK: The suggestion

    @Test func neverAskedShowsOnTheFirstEligiblePage() {
        #expect(DarkPagesSuggestion.neverAsked.mayShow(onSite: "a.example", session: 0))
    }

    @Test func ignoredShowsAgainOnAnotherSiteNextTime() {
        let ignored = DarkPagesSuggestion.neverAsked.shown(onSite: "a.example", session: 1)
        #expect(ignored == .ignored(site: "a.example", session: 1))
        #expect(!ignored.mayShow(onSite: "b.example", session: 1), "not again in the same session")
        #expect(!ignored.mayShow(onSite: "a.example", session: 2), "not on the site it was ignored on")
        #expect(ignored.mayShow(onSite: "b.example", session: 2), "another site, next time")
        // Ignored again: the same rule from there, with no limit on how often.
        let again = ignored.shown(onSite: "b.example", session: 2)
        #expect(again.mayShow(onSite: "a.example", session: 3))
        #expect(!again.mayShow(onSite: "b.example", session: 3))
    }

    @Test func declinedAndAcceptedAreFinal() {
        for answer in [DarkPagesSuggestion.declined, .accepted] {
            #expect(!answer.mayShow(onSite: "a.example", session: 99))
            #expect(answer.shown(onSite: "a.example", session: 99) == answer)
            #expect(answer.isAnswered)
        }
    }

    @Test func showsOnlyAtTheRightMoment() {
        let ready = DarkPagesSuggestion.Moment(page: .available, isPrivate: false, settingsLoaded: true, isBarShowing: true, isBusy: false)
        #expect(DarkPagesSuggestion.neverAsked.shouldShow(onSite: "a.example", session: 0, at: ready))
        var moment = ready
        for page in [DarkPagesPage.none, .darkened, .off] {
            moment.page = page
            #expect(!DarkPagesSuggestion.neverAsked.shouldShow(onSite: "a.example", session: 0, at: moment),
                    "\(page): light colors, a dark design, applied, or turned off here")
        }
        moment = ready
        moment.isPrivate = true
        #expect(!DarkPagesSuggestion.neverAsked.shouldShow(onSite: "a.example", session: 0, at: moment), "never private")
        moment = ready
        moment.settingsLoaded = false
        #expect(!DarkPagesSuggestion.neverAsked.shouldShow(onSite: "a.example", session: 0, at: moment))
        moment = ready
        moment.isBarShowing = false
        #expect(!DarkPagesSuggestion.neverAsked.shouldShow(onSite: "a.example", session: 0, at: moment))
        moment = ready
        moment.isBusy = true
        #expect(!DarkPagesSuggestion.neverAsked.shouldShow(onSite: "a.example", session: 0, at: moment), "keyboard, sheet, toast")
        #expect(!DarkPagesSuggestion.declined.shouldShow(onSite: "a.example", session: 0, at: ready))
        #expect(!DarkPagesSuggestion.accepted.shouldShow(onSite: "a.example", session: 0, at: ready))
        moment = ready
        moment.hasDefault = true
        #expect(!DarkPagesSuggestion.neverAsked.shouldShow(onSite: "a.example", session: 0, at: moment),
                "a default page appearance is already an answer")
    }

    @Test func storeRemembersAndAnswersOnce() throws {
        let suite = "plain.tests.darkPagesSuggestion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DarkPagesSuggestionStore(defaults: defaults)
        #expect(store.state == .neverAsked)
        store.state = store.state.shown(onSite: "a.example", session: 1)
        #expect(DarkPagesSuggestionStore(defaults: defaults).state == .ignored(site: "a.example", session: 1))
        let first = store.session
        store.beginSession()
        #expect(DarkPagesSuggestionStore(defaults: defaults).session == first + 1, "sessions count across launches")
        store.answer(false)
        #expect(store.state == .declined)
        store.answer(true)
        #expect(store.state == .declined, "an answer is final: turning it on later changes nothing here")
    }

    @Test func settingsSwitchCountsAsAccepted() throws {
        let suite = "plain.tests.darkPagesSuggestion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DarkPagesSuggestionStore(defaults: defaults)
        store.state = .ignored(site: "a.example", session: 1)
        store.answer(true)
        #expect(store.state == .accepted)
        #expect(!store.state.mayShow(onSite: "b.example", session: 5))
    }
}
