import CoreGraphics
import Foundation
import Testing
@testable import WebEngine

/// Pure policy; runs on macOS with `swift test` too.
@Suite struct NavigationRulesTests {
    @Test func schemes() {
        #expect(NavigationRules.schemeKind(of: URL(string: "https://a.example")!) == .web)
        #expect(NavigationRules.schemeKind(of: URL(string: "HTTP://a.example")!) == .web)
        #expect(NavigationRules.schemeKind(of: URL(string: "about:blank")!) == .inPage)
        #expect(NavigationRules.schemeKind(of: URL(string: "blob:https://a.example/1")!) == .inPage)
        #expect(NavigationRules.schemeKind(of: URL(string: "mailto:x@a.example")!) == .external)
        #expect(NavigationRules.schemeKind(of: URL(string: "itms-apps://app")!) == .external)
    }

    @Test func contentModeFromPaneSize() {
        // Duo inner screen, both orientations: desktop.
        #expect(NavigationRules.contentMode(forPaneSize: CGSize(width: 951, height: 669)) == .desktop)
        #expect(NavigationRules.contentMode(forPaneSize: CGSize(width: 669, height: 951)) == .desktop)
        // Duo outer screen, a split half, a phone in landscape: mobile.
        #expect(NavigationRules.contentMode(forPaneSize: CGSize(width: 382, height: 580)) == .mobile)
        #expect(NavigationRules.contentMode(forPaneSize: CGSize(width: 475, height: 669)) == .mobile)
        #expect(NavigationRules.contentMode(forPaneSize: CGSize(width: 956, height: 440)) == .mobile)
    }

    @Test func downloadDecisions() {
        #expect(NavigationRules.isAttachment(contentDisposition: "attachment; filename=a.zip"))
        #expect(NavigationRules.isAttachment(contentDisposition: " Attachment"))
        #expect(!NavigationRules.isAttachment(contentDisposition: "inline; filename=a.pdf"))
        #expect(!NavigationRules.isAttachment(contentDisposition: nil))
        #expect(NavigationRules.responseDecision(isMainFrame: true, canShowMIMEType: true, contentDisposition: nil) == .allow)
        #expect(NavigationRules.responseDecision(isMainFrame: true, canShowMIMEType: false, contentDisposition: nil) == .download)
        #expect(NavigationRules.responseDecision(isMainFrame: false, canShowMIMEType: false, contentDisposition: nil) == .cancel)
        #expect(NavigationRules.responseDecision(
            isMainFrame: false, canShowMIMEType: true, contentDisposition: "attachment"
        ) == .download)
    }

    @Test func sitesAndUniversalLinks() {
        #expect(NavigationRules.siteKey(for: URL(string: "https://www.Example.com/a")!) == "example.com")
        #expect(NavigationRules.isCrossSite(from: URL(string: "https://a.example/1")!, to: URL(string: "https://b.example")!))
        #expect(!NavigationRules.isCrossSite(from: URL(string: "https://www.a.example")!, to: URL(string: "https://a.example/2")!))
        #expect(NavigationRules.isCrossSite(from: nil, to: URL(string: "https://a.example")!))
    }

    @Test func filenames() {
        #expect(NavigationRules.sanitizedFilename("../../etc/passwd") == "_.._etc_passwd")
        #expect(NavigationRules.sanitizedFilename("  .hidden ") == "hidden")
        #expect(NavigationRules.sanitizedFilename("") == "download")
        #expect(NavigationRules.sanitizedFilename("report.pdf") == "report.pdf")
    }

    @Test func errorsThatShowNoPage() {
        #expect(NavigationRules.isSilentError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(NavigationRules.isSilentError(NSError(domain: "WebKitErrorDomain", code: 102)))
        #expect(!NavigationRules.isSilentError(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        // A certificate code without the server's trust is a plain error.
        #expect(!NavigationRules.isCertificateError(NSError(
            domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted
        )))
    }

    @Test func rateLimiterSlidesItsWindow() {
        var limiter = RateLimiter(limit: 2, window: .seconds(2))
        let key = UUID()
        let start = ContinuousClock.now
        let answers = [
            limiter.allow(key, at: start),
            limiter.allow(key, at: start + .milliseconds(100)),
            limiter.allow(key, at: start + .milliseconds(200)),
            limiter.allow(UUID(), at: start + .milliseconds(200)),
            limiter.allow(key, at: start + .milliseconds(2_050)),
        ]
        #expect(answers == [true, true, false, true, true])
    }
}
