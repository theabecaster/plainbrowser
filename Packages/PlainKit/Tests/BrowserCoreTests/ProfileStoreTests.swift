@testable import BrowserCore
import Foundation
import Testing

/// Profiles in `TabStore`: each profile's own tab list inside a window, the window's profile
/// following the tab on screen, and deletion (docs/decisions.md, "Profiles, no tab groups").
@MainActor
@Suite struct ProfileStoreTests {
    let clock = TestClock()
    let persistence = RecordingPersistence()

    func makeStore(_ session: TabSession = .empty) -> TabStore {
        let clock = clock
        return TabStore(session: session, persistence: persistence, now: { clock.now })
    }

    func url(_ name: String) -> URL { URL(string: "https://\(name).example/")! }

    @Test func personalAlwaysComesFirst() {
        #expect(makeStore().profiles == [.personal])
        let work = Profile(name: "Work")
        let renamed = Profile(id: Profile.defaultID, name: "Home")
        let store = makeStore(TabSession(profiles: [work, renamed, work]))
        #expect(store.profiles == [renamed, work])
    }

    @Test func namesAreCleanedAndUnique() throws {
        let store = makeStore()
        #expect(store.addProfile(named: "   ") == nil)
        let work = try #require(store.addProfile(named: "  Side   project  "))
        #expect(store.profile(work)?.name == "Side project")
        #expect(store.addProfile(named: "side PROJECT") == nil, "case-insensitive duplicate")
        #expect(store.addProfile(named: "personal") == nil)
        #expect(!store.renameProfile(work, to: "Personal"))
        #expect(store.renameProfile(work, to: "Work"))
        #expect(store.renameProfile(Profile.defaultID, to: "Home"))
        #expect(store.profiles.map(\.name) == ["Home", "Work"])
        let long = String(repeating: "x", count: 40)
        let third = try #require(store.addProfile(named: long))
        #expect(store.profile(third)?.name.count == FixedChoices.profileNameLimit)
    }

