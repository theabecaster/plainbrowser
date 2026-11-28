import BrowserCore
import Foundation
import Testing

/// Dark Pages' choices and its one suggestion (docs/research/dark-pages-optin.md, "State model").
@Suite struct DarkPagesRulesTests {
    // MARK: Choices

    @Test func startsOffForEveryone() {
        #expect(!FixedChoices.darkPagesDefaultEnabled)
        #expect(!DarkPagesChoices().applies(to: "example.com"))
        #expect(!BrowserSettings.defaults.darkPages)
    }

    @Test func aSiteChoiceBeatsTheSwitchEitherWay() {
        var choices = DarkPagesChoices(enabled: false)
        choices.setChoice(.on, for: "a.example")
        #expect(choices.applies(to: "a.example"), "on for this site while the switch is off")
        #expect(!choices.applies(to: "b.example"))
        choices.enabled = true
        choices.setChoice(.off, for: "b.example")
        #expect(!choices.applies(to: "b.example"), "off for this site while the switch is on")
        #expect(choices.applies(to: "c.example"))
        choices.enabled = false
        #expect(choices.applies(to: "a.example"), "the switch never clears a site's choice")
        #expect(choices.choice(for: "b.example") == .off)
    }

    @Test func aSiteIsInOneListAtMost() {
        var choices = DarkPagesChoices(onSites: ["a.example"], offSites: ["a.example"])
        #expect(choices.choice(for: "a.example") == .off, "a conflicting pair resolves to the safe side")
        choices.setChoice(.on, for: "a.example")
        #expect(choices.onSites == ["a.example"] && choices.offSites.isEmpty)
        choices.setChoice(.off, for: "a.example")
        #expect(choices.onSites.isEmpty && choices.offSites == ["a.example"])
        choices.setChoice(.automatic, for: "a.example")
        #expect(choices.onSites.isEmpty && choices.offSites.isEmpty)
    }

    @Test func theIndicatorTogglesBetweenAppliedAndNot() {
        var choices = DarkPagesChoices(enabled: true)
        // Applied by the switch: off for this site, then back to following the switch.
        #expect(choices.toggled(for: "a.example") == .off)
        choices.setChoice(.off, for: "a.example")
        #expect(choices.toggled(for: "a.example") == .automatic)
        // The switch off: on for this site, then off for it.
        choices = DarkPagesChoices(enabled: false)
        #expect(choices.toggled(for: "a.example") == .on)
        choices.setChoice(.on, for: "a.example")
        #expect(choices.toggled(for: "a.example") == .off)
        choices.setChoice(.off, for: "a.example")
        #expect(choices.toggled(for: "a.example") == .on)
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
