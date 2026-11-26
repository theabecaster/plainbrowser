import Foundation
import Testing
@testable import WebEngine

/// The link menu's items and the PDF check: pure rules, so they also run on macOS.
@Suite struct LinkMenuRulesTests {
    let web = URL(string: "https://example.com/page")!
    let image = URL(string: "https://example.com/a.png")!

    @Test func webLinkSections() {
        let sections = LinkMenuRules.sections(
            for: LinkElement(linkURL: web, imageURL: nil), canOpenInOtherPane: false, canSaveImages: true
        )
        #expect(sections == [[.openInNewTab, .openInBackground], [.copyLink, .share], [.downloadLinkedFile]])
    }

    @Test func otherPaneOnlyWhenTheShellHasOne() {
        let sections = LinkMenuRules.sections(
            for: LinkElement(linkURL: web, imageURL: nil), canOpenInOtherPane: true, canSaveImages: true
        )
        #expect(sections.first == [.openInNewTab, .openInBackground, .openInOtherPane])
    }

    @Test func linkedImageAddsImageSectionLast() {
        let sections = LinkMenuRules.sections(
            for: LinkElement(linkURL: web, imageURL: image), canOpenInOtherPane: false, canSaveImages: true
        )
        #expect(sections.last == [.saveImage, .copyImage])
        let noPhotos = LinkMenuRules.sections(
            for: LinkElement(linkURL: nil, imageURL: image), canOpenInOtherPane: false, canSaveImages: false
        )
        #expect(noPhotos == [[.copyImage]])
    }

    @Test func appLinksCanOnlyBeCopiedOrShared() {
        let mail = URL(string: "mailto:a@example.com")!
        let element = LinkElement(linkURL: mail, imageURL: nil)
        #expect(LinkMenuRules.sections(for: element, canOpenInOtherPane: true, canSaveImages: true) == [[.copyLink, .share]])
        #expect(!LinkMenuRules.hasPreview(element))
        #expect(LinkMenuRules.hasPreview(LinkElement(linkURL: web, imageURL: nil)))
        #expect(LinkMenuRules.sections(for: LinkElement(linkURL: nil, imageURL: nil), canOpenInOtherPane: true, canSaveImages: true).isEmpty)
    }

    @Test func onlyFetchableImageAddresses() {
        #expect(LinkMenuRules.fetchableImageURL("https://example.com/a.png") != nil)
        #expect(LinkMenuRules.fetchableImageURL("data:image/png;base64,AAAA") != nil)
        #expect(LinkMenuRules.fetchableImageURL("blob:https://example.com/123") == nil)
        #expect(LinkMenuRules.fetchableImageURL(nil) == nil)
    }

    @Test func pdfTypes() {
        #expect(NavigationRules.isPDF(mimeType: "application/pdf"))
        #expect(NavigationRules.isPDF(mimeType: "Application/PDF"))
        #expect(!NavigationRules.isPDF(mimeType: "text/html"))
        #expect(!NavigationRules.isPDF(mimeType: nil))
    }

    @Test func menuWordingIsTitleCase() {
        #expect(LinkMenuItem.allCases.map(\.title) == [
            "Open in New Tab", "Open in Background", "Open in Other Pane", "Copy Link", "Share",
            "Download Linked File", "Save Image", "Copy Image",
        ])
    }
}
