#if canImport(UIKit)
import LinkPresentation
@testable import ShellUI
import Testing
import UIKit

/// The page's share item: every activity still gets the plain URL (Copy, Messages, Plain's Print and
/// Save as PDF), and the sheet's header and a mail's subject get the title when there is one.
@MainActor
struct PageShareItemTests {
    let url = URL(string: "https://example.com/a")!

    @Test func everyActivityGetsTheURL() {
        let item = PageShareItem(url: url, title: "Example")
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        #expect(item.activityViewControllerPlaceholderItem(sheet) as? URL == url)
        #expect(item.activityViewController(sheet, itemForActivityType: .copyToPasteboard) as? URL == url)
        #expect(item.activityViewController(sheet, itemForActivityType: PageActivity.printType) as? URL == url)
    }

    @Test func theTitleHeadsTheSheetAndTheMail() {
        let item = PageShareItem(url: url, title: "Example")
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        let metadata = item.activityViewControllerLinkMetadata(sheet)
        #expect(metadata?.title == "Example")
        #expect(metadata?.url == url)
        #expect(item.activityViewController(sheet, subjectForActivityType: .mail) == "Example")
    }

    @Test func aPageWithoutATitleSharesOnlyItsAddress() {
        let item = PageShareItem(url: url, title: nil)
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        #expect(item.activityViewControllerLinkMetadata(sheet)?.title == nil)
        #expect(item.activityViewController(sheet, subjectForActivityType: .mail) == "")
    }
}
#endif
