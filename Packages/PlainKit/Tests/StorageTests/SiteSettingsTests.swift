import Foundation
@testable import Storage
import Testing

@Suite struct SiteSettingsTests {
    @Test func permissionsAreRememberedPerSiteAndPermission() async throws {
        let database = try AppDatabase.inMemory()
        #expect(try await database.sitePermission("camera", forSite: "https://a.example") == nil)
        try await database.setSitePermission(true, "camera", forSite: "https://a.example")
        try await database.setSitePermission(false, "microphone", forSite: "https://a.example")
        #expect(try await database.sitePermission("camera", forSite: "https://a.example") == true)
        #expect(try await database.sitePermission("microphone", forSite: "https://a.example") == false)
        #expect(try await database.sitePermission("camera", forSite: "https://b.example") == nil)
        // A second answer replaces the first.
        try await database.setSitePermission(false, "camera", forSite: "https://a.example")
        #expect(try await database.sitePermission("camera", forSite: "https://a.example") == false)
    }

    @Test func contentModesSetReplaceAndForget() async throws {
        let database = try AppDatabase.inMemory()
        #expect(try await database.siteContentModes().isEmpty)
        try await database.setSiteContentMode("desktop", forSite: "a.example")
        try await database.setSiteContentMode("mobile", forSite: "b.example")
        try await database.setSiteContentMode("mobile", forSite: "a.example")
        #expect(try await database.siteContentModes() == ["a.example": "mobile", "b.example": "mobile"])
        try await database.setSiteContentMode(nil, forSite: "a.example")
        #expect(try await database.siteContentModes() == ["b.example": "mobile"])
    }

    @Test func pageZoomsSetReplaceAndForget() async throws {
        let database = try AppDatabase.inMemory()
        #expect(try await database.sitePageZooms().isEmpty)
        try await database.setSitePageZoom(1.25, forSite: "a.example")
        try await database.setSitePageZoom(0.85, forSite: "b.example")
        try await database.setSitePageZoom(1.5, forSite: "a.example")
        #expect(try await database.sitePageZooms() == ["a.example": 1.5, "b.example": 0.85])
        try await database.setSitePageZoom(nil, forSite: "a.example")
        #expect(try await database.sitePageZooms() == ["b.example": 0.85])
    }

    @Test func blockingAllowListSavesWhole() async throws {
        let database = try AppDatabase.inMemory()
        #expect(try await database.blockingAllowList().isEmpty)
        try await database.saveBlockingAllowList(["a.example", "b.example"])
        #expect(try await database.blockingAllowList() == ["a.example", "b.example"])
        try await database.saveBlockingAllowList(["b.example"])
        #expect(try await database.blockingAllowList() == ["b.example"])
    }

    @Test func darkPagesOffSitesAreRemembered() async throws {
        let database = try AppDatabase.inMemory()
        #expect(try await database.darkPagesOffSites().isEmpty)
        try await database.setDarkPagesOff(true, forSite: "a.example")
        try await database.setDarkPagesOff(true, forSite: "a.example")
        try await database.setDarkPagesOff(true, forSite: "b.example")
        #expect(try await database.darkPagesOffSites() == ["a.example", "b.example"])
        try await database.setDarkPagesOff(false, forSite: "a.example")
        #expect(try await database.darkPagesOffSites() == ["b.example"])
    }
}
