#if canImport(UIKit)
import DesignSystem
import Foundation
import QuickLook
import UIKit
import WebEngine

/// The shell's answers to the engine (`EngineHost`): child tabs, JavaScript dialogs, sign-in,
/// certificate warnings, form resubmission, other apps, permissions, downloads and crashes.
///
/// Every question is a system alert with one sentence (docs/ui-reference.md, "Wording"), shown
/// one at a time over whatever is on screen. Answers to permission prompts are remembered per
/// site by the engine (`SitePermissionStore`), so each site asks once.
extension BrowserViewController: EngineHost {
    // MARK: TabPresenter

    public func pool(_ pool: WebViewPool, didOpen child: Tab, from opener: Tab) {
        session.tabs.add(child, after: opener)
        // One tab on screen for now: the popup takes it; Back (or the page's window.close())
        // returns to the opener.
        show(child)
    }

    public func pool(_ pool: WebViewPool, tabRequestsClose tab: Tab) {
        closeTab(tab)
    }

    public func pool(_ pool: WebViewPool, tabKeepsCrashing tab: Tab) {
        engineUI.crashedTabs.insert(tab.id)
        if tab === self.currentTab { updatePageState() }
    }

    public func pool(_ pool: WebViewPool, shouldResubmitFormIn tab: Tab) async -> Bool {
        await ask(
            "Send the form again?",
            message: "This page came from a form, and loading it sends what you entered again.",
            cancel: "Don't Send", confirm: "Send"
        )
    }

    // MARK: JavaScriptDialogPresenter

