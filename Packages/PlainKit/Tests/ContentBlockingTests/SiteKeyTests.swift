import ContentBlocking
import Testing

@Suite struct SiteKeyTests {
    @Test func siteDropsWwwAndCase() {
        #expect(SiteKey.site(forHost: "WWW.Example.COM") == "example.com")
        #expect(SiteKey.site(forHost: "example.com.") == "example.com")
        #expect(SiteKey.site(forHost: "m.example.com") == "m.example.com")
        #expect(SiteKey.site(forHost: nil) == nil)
        #expect(SiteKey.site(forHost: "") == nil)
    }

    @Test func entryCoversHostAndSubdomains() {
        let sites: Set = ["example.com"]
        #expect(SiteKey.host("example.com", isIn: sites))
        #expect(SiteKey.host("www.example.com", isIn: sites))
        #expect(SiteKey.host("a.b.example.com", isIn: sites))
        #expect(!SiteKey.host("notexample.com", isIn: sites))
        #expect(!SiteKey.host("example.com.evil.net", isIn: sites))
        #expect(!SiteKey.host(nil, isIn: sites))
    }

    @Test func subdomainEntryDoesNotCoverParent() {
        let sites: Set = ["m.example.com"]
        #expect(SiteKey.host("m.example.com", isIn: sites))
        #expect(!SiteKey.host("example.com", isIn: sites))
    }
}
