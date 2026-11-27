#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import WebKit
@testable import WebEngine

/// Sign-in in web pages (docs/research/sign-in.md): login fields reach iOS AutoFill as the site
/// wrote them, and without the web-browser entitlement pages are steered to password sign-in.
@Suite(.serialized) @MainActor
struct SignInTests {
    nonisolated static let login = Pages.page(title: "Login", body: """
        <form id=login method=post action='/b'>
          <input id=user name=username type=email autocomplete="username">
          <input id=pass name=password type=password autocomplete="current-password">
          <input id=new name=new type=password autocomplete="new-password">
          <input id=code name=code inputmode=numeric autocomplete="one-time-code">
          <button>Sign In</button>
        </form>
        """)

    @Sendable nonisolated static func route(_ request: TestServer.Request) -> TestServer.Response {
        switch request.path {
        case "/login": return .html(login)
        case "/framed": return .html(Pages.page(title: "Framed", body: "<iframe src='/login'></iframe>"))
        default: return Pages.route(request)
        }
    }

    /// A passkey sign-in attempt, as a site's button runs it. Returns the error name.
    static let passkeyRequest = """
        try {
          await navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32), timeout: 1000 } });
          return 'ok';
        } catch (e) { return e.name; }
        """

    private func page(_ script: String, in harness: Harness, tab: Tab) async throws -> Any? {
        let webView = try #require(harness.pool.existingWebView(for: tab))
        return try await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    private func openLogin(_ harness: Harness, path: String = "/login") async throws -> Tab {
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load(path, in: tab)
        return tab
    }

    // MARK: Passwords

    @Test func loginFieldsKeepTheAutocompleteHintsAutoFillReads() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let tab = try await openLogin(harness)
        let fields = try await page("""
            return [...document.querySelectorAll('input')].map(i => i.type + ' ' + i.autocomplete).join('|');
            """, in: harness, tab: tab) as? String
        #expect(fields == "email username|password current-password|password new-password|text one-time-code")
        // Nothing of Plain's stops the page from focusing a field (AutoFill shows on focus).
        let focused = try await page("""
            document.getElementById('pass').focus(); return document.activeElement.id;
            """, in: harness, tab: tab) as? String
        #expect(focused == "pass")
    }

    // MARK: Passkeys without the entitlement

    @Test func pagesAreToldThereIsNoPasskeyAuthenticator() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let tab = try await openLogin(harness)
        let answers = try await page("""
            const caps = await PublicKeyCredential.getClientCapabilities();
            return JSON.stringify({
              defined: typeof PublicKeyCredential,
              uvpaa: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(),
              conditional: await PublicKeyCredential.isConditionalMediationAvailable(),
              platform: caps.passkeyPlatformAuthenticator,
              uv: caps.userVerifyingPlatformAuthenticator,
              hybrid: caps.hybridTransport,
              conditionalGet: caps.conditionalGet,
              conditionalCreate: caps.conditionalCreate,
              native: Function.prototype.toString.call(navigator.credentials.get).includes('[native code]')
                && Function.prototype.toString.call(PublicKeyCredential.getClientCapabilities).includes('[native code]'),
            });
            """, in: harness, tab: tab) as? String
        let json = try #require(answers.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(json["defined"] as? String == "function")
        for key in ["uvpaa", "conditional", "platform", "uv", "hybrid", "conditionalGet", "conditionalCreate"] {
            #expect(json[key] as? Bool == false, "\(key)")
        }
        #expect(json["native"] as? Bool == true)
    }

    @Test func aFailedPasskeyRequestTellsTheShellOncePerSite() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let tab = try await openLogin(harness)
        // Refused at once, with the error WebKit would give.
        #expect(try await page(Self.passkeyRequest, in: harness, tab: tab) as? String == "NotAllowedError")
        try await waitUntil("passkey notice") { harness.host.passkeyNotices == ["127.0.0.1"] }
        // A second try on a new page of the same site says nothing more.
        try await harness.load("/login", in: tab)
        #expect(try await page(Self.passkeyRequest, in: harness, tab: tab) as? String == "NotAllowedError")
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.host.passkeyNotices == ["127.0.0.1"])
    }

    @Test func aPasskeyRequestInAFrameNamesThePageSite() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let tab = try await openLogin(harness, path: "/framed")
        try await waitUntil("frame loaded") { harness.server.requests.contains { $0.path == "/login" } }
        try await Task.sleep(for: .milliseconds(200))
        let result = try await page("""
            const frame = frames[0];
            try {
              await frame.navigator.credentials.create({ publicKey: {
                challenge: new Uint8Array(32), rp: { name: 'Test' },
                user: { id: new Uint8Array(8), name: 'a', displayName: 'A' },
                pubKeyCredParams: [{ type: 'public-key', alg: -7 }], timeout: 1000 } });
              return 'ok';
            } catch (e) { return e.name; }
            """, in: harness, tab: tab) as? String
        #expect(result == "NotAllowedError")
        try await waitUntil("passkey notice") { harness.host.passkeyNotices == ["127.0.0.1"] }
    }

    @Test func silentPasskeyRequestsNeverTellTheShell() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let tab = try await openLogin(harness)
        _ = try await page("""
            const abort = new AbortController();
            const request = navigator.credentials.get({ mediation: 'conditional', signal: abort.signal,
              publicKey: { challenge: new Uint8Array(32) } }).catch(e => e.name);
            setTimeout(() => abort.abort(), 300);
            return await request;
            """, in: harness, tab: tab)
        // Password-less sign-in failing for a reason other than passkeys says nothing either.
        _ = try await page("""
            try { await navigator.credentials.get({ password: true }); } catch (e) {}
            return 0;
            """, in: harness, tab: tab)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.host.passkeyNotices.isEmpty)
    }

    @Test func privateTabsForgetTheirNoticesWithThePrivateSession() async throws {
        let harness = try await Harness(route: Self.route)
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab(isPrivate: true)
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/login", in: tab)
        _ = try await page(Self.passkeyRequest, in: harness, tab: tab)
        try await waitUntil("passkey notice") { harness.host.passkeyNotices.count == 1 }
        harness.pool.close(tab)
        harness.pool.endPrivateSession()

        let again = harness.pool.makeTab(isPrivate: true)
        harness.pool.attach(again, to: harness.container)
        try await harness.load("/login", in: again)
        _ = try await page(Self.passkeyRequest, in: harness, tab: again)
        try await waitUntil("second notice") { harness.host.passkeyNotices.count == 2 }
    }

    // MARK: With the entitlement

    @Test func withPasskeysEnabledPagesSeeWebKitAsItIs() async throws {
        let harness = try await Harness(passkeysEnabled: true, route: Self.route)
        defer { harness.cleanUp() }
        let tab = try await openLogin(harness)
        let untouched = try await page("""
            // WebKit's `get` and `create` live on the prototype; the fallback puts its own on the
            // instance.
            return !Object.prototype.hasOwnProperty.call(navigator.credentials, 'get')
              && !Object.prototype.hasOwnProperty.call(navigator.credentials, 'create');
            """, in: harness, tab: tab) as? Bool
        #expect(untouched == true)
        _ = try await page(Self.passkeyRequest, in: harness, tab: tab)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.host.passkeyNotices.isEmpty)
    }
}
#endif
