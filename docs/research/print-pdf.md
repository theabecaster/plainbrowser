# Print and Save as PDF (WKWebView, iOS 27)

Researched 2026-11-26. "Verified" means checked in source or Apple docs. "Reported" means forum or third-party claims only.

## 1. Printing a WKWebView

**API (verified).** `UIPrintInteractionController.shared` takes content through exactly one of four properties: `printingItem`, `printingItems`, `printFormatter` or `printPageRenderer`. They are mutually exclusive. [Apple docs](https://developer.apple.com/documentation/uikit/uiprintinteractioncontroller)

- `webView.viewPrintFormatter()` returns WebKit's `_WKWebViewPrintFormatter`. It asks the WebContent process to lay out the page in print mode, so `@media print` applies, and it gets back a paginated vector PDF. Each page is drawn from that PDF and scaled down only when it does not fit. [WebKit source](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/_WKWebViewPrintFormatter.mm)
- Wrapping it in a `UIPrintPageRenderer` (`addPrintFormatter(_:startingAtPageAt: 0)`) is optional. Use a renderer only for headers and footers. Plain `printFormatter = webView.viewPrintFormatter()` is enough otherwise.
- `UIPrintInfo`: set `jobName` to the page title and `outputType = .general` for mixed text and images.
- Presentation: `present(animated:completionHandler:)` is the iPhone sheet. `present(from: UIBarButtonItem, ...)` and `present(from: CGRect, in: UIView, ...)` are the iPad popover forms. Set a delegate that returns `printInteractionControllerParentViewController` so UIKit knows where to present.

**What Chrome iOS does (verified, [print_coordinator_impl.mm](https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/browser/print/coordinator/print_coordinator_impl.mm)).**
- Builds a `UIPrintPageRenderer` with `[view viewPrintFormatter]`.
- Uses `printInfo.outputType = UIPrintInfoOutputGeneral` and `jobName = title`.
- Calls `presentAnimated:completionHandler:` and returns the parent VC from the delegate.
- Ignores a second request while the shared controller already has a delegate.
- On completion, clears `delegate`, `printPageRenderer`, `printingItem` and `printInfo`.

**What Firefox iOS does (verified, [BrowserCoordinator.swift](https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Client/Coordinators/Browser/BrowserCoordinator.swift)).**
- Sets `printInfo.jobName = tab.displayTitle`.
- For a tab that shows a PDF, sets `printingItem = url`.
- Otherwise sets `printFormatter = webView.viewPrintFormatter()`, then calls `present(animated:)`.
- The share sheet also adds `UIPrintInfo` and a `TabPrintPageRenderer` (a `UIPrintPageRenderer` subclass) as activity items. That renderer draws the title and date in the header, and the URL and page number in the footer ([ShareManager.swift](https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Client/Frontend/Share/ShareManager.swift), [TabPrintPageRenderer.swift](https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Client/Frontend/Browser/TabPrintPageRenderer.swift)).

**Known issues.**
- Lazy images and iframes never scrolled into view print empty ([WebKit 224547](https://bugs.webkit.org/show_bug.cgi?id=224547)). The reported fix is setting `loading="eager"` on lazy elements before printing. A `beforeprint` handler is too late because it runs asynchronously.
- Blank pages were real regressions in the past ([157924](https://bugs.webkit.org/show_bug.cgi?id=157924), [151386](https://bugs.webkit.org/show_bug.cgi?id=151386)). Both are fixed. Recent blank-page reports are mostly about macOS ([forum 803249](https://developer.apple.com/forums/thread/803249)).
- "Only the visible part prints" happens with screen snapshots, not with `viewPrintFormatter`, which lays out the whole document.
- `@media print` nested inside another rule did not apply after Safari 18.5 ([297232](https://bugs.webkit.org/show_bug.cgi?id=297232)). That is a page CSS bug, not an API bug.
- Width media queries are ignored when printing ([250685](https://bugs.webkit.org/show_bug.cgi?id=250685)).

**iOS 26/27.** I found no change to UIKit printing or to `viewPrintFormatter`. iOS 26 added SwiftUI `WebPage.exported(as: .pdf)`, which returns PDF `Data` ([docs](https://developer.apple.com/documentation/webkit/webpage/exported(as:))). The SwiftUI `WebView` has no direct print API ([forum 800440](https://developer.apple.com/forums/thread/800440)). It does not matter for a UIKit `WKWebView` shell. `viewPrintFormatter()` with `UIPrintInteractionController` is still the path Chrome and Firefox ship.

## 2. Save as PDF

**`createPDF(configuration:completionHandler:)` / async `pdf(configuration:)` (iOS 14+), verified in [WebKit `drawToPDF`](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/Cocoa/WebPageCocoa.mm) and [`drawMainFrameToPDF` / `pdfSnapshotAtSize`](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/WebPage.cpp).**
- Default rect is the frame view's full `contentsSize`. `WKPDFConfiguration.rect` overrides it. Chrome notes the rect is in document coordinates and unscaled, even though Apple's header says view coordinates. WebKit never completes the request for a rect under 1x1 ([Chrome wk_web_view_util.mm](https://chromium.googlesource.com/chromium/src/+/main/ios/web/util/wk_web_view_util.mm)).
- **Output is one tall page per 200 inches (14,400 pt).** It is not split into paper pages. A page taller than 14,400 pt becomes several 14,400-pt slices, cut at arbitrary points. The 200-inch limit is the PDF page-height limit.
- **Print CSS is not applied (verified).** The code paints the normal screen rendering through the snapshot path, with no PrintContext and no print media. It only adds `PaintBehavior::AnnotateLinks`, so links stay clickable. Output is vector.
- `allowTransparentBackground` (iOS 17+) turns off the base background color.
- Page size cannot be scaled, and DPI is fixed at 72 ([WebKit 214602](https://bugs.webkit.org/show_bug.cgi?id=214602)).

**Paginated alternative (`UIPrintPageRenderer` + `UIGraphicsPDFRenderer`).**
1. Create a renderer and add `webView.viewPrintFormatter()`.
2. Set `paperRect` and `printableRect` through KVC, because both are read-only (`renderer.setValue(NSValue(cgRect: r), forKey: "paperRect")`). WebKit's own test sets both to the page rect ([WebKit test](https://webkit.googlesource.com/WebKit/+/84774fe198803611f5618b9a9f2415bf7b147653/Tools/TestWebKitAPI/Tests/WebKitCocoa/WKWebViewPrintFormatter.mm)).
3. Call `renderer.prepare(forDrawingPages:)`, then `numberOfPages`.
4. In `UIGraphicsPDFRenderer(bounds: paper).pdfData`, call `beginPage()` and `renderer.drawPage(at: i, in: bounds)` for each page.

This gives A4 or Letter pages with `@media print` applied, the same as the print preview. [HTML2PDFRenderer](https://github.com/radianttap/HTML2PDFRenderer) packages this approach with A4 and Letter presets and margins.

**What other browsers ship.**

| Browser | Feature | API | Output |
|---|---|---|---|
| Firefox iOS | Menu "Save as PDF" | `webView.createPDF` (verified) | One tall page, screen CSS |
| Firefox / Chrome iOS | Full-page screenshot "PDF" tab | `UIScreenshotService` `generatePDFRepresentation`, which calls `createPDF` (verified: [Firefox ScreenshotService.swift](https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Client/Coordinators/Scene/ScreenshotService.swift), [Chrome screenshot_delegate.mm](https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/browser/screenshot/model/screenshot_delegate.mm)) | One tall page |
| Chrome iOS | Share, then Print; pinch the preview or use the print panel's share action to get a PDF | `viewPrintFormatter` | Paginated, print CSS |
| Safari iOS | Share > Options > PDF; full-page screenshot > Save PDF to Files; Print preview share | Not public | Options > PDF and Print give paper pages (reported). The screenshot gives one tall page (reported, [Obsidian forum](https://forum.obsidian.md/t/bug-long-unpaginated-pdfs-not-rendering/21405)) |
| Arc Search | Unverified | None found | Unverified |

Firefox's Save as PDF flow, verified in `presentSavePDFController`:
- If the tab already shows a PDF, it shares that file directly.
- Otherwise it calls `createPDF`, then `createOutputURL(withFileName: webView.title ?? "")`.
- It writes the data to that URL and opens its share-sheet coordinator with `.file(url:remoteURL:)`.
- On error it only logs, with a TODO (FXIOS-11542). Users see nothing.

Single tall pages render badly in some viewers. Preview's single-page view shrinks the page to a narrow strip, and Obsidian fails on long pages ([Apple discussions](https://discussions.apple.com/thread/8321489), [Obsidian](https://forum.obsidian.md/t/bug-long-unpaginated-pdfs-not-rendering/21405)).

## 3. Share flow

1. Write the data to `FileManager.default.temporaryDirectory/<UUID>/<Title>.pdf`. Pass the **file URL** to `UIActivityViewController`, not `Data`. A URL keeps the filename for Save to Files and AirDrop. Raw `Data` arrives with a generic name.
2. On iPad, set `popoverPresentationController.sourceItem` (iOS 16+) or `sourceView`/`sourceRect`.
3. Sanitize the filename:
   - Trim whitespace.
   - Replace `/`, `:` and `\` with `-`, and strip control characters and newlines.
   - Collapse runs of spaces.
   - Drop a leading `.`.
   - Cap at about 100 characters, cutting on a grapheme boundary.
   - Fall back to the URL host, then to "Page".
   - Add `.pdf` once. Do not add it when the title already ends in `.pdf` (Firefox desktop doubled it: [bug 1660162](https://bugzilla.mozilla.org/show_bug.cgi?id=1660162)).
4. Cleanup: delete the UUID folder in `completionWithItemsHandler`. AirDrop and Save to Files copy the file before the handler fires. As a backstop, clear stale export folders at launch. iOS also purges `tmp` on its own.
5. Optional: give `LPLinkMetadata` (title and favicon) through a `UIActivityItemSource` so the sheet header looks right.

## 4. Performance

- `createPDF` runs in the **WebContent process**, synchronously on that process's main thread (`drawToPDF`). The app's main thread is not blocked. Page JS and scrolling stall for the length of the paint. The data then crosses IPC as one buffer and lives in app memory as `Data`.
- Vector output keeps text pages small. Image-heavy pages embed every image and can reach tens of MB. Write to disk right away and drop the `Data`.
- The print-formatter path makes **blocking calls** from the caller's thread. `_wk_pageCountForPrintFormatter` and `_wk_requestDocumentForPrintFormatter` wait on a condition variable until the web process returns the paginated PDF ([source](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/_WKWebViewPrintFormatter.mm)). Inside the system print panel, UIKit handles this. A hand-rolled `UIGraphicsPDFRenderer` export on the main thread freezes the UI until pagination finishes. Show a progress HUD first, and measure on a long page such as a large Wikipedia article.
- Lazy content: before either export, run a small script that sets `loading="eager"` on `img` and `iframe` elements, then wait briefly. Otherwise images below the fold come out blank.

## Recommendation for Plain

- **Print:** `UIPrintInteractionController.shared` with `printFormatter = webView.viewPrintFormatter()` and `UIPrintInfo(outputType: .general, jobName: title)`. For a PDF tab, use `printingItem = url`. Present from the menu's source item on iPad and with `present(animated:)` on iPhone. Guard against re-entry and clear state on completion, as Chrome does.
- **No header/footer renderer at first.** Firefox's title, URL and page-number chrome is extra; add it later only if users ask.
- **Save as PDF: paginated.** Use `UIPrintPageRenderer` + `viewPrintFormatter` + `UIGraphicsPDFRenderer`, with the paper size chosen by locale: Letter for US/CA/MX, otherwise A4. Use 0.5 in margins. This gives clean pages with print CSS applied. Firefox's single tall page avoids pagination but cuts at 200 inches and reads badly in viewers.
- **Keep `createPDF` for one case:** the full-page screenshot via `UIScreenshotServiceDelegate.generatePDFRepresentation`. Chrome and Firefox both do this, and it is cheap to add.
- **Before export,** force lazy images with `loading="eager"`. Then measure. If pagination blocks the main thread for more than about 200 ms on long pages, show a spinner and keep the menu responsive. Never run it from a scroll or tap hot path.
- **For a PDF tab,** share the original file instead of re-rendering it (Firefox does the same).
- **Share flow:** write to `tmp/<UUID>/<SanitizedTitle>.pdf` and present `UIActivityViewController` with the file URL. Delete the folder in `completionWithItemsHandler`, and sweep stale folders at launch.
- **File naming:** use the sanitized page title, falling back to the host, then "Page". Cap at 100 characters, add `.pdf` once, and add no date or app suffix.
- **Surface failures** with a short error toast instead of only logging, as Firefox does.
