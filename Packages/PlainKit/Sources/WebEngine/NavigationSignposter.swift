import os
import PerfSignposts
import WebKit

/// A navigation delegate that emits the `nav.commit` and `nav.finish` intervals for every
/// main-frame navigation of the web view it is attached to.
public final class NavigationSignposter: NSObject, WKNavigationDelegate {
    private struct Open {
        var commit: OSSignpostIntervalState?
        let finish: OSSignpostIntervalState
    }

    private var open: [ObjectIdentifier: Open] = [:]

    override public init() {}

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation else { return }
        let signposter = Signposts.signposter
        let id = signposter.makeSignpostID()
        open[ObjectIdentifier(navigation)] = Open(
            commit: signposter.beginInterval(Signposts.navCommit, id: id),
            finish: signposter.beginInterval(Signposts.navFinish, id: id)
        )
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let navigation, let state = open[ObjectIdentifier(navigation)]?.commit else { return }
        Signposts.signposter.endInterval(Signposts.navCommit, state)
        open[ObjectIdentifier(navigation)]?.commit = nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        end(navigation, outcome: "finished")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        end(navigation, outcome: "failed")
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        end(navigation, outcome: "failed")
    }

    /// A crashed page never finishes its navigations; close their intervals.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        for state in open.values {
            if let commit = state.commit {
                Signposts.signposter.endInterval(Signposts.navCommit, commit, "crashed")
            }
            Signposts.signposter.endInterval(Signposts.navFinish, state.finish, "crashed")
        }
        open = [:]
    }

    private func end(_ navigation: WKNavigation?, outcome: StaticString) {
        guard let navigation, let state = open.removeValue(forKey: ObjectIdentifier(navigation)) else { return }
        let signposter = Signposts.signposter
        if let commit = state.commit {
            signposter.endInterval(Signposts.navCommit, commit, "\(outcome)")
        }
        signposter.endInterval(Signposts.navFinish, state.finish, "\(outcome)")
    }
}