    public func tab(_ tab: Tab, alert message: String, from site: String) async {
        await presentPrompt { finish in
            let alert = UIAlertController(title: Self.displaySite(site), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in finish(()) })
            return (alert, ())
        }
    }

    public func tab(_ tab: Tab, confirm message: String, from site: String) async -> Bool {
        await ask(Self.displaySite(site), message: message, cancel: "Cancel", confirm: "OK")
    }

    public func tab(_ tab: Tab, prompt message: String, defaultText: String?, from site: String) async -> String? {
        await presentPrompt { finish in
            let alert = UIAlertController(title: Self.displaySite(site), message: message, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in finish(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                finish(alert?.textFields?.first?.text ?? "")
            })
            return (alert, nil)
        }
    }

    // MARK: AuthenticationPresenter

    public func tab(_ tab: Tab, credentialFor request: AuthenticationRequest) async -> URLCredential? {
        let message: String
        if request.previousFailureCount > 0 {
            message = "That user name or password didn't work."
        } else if request.isPasswordSentInClear {
            message = "\(request.host) asks you to sign in, and your password would be sent unencrypted."
        } else {
            message = "\(request.host) asks you to sign in."
        }
        return await presentPrompt { finish in
            let alert = UIAlertController(title: "Sign In", message: message, preferredStyle: .alert)
            alert.addTextField {
                $0.placeholder = "User Name"
                $0.text = request.proposedUser
                $0.textContentType = .username
                $0.autocapitalizationType = .none
                $0.autocorrectionType = .no
            }
            alert.addTextField {
                $0.placeholder = "Password"
                $0.isSecureTextEntry = true
                $0.textContentType = .password
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in finish(nil) })
            let signIn = UIAlertAction(title: "Sign In", style: .default) { [weak alert] _ in
                let user = alert?.textFields?.first?.text ?? ""
                let password = alert?.textFields?.last?.text ?? ""
                finish(URLCredential(user: user, password: password, persistence: .forSession))
            }
            alert.addAction(signIn)
            alert.preferredAction = signIn
            return (alert, nil)
        }
    }

    public func tab(_ tab: Tab, shouldProceedPast error: CertificateError) async -> Bool {
        await presentPrompt { finish in
            let alert = UIAlertController(
                title: "This connection isn't private",
                message: "\(error.host) can't prove who it is, so someone could read or change what you send.",
                preferredStyle: .alert
            )
            let back = UIAlertAction(title: "Go Back", style: .cancel) { _ in finish(false) }
            alert.addAction(back)
            alert.addAction(UIAlertAction(title: "Visit Anyway", style: .destructive) { _ in finish(true) })
            alert.preferredAction = back
            return (alert, false)
        }
    }

    // MARK: ExternalAppPresenter

    public func tab(_ tab: Tab, openExternally url: URL) async -> Bool {
        let open = await ask("Open this link in another app?", message: nil, cancel: "Cancel", confirm: "Open")
        guard open else { return false }
        return await UIApplication.shared.open(url)
    }

    // MARK: PermissionPresenter

    public func tab(_ tab: Tab, allow permissions: [SitePermission], forSite site: String) async -> Bool {
        await ask(
            "Allow \(Self.displaySite(site)) to use \(Self.describe(permissions))?",
            message: nil, cancel: "Don't Allow", confirm: "Allow"
        )
    }

    // MARK: DownloadPresenter

    public func downloadDidStart(_ download: Download) {
        Haptic.tap.play()
    }

    public func downloadDidEnd(_ download: Download) {
        switch download.state {
        case .finished(let file):
            Task {
                await presentPrompt { finish in
                    let alert = UIAlertController(
                        title: "Downloaded", message: "\(download.filename) is in Files, in Plain's Downloads folder.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in finish(()) })
                    alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
                        finish(())
                        self?.preview(file)
                    })
                    return (alert, ())
                }
            }
        case .failed:
            Task {
                await presentPrompt { finish in
                    let alert = UIAlertController(
                        title: nil, message: "\(download.filename) didn't download.", preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in finish(()) })
                    return (alert, ())
                }
            }
        case .inProgress, .cancelled:
            break
        }
    }

    private func preview(_ file: URL) {
        engineUI.preview.file = file
        let controller = QLPreviewController()
        controller.dataSource = engineUI.preview
        topPresenter.present(controller, animated: true)
    }

    // MARK: Presenting

    /// A yes-or-no question: `confirm` answers true, `cancel` false.
    private func ask(_ title: String, message: String?, cancel: String, confirm: String) async -> Bool {
        await presentPrompt { finish in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: cancel, style: .cancel) { _ in finish(false) })
            let yes = UIAlertAction(title: confirm, style: .default) { _ in finish(true) }
            alert.addAction(yes)
            alert.preferredAction = yes
            return (alert, false)
        }
    }

    /// Shows the alert `make` builds once the questions before it are answered, and returns the
    /// answer its actions pass to `finish`. When it can't be shown (the screen is busy leaving),
    /// the fallback `make` returned is the answer, so the engine never waits forever.
    private func presentPrompt<Answer: Sendable>(
        _ make: (_ finish: @escaping (Answer) -> Void) -> (UIAlertController, fallback: Answer)
    ) async -> Answer {
        await engineUI.prompts.acquire()
        defer { engineUI.prompts.release() }
        return await withCheckedContinuation { continuation in
            let once = Once()
            let (alert, fallback) = make { answer in
                guard once.claim() else { return }
                continuation.resume(returning: answer)
            }
            alert.view.tintColor = Palette.accent
            let presenter = topPresenter
            presenter.present(alert, animated: true)
            if alert.presentingViewController == nil, once.claim() {
                continuation.resume(returning: fallback)
            }
        }
    }

    /// The controller at the top of the presentation chain, so a question shows over a sheet.
    private var topPresenter: UIViewController {
        var top: UIViewController = navigationController ?? self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// `https://example.com` as people read it: `example.com`.
    static func displaySite(_ site: String) -> String {
        guard let url = URL(string: site), let host = url.host(), !host.isEmpty else { return site }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return url.port.map { "\(name):\($0)" } ?? name
    }

    /// "your camera", "your camera and microphone".
    static func describe(_ permissions: [SitePermission]) -> String {
        let names = permissions.map { permission in
            switch permission {
            case .camera: "camera"
            case .microphone: "microphone"
            case .location: "location"
            case .motion: "motion sensors"
            }
        }
        return "your " + ListFormatter.localizedString(byJoining: names)
    }
}

/// True for the first `claim()` only, so a continuation resumes once.
private final class Once {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
#endif
