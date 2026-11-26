#if canImport(UIKit)
import Foundation
import Security
import Testing
import UIKit
import WebKit
@testable import WebEngine

/// Popups, downloads, auth, certificates and permissions (docs/plan.md, M4).
@Suite(.serialized) @MainActor
struct EdgeCaseTests {
    // MARK: Popups

    @Test func popupOpensAChildTabThatKeepsItsOpener() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        harness.host.childContainer = harness.makePane(size: CGSize(width: 390, height: 780))
        let opener = harness.pool.makeTab()
        harness.pool.attach(opener, to: harness.container)
        try await harness.load("/opener", in: opener)

        // evaluateJavaScript runs with a user gesture, like a tap.
        _ = try await harness.evaluate("window.open('/child'); 0", in: opener)
        try await waitUntil("child tab") { harness.host.opened.count == 1 }
        let child = harness.host.opened[0].child
        #expect(child.openerID == opener.id)
        try await harness.waitForLoad(of: harness.server.url("/child"), in: child)
        // The child reached its opener through window.opener (OAuth popups depend on it).
        try await waitUntil("opener got the message") { opener.title == "got hello" }

        _ = try await harness.evaluate("window.close(); 0", in: child)
        try await waitUntil("close request") { harness.host.closeRequests.first === child }
        harness.pool.close(child)
        #expect(harness.pool.existingWebView(for: child) == nil)
    }

    @Test func popupBurstIsThrottled() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let opener = harness.pool.makeTab()
        harness.pool.attach(opener, to: harness.container)
        try await harness.load("/opener", in: opener)
        _ = try await harness.evaluate("for (let i = 0; i < 5; i++) window.open('/child?' + i); 0", in: opener)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.host.opened.count == EngineChoices.popupLimit)
    }

    // MARK: Downloads

    @Test func attachmentBecomesADownload() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        _ = try await harness.evaluate("location.href = '/file.bin'; 0", in: tab)
        try await waitUntil("download end") { !harness.host.endedDownloads.isEmpty }
        let download = harness.host.endedDownloads[0]
        guard case .finished(let file) = download.state else {
            Issue.record("download state \(download.state)")
            return
        }
        #expect(file.lastPathComponent == "report.bin")
        #expect(try Data(contentsOf: file).count == 4096)
        #expect(download.tabID == tab.id)
        #expect(tab.url == harness.server.url("/a"))
        #expect(tab.loadError == nil)

        // Same name again gets a numbered file instead of failing.
        _ = try await harness.evaluate("location.href = '/file.bin'; 0", in: tab)
        try await waitUntil("second download") { harness.host.endedDownloads.count == 2 }
        guard case .finished(let second) = harness.host.endedDownloads[1].state else {
            Issue.record("second download failed")
            return
        }
        #expect(second.lastPathComponent == "report 2.bin")
    }

    @Test func typeWebKitCannotShowBecomesADownload() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        _ = try await harness.evaluate("location.href = '/raw'; 0", in: tab)
        try await waitUntil("download end") { !harness.host.endedDownloads.isEmpty }
        #expect(harness.host.endedDownloads[0].filename == "raw")
    }

    @Test func pdfShowsInline() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/doc.pdf", in: tab)
        #expect(harness.host.startedDownloads.isEmpty)
        #expect(tab.loadError == nil)
    }

    @Test func blobLinkWithDownloadAttributeIsSaved() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/blob", in: tab)
        _ = try await harness.evaluate("document.getElementById('save').click(); 0", in: tab)
        try await waitUntil("blob download") { !harness.host.endedDownloads.isEmpty }
        guard case .finished(let file) = harness.host.endedDownloads[0].state else {
            Issue.record("blob download: \(harness.host.endedDownloads[0].state)")
            return
        }
        #expect(file.lastPathComponent == "notes.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello blob")
    }

    @Test func blobFallbackReadsTheBlobFromThePage() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/blob", in: tab)
        let href = try #require(try await harness.evaluate("document.getElementById('save').href", in: tab) as? String)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        let frame = try #require(await mainFrame(of: webView))
        let item = Download(sourceURL: URL(string: href), tabID: tab.id, progress: Progress())
        item.filename = "fallback.txt"
        harness.pool.downloads.readBlob(URL(string: href)!, from: webView, frame: frame, into: item)
        try await waitUntil("fallback") { item.state != .inProgress }
        guard case .finished(let file) = item.state else {
            Issue.record("fallback: \(item.state)")
            return
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello blob")
    }

    /// The main frame's `WKFrameInfo`, captured from a script message.
    private func mainFrame(of webView: WKWebView) async -> WKFrameInfo? {
        let catcher = FrameCatcher()
        webView.configuration.userContentController.add(catcher, contentWorld: .page, name: "plainFrame")
        defer { webView.configuration.userContentController.removeScriptMessageHandler(forName: "plainFrame", contentWorld: .page) }
        _ = try? await webView.evaluateJavaScript("webkit.messageHandlers.plainFrame.postMessage(1); 0")
        try? await waitUntil("frame") { catcher.frame != nil }
        return catcher.frame
    }

    // MARK: HTTP auth

    @Test func httpAuthAsksTheShellAndUsesTheCredential() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        harness.host.credential = URLCredential(user: "user", password: "pass", persistence: .forSession)
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/secret", in: tab)
        try await waitUntil("welcome") { tab.title == "Welcome" }
        let request = try #require(harness.host.authRequests.first)
        #expect(request.realm == "Plain Test")
        #expect(request.isPasswordSentInClear)
        #expect(request.previousFailureCount == 0)
    }

    @Test func cancelledAuthShowsTheServersPage() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/secret", in: tab)
        try await waitUntil("denied page") { tab.title == "Denied" }
        #expect(harness.host.authRequests.count == 1)
    }

    // MARK: Certificates

    @Test func certificateExceptionTrustsOnlyTheCertificateSeen() throws {
        let exceptions = ServerTrustExceptions()
        let first = try Self.trust(Self.certificate1)
        let second = try Self.trust(Self.certificate2)
        #expect(!exceptions.matches(first, forHost: "a.test"))
        exceptions.allow(first, forHost: "A.test")
        #expect(exceptions.matches(first, forHost: "a.test"))
        #expect(!exceptions.matches(second, forHost: "a.test"))
        #expect(!exceptions.matches(first, forHost: "b.test"))
        #expect(exceptions.contains(host: "a.test"))
    }

    @Test func certificateErrorAsksTheShellThenReloads() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        harness.host.proceedPastCertificateError = true
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        let url = harness.server.url("/a")
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSURLErrorFailingURLPeerTrustErrorKey: try Self.trust(Self.certificate1),
        ])
        #expect(NavigationRules.isCertificateError(error))
        harness.pool.handleCertificateError(error, in: tab)
        try await waitUntil("proceed and reload") { tab.title == "A" }
        #expect(harness.host.certificateErrors.first?.code == .serverCertificateUntrusted)
        #expect(harness.pool.trustExceptions.contains(host: "127.0.0.1"))
    }

    static let certificate1 = "MIIC4jCCAcqgAwIBAgIUHzpHVM25klmE8hpp6sFKUXiRq2AwDQYJKoZIhvcNAQELBQAwETEPMA0GA1UEAwwGYS50ZXN0MB4XDTI2MTEyNjEwNDM0N1oXDTM2MTEyMzEwNDM0N1owETEPMA0GA1UEAwwGYS50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmLKnv1lAmOjz4U/QXhGuqWuKImXCa2HBXC0CXo4+/F0XWum0FY4yVWmGUMz50uKWxApHjWlbaBH07ZjEjDrnaz0SMKzYkZWO36kC7EmkxZ3IX/8AgCwcppnBnMvLmZgXRDNWH/ScoPS95o4+bo3uT00xX/0txmdtGhKPh2esqsHidpN+USH0LeMXrb7wRE8pP3h8b8YtM+4WpccrTlknmXpppG8TClwNo+e//GOQQElfStNQFXRXSUjg0AHK1lvvLRoz2S2y/rd74R/rtpDQB7xrC8OOZEkgqI6l1pEY4KN3IDxM/B0aFp7Ir3ODJa8A41TulsweDMjBYRHuj0pxgwIDAQABozIwMDAdBgNVHQ4EFgQU5mBV/w0PMqAeV5wGgQV7dBXh8V8wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAX7VnSHmL99X021gsxIdL7QJpkhTUgLRWaZyRpnQGJkeB+7DXtKdv6WR/UZjuWoc2hLIREumbZt655sc4FiaQEJ5nIEho7H4eTRuhzXAfyb4M9YnVN6+fDJ4C4aHIbbMoztawOUVzwFvfIzm0P+U68PWgnkS0+TPDP2QEegI2N0sOWUtJjYAdDQBdW66BTFE6Ywg6PIuBqgA/X9faRVMIE4mQq0nI87CLPzfZqB4+Y+f8tnqY2vn8B78SeskwqCQMU14vDNWMVnY6VO374u31vJBx1YNYK5kGek2a81l6KIydKgGuzjxqty2VY2ww1aZz8JvjT+7YLooCijZR6Ayfhg=="
    static let certificate2 = "MIIC4jCCAcqgAwIBAgIULJ+ViIsKFRLDzxuph4BI04IYCZowDQYJKoZIhvcNAQELBQAwETEPMA0GA1UEAwwGYS50ZXN0MB4XDTI2MTEyNjEwNDM0N1oXDTM2MTEyMzEwNDM0N1owETEPMA0GA1UEAwwGYS50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArIHvCjYWpSgmY6YKNqAQvNQpV7KaBXys3bjFMG4gRiictPwGamXY7zhlF8HuI57RxarLu42xZ5uEIYpChS3d+cchipJSlZxITkuX2cUZw7grUxtLDGPUAhZL9kgr+Wm3RADY4thZg/YSdwk8wP5Z1E77AGyQ27ygNv4LD+Ge4tiDOkf9CU7EH9r2cniO7gBq5Mg1+O7fIDt9IfkP4d8tN+IQaPI96FzVVe52BueLuPQ9DpnchloIX7xqyCRJ/KMesz1Xqtt51HNHu7klFV+HyvYjBiKjwHlh0LsdB2l0OtKKT5pEwwig2BvCU9lmCGnJdpL7fZgLelWzNQlshTePGwIDAQABozIwMDAdBgNVHQ4EFgQUJ01rDASolK3XzNMRTWJC4ArMNiYwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAIpDaKgKvxJ/o/We24LnZB+4E46yX07b2D0VLHVyhpcKA879EBnZvdcGqPLJtXIjcMImnioucwVml/DxlOZRKBQKngwoOcsub1t+IZzrAdan5oR/KPXMWtIS9JUWukq3gQR3eipW4sL3IE5UOX/wTKyPuEkYh+UB1LD31veaJGChQHc/LM1wPnph6bYAmebLkcWUym5B/vNx14CoJv+Qdzv9vnKcMlw/yaJdlLxJWQIkUuj+rj1Dq/JasNU6h+Lr7TxrilNFix6y0QdfFKShYLF5gZJHAO/KIoasjJ8j6qJ3w0Up2WueH8TOkBOdkKHkijt3FfF1yMosmy9ya87Ap+g=="

    static func trust(_ base64: String) throws -> SecTrust {
        let data = try #require(Data(base64Encoded: base64))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "a.test" as CFString), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    // MARK: Permissions

    // The WebKit permission callbacks (camera, microphone, geolocation, motion) are not driven from
    // a page here: in a hostless test process WebKit never reaches the delegate without the app's
    // own camera or location authorization. The pool logic behind them is tested directly.

    @Test func permissionIsAskedOncePerSiteThenRemembered() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        let site = "https://maps.example"
        #expect(await harness.pool.decide([.camera, .microphone], site: site, for: tab))
        #expect(await harness.pool.decide([.camera], site: site, for: tab))
        #expect(harness.host.permissionAsks.count == 1)
        #expect(harness.host.permissionAsks[0].permissions == [.camera, .microphone])

        harness.host.permissionAnswer = false
        #expect(await harness.pool.decide([.location], site: site, for: tab) == false)
        #expect(await harness.pool.decide([.location], site: site, for: tab) == false)
        #expect(harness.host.permissionAsks.count == 2)

        // A hidden tab never prompts and nothing is remembered for it.
        let hidden = harness.pool.makeTab()
        #expect(await harness.pool.decide([.motion], site: site, for: hidden) == false)
        #expect(harness.host.permissionAsks.count == 2)
        harness.host.permissionAnswer = true
        #expect(await harness.pool.decide([.motion], site: site, for: tab))
        #expect(harness.host.permissionAsks.count == 3)
    }
}

private final class FrameCatcher: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
    }
}
#endif
