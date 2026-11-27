#if canImport(UIKit)
import BrowserCore
import PerfSignposts
import UIKit
import WebKit

/// Print and Save as PDF for a page or the reader's article (docs/research/print-pdf.md).
///
/// Both go through WebKit's print formatter, so the page's `@media print` styles apply and the
/// output is cut into paper-sized pages, as a printer would get them. `createPDF` was not used: it
/// draws the screen styles as one tall page, which reads badly in every PDF viewer.
public enum PageExport {
    /// The paper Plain prints and saves on, chosen by the region: US Letter where it is the
    /// standard (`FixedChoices.letterPaperRegions`), A4 everywhere else.
    public static func paperSize(for locale: Locale = .current) -> CGSize {
        let region = locale.region?.identifier ?? ""
        return FixedChoices.letterPaperRegions.contains(region)
            ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }

    /// Asks lazily loaded pictures to load now and waits for them, at most
    /// `FixedChoices.exportImageWait`: WebKit prints a `loading=lazy` picture that never scrolled
    /// into view as a blank box. Runs in the engine's world; the page can't see it.
    public static func loadLazyImages(in webView: WKWebView) async {
        let script = """
            const lazy = [...document.querySelectorAll('img[loading="lazy"]')];
            for (const img of lazy) img.loading = 'eager';
            const pending = lazy.filter((img) => !img.complete);
            if (pending.length === 0) return 0;
            await Promise.race([
              Promise.allSettled(pending.map((img) => img.decode())),
              new Promise((resolve) => setTimeout(resolve, \(FixedChoices.exportImageWait.milliseconds))),
            ]);
            return pending.length;
            """
        await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: UserScripts.world) { _ in
                continuation.resume()
            }
        }
    }

    /// How long each step of the last `pdf(of:)` held the main thread, for the perf test.
    static var lastTimings: (layout: Duration, longestPage: Duration, pages: Int) = (.zero, .zero, 0)

    /// The page as a paginated PDF on `paperSize` with `FixedChoices.exportMargin` margins.
    ///
    /// The print formatter works on the main thread. Laying out the printed pages is one wait on
    /// the page's process; each page is then drawn on its own turn of the main run loop, so a
    /// hundred-page document never holds the main thread for more than one page at a time and
    /// touches, scrolling and the spinner keep going (measured in `PageExportTests`). Call it from
    /// a menu action, never from a gesture or scroll path.
    public static func pdf(of webView: WKWebView, title: String?, paperSize: CGSize = paperSize()) async -> Data {
        let clock = ContinuousClock()
        let layoutStart = clock.now
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = CGRect(origin: .zero, size: paperSize)
        let margin = FixedChoices.exportMargin
        // Read-only properties without a public setter: KVC is the documented way in.
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: margin, dy: margin)), forKey: "printableRect")
        let pages = renderer.numberOfPages
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        let layout = clock.now - layoutStart

        let data = NSMutableData()
        var info: [CFString: Any] = [kCGPDFContextCreator: "Plain"]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        var mediaBox = paper
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else { return Data() }
        var longest = Duration.zero
        for page in 0..<pages {
            let pageStart = clock.now
            context.beginPDFPage(nil)
            // UIKit drawing goes to the current context: pushed only while this page draws, so
            // nothing else on the main thread can draw into the PDF between pages.
            UIGraphicsPushContext(context)
            // Core Graphics' PDF space starts at the bottom; UIKit drawing expects the top.
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            renderer.drawPage(at: page, in: paper)
            UIGraphicsPopContext()
            context.endPDFPage()
            longest = max(longest, clock.now - pageStart)
            await Task.yield()
        }
        context.closePDF()
        lastTimings = (layout, longest, pages)
        return data as Data
    }

    /// Writes a saved PDF where the share sheet can hand it on: a folder of its own under the
    /// temporary directory, named for the page. Folders left from earlier exports are removed
    /// first. Disk work: call it off the main thread.
    nonisolated public static func writeTemporaryFile(_ data: Data, named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "PlainPDF", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// A file name for the page: its title, else its site, else "Page", without characters Files
    /// and AirDrop reject, at most `FixedChoices.exportFileNameLength` characters, plus `.pdf`.
    public static func fileName(title: String?, url: URL?) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            let cleaned = text.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return cleaned.isEmpty ? nil : String(cleaned.prefix(FixedChoices.exportFileNameLength))
        }
        let host = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        var name = clean(title) ?? clean(host) ?? "Page"
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        return name + ".pdf"
    }
}

private extension Duration {
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
#endif