    @Test func profilesStopAtTheLimit() {
        let store = makeStore()
        for number in 1 ..< FixedChoices.maxProfiles { #expect(store.addProfile(named: "P\(number)") != nil) }
        #expect(!store.canAddProfile)
        #expect(store.addProfile(named: "One more") == nil)
    }

    @Test func eachProfileListsItsOwnTabsAndTheWindowFollowsTheTabOnScreen() throws {
        let store = makeStore()
        let window = store.windows[0].id
        let a = store.open(url("a"))
        let work = try #require(store.addProfile(named: "Work"))
        #expect(store.profileID(of: window) == Profile.defaultID, "adding switches nothing")
        let b = store.open(url("b"), profile: work)
        #expect(store.tabs[b]?.profileID == work)
        #expect(store.profileID(of: window) == work, "showing a Work tab makes the window Work")
        let c = store.open(url("c"))
        #expect(store.tabs[c]?.profileID == work, "new tabs open in the window's profile")
        #expect(store.tabs(in: window).map(\.id) == [b, c])
        #expect(store.tabs(in: window, profile: Profile.defaultID).map(\.id) == [a])
        let child = store.open(url("d"), opener: a, inBackground: true)
        #expect(store.tabs[child]?.profileID == Profile.defaultID, "a link keeps its opener's profile")
        store.select(a)
        #expect(store.profileID(of: window) == Profile.defaultID)
        let secret = store.open(url("p"), isPrivate: true)
        #expect(store.profileID(of: window) == Profile.defaultID, "a private tab changes no profile")
        #expect(store.tabs(in: window, private: true).map(\.id) == [secret])
    }

    @Test func closingATabShowsOneOfTheSameProfile() throws {
        let store = makeStore()
        let window = store.windows[0].id
        let work = try #require(store.addProfile(named: "Work"))
        let a = store.open(url("a"))
        let b = store.open(url("b"), profile: work)
        _ = store.open(url("c"))
        store.select(b)
        store.close(b)
        // `c` is Work's; `a` is Personal's and sits before b.
        #expect(store.tabs[store.selectedTabID(in: window)!]?.profileID == work)
        store.close(store.selectedTabID(in: window)!)
        #expect(store.selectedTabID(in: window) == nil, "never another profile's page")
        #expect(store.tabs[a] != nil)
    }

    @Test func moveReordersOnlyInsideTheProfile() throws {
        let store = makeStore()
        let window = store.windows[0].id
        let work = try #require(store.addProfile(named: "Work"))
        let a = store.open(url("a"))
        let w1 = store.open(url("w1"), profile: work)
        let b = store.open(url("b"), profile: Profile.defaultID)
        let w2 = store.open(url("w2"), profile: work)
        store.move(w2, to: 0)
        #expect(store.tabs(in: window, profile: work).map(\.id) == [w2, w1])
        #expect(store.tabs(in: window, profile: Profile.defaultID).map(\.id) == [a, b])
        #expect(store.windows[0].tabIDs == [a, w2, b, w1])
    }

    @Test func closeAllClosesOneProfile() throws {
        let store = makeStore()
        let window = store.windows[0].id
        let work = try #require(store.addProfile(named: "Work"))
        let a = store.open(url("a"))
        _ = store.open(url("w1"), profile: work)
        _ = store.open(url("w2"), profile: work)
        store.closeAllTabs(in: window, profile: work)
        #expect(store.tabs(in: window, profile: work).isEmpty)
        #expect(store.tabs(in: window, profile: Profile.defaultID).map(\.id) == [a])
        #expect(store.lastClosedBatch(in: work)?.tabs.count == 2)
        #expect(store.lastClosedBatch(in: Profile.defaultID) == nil)
    }

    @Test func reopenStaysInTheProfile() throws {
        let store = makeStore()
        let work = try #require(store.addProfile(named: "Work"))
        let a = store.open(url("a"))
        let w = store.open(url("w"), profile: work)
        store.close(a)
        store.close(w)
        // Reopen in Personal brings back Personal's close, not the newer Work one.
        #expect(store.reopenLastClosed(in: Profile.defaultID) == [a])
        #expect(store.reopenLastClosed(in: Profile.defaultID).isEmpty)
        #expect(store.reopenLastClosed(in: work) == [w])
    }

    @Test func deletingAProfileTakesItsTabsAndMovesTheWindowToPersonal() throws {
        let store = makeStore()
        let window = store.windows[0].id
        let work = try #require(store.addProfile(named: "Work"))
        let a = store.open(url("a"))
        let w1 = store.open(url("w1"), profile: work)
        let w2 = store.open(url("w2"), profile: work)
        store.close(w2)
        let secret = store.open(url("p"), isPrivate: true)
        store.select(w1)
        let removed = store.deleteProfile(work)
        #expect(removed == [w1])
        #expect(store.profiles == [.personal])
        #expect(store.tabs[w1] == nil)
        #expect(store.tabs[secret] != nil, "private tabs are no profile's data")
        #expect(store.profileID(of: window) == Profile.defaultID)
        #expect(store.selectedTabID(in: window) == a, "the pane shows Personal's latest tab")
        #expect(store.lastClosedBatch(in: work) == nil)
        #expect(store.recentlyClosed.isEmpty)
        #expect(persistence.recorded.contains(.deleteProfile(work)))
        #expect(persistence.lastSession?.profiles == [.personal])
        #expect(store.deleteProfile(Profile.defaultID).isEmpty, "Personal stays")
    }

    @Test func aSessionKeepsProfilesAndDropsTabsOfMissingOnes() throws {
        let store = makeStore()
        let work = try #require(store.addProfile(named: "Work"))
        _ = store.open(url("a"))
        let w = store.open(url("w"), profile: work)
        var saved = try #require(persistence.lastSession)
        #expect(saved.windows[0].profileID == work)
        let restored = makeStore(saved)
        #expect(restored.profiles.map(\.name) == ["Personal", "Work"])
        #expect(restored.profileID(of: restored.windows[0].id) == work)
        #expect(restored.tabs[w]?.profileID == work)
        saved.profiles = []
        let orphaned = makeStore(saved)
        #expect(orphaned.tabs[w] == nil, "a gone profile's tab never shows up in Personal")
        #expect(orphaned.profileID(of: orphaned.windows[0].id) == Profile.defaultID)
    }

    @Test func archiveRestoreKeepsTheProfile() throws {
        let store = makeStore()
        let work = try #require(store.addProfile(named: "Work"))
        let entry = TabEntry(url: url("old"), profileID: work, createdAt: clock.now)
        let id = store.restoreArchived(entry)
        #expect(store.tabs[id]?.profileID == work)
        #expect(store.profileID(of: store.windows[0].id) == work)
    }

    @Test func galleryRulesForProfiles() {
        var state = GalleryState()
        state.listCount = 1
        #expect(!GalleryRules(state).more, "no profiles in this data source")
        state.profileCount = 1
        #expect(GalleryRules(state).newProfile)
        #expect(GalleryRules(state).more)
        #expect(!GalleryRules(state).profileSwitcher)
        state.profileCount = 2
        #expect(!GalleryRules(state).newProfile, "it moves to the switcher's menu")
        #expect(GalleryRules(state).profileSwitcher)
        state.isPrivateList = true
        #expect(!GalleryRules(state).profileSwitcher)
        #expect(!GalleryRules(state).newProfile)
    }
}
