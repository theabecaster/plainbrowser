#if canImport(UIKit)
import Foundation
import PerfSignposts
import UIKit
import WebKit

/// The navigation and UI delegate of one tab's web view. It routes each WebKit callback to the
/// small piece that decides it: `NavigationRules` (pure policy), the pool (tiers, popups, crash
/// recovery, permissions), `ServerTrustExceptions`, `DownloadCoordinator` and the shell's
/// presenters. Split this way after DuckDuckGo's navigation handlers (an idea, no code taken;
/// see docs/decisions.md).
final class TabWebViewHandler: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var tab: Tab?
    private weak var pool: WebViewPool?
    private let signposter = NavigationSignposter()

    init(tab: Tab, pool: WebViewPool) {
        self.tab = tab
        self.pool = pool
    }

    // MARK: - Navigation policy

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let tab, let pool, let url = action.request.url else {
            decisionHandler(.allow, preferences)
            return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        // No target frame: a new window. `createWebViewWith` makes the child tab, whose own
        // handler decides its navigation; this tab's mode and rules must not change.
        guard let targetFrame = action.targetFrame else {
            if NavigationRules.schemeKind(of: url) == .external {
                // `target=_blank` to another app: WebKit only gets here from a user gesture.
                decisionHandler(.cancel, preferences)
                pool.openExternally(url, from: tab)
            } else {
                decisionHandler(.allow, preferences)
            }
            return
        }
        let isMainFrame = targetFrame.isMainFrame
        switch NavigationRules.schemeKind(of: url) {
        case .external:
            decisionHandler(.cancel, preferences)
            // Ask only for the page itself or a tap; iframes can't pop app prompts.
            if isMainFrame || action.navigationType == .linkActivated {
                pool.openExternally(url, from: tab)
            }
            return
        case .inPage:
            decisionHandler(.allow, preferences)
            return
        case .web:
            break
        }
        guard isMainFrame else {
            decisionHandler(.allow, preferences)
            return
        }

        // Desktop or mobile, decided now and kept for this page (never switched on resize).
        pool.slot(for: tab)?.pendingNavigationIsFormSubmission =
            action.request.httpMethod == "POST" || action.navigationType == .formResubmitted
        let mode = pool.contentMode(for: url, in: tab)
        preferences.preferredContentMode = mode == .desktop ? .desktop : .mobile
        let agent = mode == .desktop ? EngineChoices.desktopUserAgent : nil
        if webView.customUserAgent != agent { webView.customUserAgent = agent }
        tab.set(\.contentMode, mode)
        if let slot = pool.slot(for: tab) {
            pool.applyContentRules(slot, mainFrameURL: url)
        }

        // `.allow` also lets WebKit hand a tapped cross-site link to an app that claims it.
        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let decision = NavigationRules.responseDecision(
            isMainFrame: response.isForMainFrame, canShowMIMEType: response.canShowMIMEType,
            contentDisposition: disposition
        )
        if response.isForMainFrame, decision == .allow, let tab, let slot = pool?.slot(for: tab) {
            slot.pendingNavigationIsPDF = NavigationRules.isPDF(mimeType: response.response.mimeType)
        }
        switch decision {
        case .allow: decisionHandler(.allow)
        case .download: decisionHandler(.download)
        case .cancel: decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        pool?.downloads.adopt(download, from: tab)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        pool?.downloads.adopt(download, from: tab)
    }

    // MARK: - Navigation progress

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        signposter.webView(webView, didStartProvisionalNavigation: navigation)
        tab?.set(\.loadError, nil)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        signposter.webView(webView, didCommit: navigation)
        if let tab, let pool, let slot = pool.slot(for: tab) {
            tab.isFormResult = slot.pendingNavigationIsFormSubmission
            tab.set(\.isAwaitingResubmit, false)
            tab.set(\.isPDF, slot.pendingNavigationIsPDF)
            slot.pendingNavigationIsPDF = false
            // The old document's frames, and their media, are gone; the new one reports its own
            // dark pages state.
            slot.clearMediaReports()
            slot.receiveDarkPagesState(.inactive)
            pool.applyRememberedZoom(to: webView, in: tab)
        }
        updateSecurity(of: webView)
        endRestore()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        signposter.webView(webView, didFinish: navigation)
        updateSecurity(of: webView)
        endRestore()
        if let tab, let pool, let slot = pool.slot(for: tab) { pool.scheduleSave(slot) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        signposter.webView(webView, didFail: navigation, withError: error)
        endRestore()
        report(error as NSError)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        signposter.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        endRestore()
        let error = error as NSError
        if NavigationRules.isCertificateError(error), let tab, let pool {
            tab.set(\.loadError, LoadError(error))
            pool.handleCertificateError(error, in: tab)
            return
        }
        if NavigationRules.isSilentError(error) {
            // Stopped (or turned into a download) before it committed: the tab is back on what it
            // showed, which for a fresh tab is nothing (docs/state-rules.md §7, Stop). The URL
            // observer ignores nil, so the address is set here.
            tab?.set(\.url, webView.url)
        }
        report(error)
    }

    private func report(_ error: NSError) {
        guard !NavigationRules.isSilentError(error) else { return }
        tab?.set(\.loadError, LoadError(error))
    }

    private func endRestore() {
        guard let tab, let slot = pool?.slot(for: tab) else { return }
        slot.endRestoreInterval()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab else { return }
        signposter.webViewWebContentProcessDidTerminate(webView)
        pool?.webContentProcessDidTerminate(tab)
    }

    func updateSecurity(of webView: WKWebView) {
        guard let tab, let pool else { return }
        let state: SecurityState
        switch webView.url?.scheme?.lowercased() {
        case "https":
            if let host = webView.url?.host(), pool.trustExceptions.contains(host: host) {
                state = .certificateBypassed
            } else {
                state = webView.hasOnlySecureContent ? .secure : .notSecure
            }
        case "http":
            state = .notSecure
        default:
            state = .none
        }
        tab.set(\.security, state)
    }

    // MARK: - Authentication

    func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            if let trust = space.serverTrust, pool?.trustExceptions.matches(trust, forHost: space.host) == true {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            guard let tab, let host = pool?.host else {
                completionHandler(.rejectProtectionSpace, nil)
                return
            }
            let request = AuthenticationRequest(
                host: space.host, port: space.port, realm: space.realm,
                isPasswordSentInClear: space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
                    && !space.receivesCredentialSecurely,
                previousFailureCount: challenge.previousFailureCount,
                proposedUser: challenge.proposedCredential?.user
            )
            Task {
                if let credential = await Signposts.prompt("auth", { await host.tab(tab, credentialFor: request) }) {
                    completionHandler(.useCredential, credential)
                } else {
                    // Continue without credentials, so the server's 401 page shows.
                    completionHandler(.rejectProtectionSpace, nil)
                }
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Popups

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let tab, let pool else { return nil }
        return pool.openChild(configuration: configuration, from: tab)
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab else { return }
        pool?.childRequestsClose(tab)
    }

    // MARK: - Link context menu

    func webView(
        _ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo
    ) async -> UIContextMenuConfiguration? {
        guard let tab, let pool else { return nil }
        return await pool.contextMenuConfiguration(for: elementInfo.linkURL, in: tab)
    }

    func webView(
        _ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
        willCommitWithAnimator animator: any UIContextMenuInteractionCommitAnimating
    ) {
        guard let tab, let pool else { return }
        pool.commitPreview(of: elementInfo.linkURL, in: tab, animator: animator)
    }

    // MARK: - JavaScript dialogs

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        guard let tab, let pool, pool.mayShowDialog(for: tab), let host = pool.host else { return }
        let site = Self.site(of: frame.securityOrigin)
        await Signposts.prompt("alert") { await host.tab(tab, alert: message, from: site) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        guard let tab, let pool, pool.mayShowDialog(for: tab), let host = pool.host else { return false }
        let site = Self.site(of: frame.securityOrigin)
        return await Signposts.prompt("confirm") { await host.tab(tab, confirm: message, from: site) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        guard let tab, let pool, pool.mayShowDialog(for: tab), let host = pool.host else { return nil }
        let site = Self.site(of: frame.securityOrigin)
        return await Signposts.prompt("prompt") {
            await host.tab(tab, prompt: prompt, defaultText: defaultText, from: site)
        }
    }

    // MARK: - Permissions

    func webView(
        _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        let permissions: [SitePermission] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: [.camera, .microphone]
        }
        return await decide(permissions, origin: origin)
    }

    func webView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        Task { decisionHandler(await decide([.location], origin: origin)) }
    }

    func webView(
        _ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        Task { decisionHandler(await decide([.motion], origin: origin)) }
    }

    private func decide(_ permissions: [SitePermission], origin: WKSecurityOrigin) async -> WKPermissionDecision {
        guard let tab, let pool else { return .deny }
        return await pool.decide(permissions, site: Self.site(of: origin), for: tab) ? .grant : .deny
    }

    /// `https://example.com`, with the port only when it is not the scheme's default.
    static func site(of origin: WKSecurityOrigin) -> String {
        origin.port == 0 ? "\(origin.protocol)://\(origin.host)" : "\(origin.protocol)://\(origin.host):\(origin.port)"
    }
}

extension LoadError {
    init(_ error: NSError) {
        self.init(
            url: error.userInfo[NSURLErrorFailingURLErrorKey] as? URL, code: error.code, domain: error.domain,
            message: error.localizedDescription
        )
    }
}
#endif
