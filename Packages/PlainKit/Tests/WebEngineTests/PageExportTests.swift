#if canImport(UIKit)
import Foundation
import PDFKit
import Testing
import UIKit
import WebKit
@testable import WebEngine

/// Print and Save as PDF: a paginated PDF with the page's print styles, lazy pictures loaded
/// first, file names Files accepts, and what a long page costs on the main thread.
@Suite(.serialized) @MainActor
struct PageExportTests {
    nonisolated static let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

    @Sendable nonisolated static func route(_ request: TestServer.Request) -> TestServer.Response {
        switch request.path {
        case "/article":
            return .html(Pages.page(title: "Print Me", body: """
                <style>@media print { .screen-only { display: none } }</style>
                <h1>Print Me</h1><p class=screen-only>Only on screen</p>
                \(String(repeating: "<p>A paragraph of text that wraps across the line and fills the page.</p>", count: 120))
                <div style="height:3000px"></div><img id=lazy loading=lazy width=10 height=10 src="/pic.png">
                """))
        case "/pic.png":
            return .data(Data(base64Encoded: String(png.split(separator: ",")[1]))!, type: "image/png")
        case "/long":
            var body = ""
            for i in 0..<3_000 { body += "<p>Paragraph \(i) with <a href='#\(i)'>a link</a> and some text to wrap.</p>" }
            return .html(Pages.page(title: "Long", body: body))
        default:
            return Pages.route(request)
        }
    }

    @Test func savesAPaginatedPDFWithPrintStyles() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/article", in: tab)
        let webView = try #require(harness.pool.existingWebView(for: tab))

        await PageExport.loadLazyImages(in: webView)
        #expect(try await harness.evaluate("document.getElementById('lazy').complete", in: tab) as? Bool == true)

        let data = await PageExport.pdf(of: webView, title: tab.title, paperSize: CGSize(width: 595.28, height: 841.89))
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount >= 2, "a long article spans pages")
        let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 595.28) < 1 && abs(bounds.height - 841.89) < 1, "A4")
        let text = document.string ?? ""
        #expect(text.contains("Print Me"))
        #expect(!text.contains("Only on screen"), "the page's print styles apply")
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Print Me")
    }

    @Test func printFormatterHasPages() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/article", in: tab)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: 36, dy: 36)), forKey: "printableRect")
        #expect(renderer.numberOfPages >= 2)
    }

    /// The cost of Save as PDF on a long page, held on the main thread.
    @Test func longPageCost() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/long", in: tab)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        var total: [Duration] = []
        var layout: [Duration] = []
        var longestPage: [Duration] = []
        var pages = 0
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let data = await PageExport.pdf(of: webView, title: "Long")
            total.append(ContinuousClock.now - start)
            layout.append(PageExport.lastTimings.layout)
            longestPage.append(PageExport.lastTimings.longestPage)
            pages = PDFDocument(data: data)?.pageCount ?? 0
        }
        report("save as PDF, 3,000 paragraphs (\(pages) pages): total \(describe(total))")
        report("save as PDF main-thread holds: layout \(describe(layout)); longest page \(describe(longestPage))")
        #expect(pages > 20)
    }

    @Test func fileNamesFilesAccepts() {
        #expect(PageExport.fileName(title: "Report: Q3/Q4 *final*", url: nil) == "Report Q3 Q4 final.pdf")
        #expect(PageExport.fileName(title: "  ", url: URL(string: "https://www.example.com/x")) == "example.com.pdf")
        #expect(PageExport.fileName(title: nil, url: nil) == "Page.pdf")
        #expect(PageExport.fileName(title: "doc.pdf", url: nil) == "doc.pdf")
        #expect(PageExport.fileName(title: String(repeating: "a", count: 300), url: nil).count == 104)
    }

    @Test func paperFollowsTheRegion() {
        #expect(PageExport.paperSize(for: Locale(identifier: "en_US")).width == 612)
        #expect(PageExport.paperSize(for: Locale(identifier: "fr_FR")).width < 600)
    }
}
#endif
