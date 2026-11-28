#if canImport(UIKit)
import BrowserCore
import WebKit

/// Hears a page ask for the camera, microphone or location while iOS has that feature off for
/// Plain, so the shell can say why in one line instead of the request failing silently.
///
/// WebKit denies such a request before it reaches Plain's `WKUIDelegate` (the page gets
/// `NotAllowedError` or `PERMISSION_DENIED`), so the only way to know a site asked is to see the
/// call. The script wraps `getUserMedia`, `getCurrentPosition` and `watchPosition` and posts which
/// features the call needed, then calls the original. It has to run in the page's own world to see
/// the page's calls, so it is installed only while a feature is off (`watched(by:)`): with
/// everything on, pages get nothing of Plain's.
/// A page that posts on its own can only make Plain say once what is already true: the shell
/// checks the feature itself and tells each site once (`SystemAccessNoticeMemory`).
enum AccessRequestWatch {
    static let handlerName = "plainAccess"
    /// The first line of the script, to find it among a controller's scripts.
    static let marker = "/* plain-access-watch */"

    /// The features a page's request can need that are off now: camera, microphone, location.
    @MainActor
    static func watched(by monitor: SystemAccessMonitor) -> Set<SystemFeature> {
        Set([SystemFeature.camera, .microphone, .location].filter { monitor.access($0).isBlocked })
    }

    static func isWatchScript(_ script: WKUserScript) -> Bool {
        script.source.hasPrefix(marker)
    }

    /// The script for every new document while something is off. It posts every feature the call
    /// needs; the pool keeps those that are off (`pageAskedForSwitchedOff`).
    static let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    /// Idempotent, so it can also run in the documents already open when a feature goes off
    /// (`WebViewPool.systemAccessDidChange`): a function it already wrapped is left alone. The
    /// handler is looked up at each call, so a wrapper outliving it (the feature back on) posts
    /// nothing.
    static let source = """
        \(marker)
        (() => {
          const mark = Symbol.for('plainAccessWatch');
          const post = (features) => {
            if (!features.length) return;
            try { window.webkit.messageHandlers.\(handlerName).postMessage(features); } catch (e) {}
          };
          const wrap = (target, name, needs) => {
            const original = target && target[name];
            if (typeof original !== 'function' || original[mark]) return;
            const wrapped = { [name](...args) { post(needs(args)); return original.apply(this, args); } }[name];
            wrapped[mark] = true;
            try { Object.defineProperty(target, name, { value: wrapped, writable: true, configurable: true }); } catch (e) {}
          };
          // The prototypes, never the instances: a property set on a DOM wrapper is lost when
          // JavaScriptCore remakes the wrapper (docs/research/notes.md, WebKit).
          if (window.MediaDevices) {
            wrap(MediaDevices.prototype, 'getUserMedia', (args) => {
              const wants = args[0] || {};
              return [].concat(wants.video ? ['camera'] : [], wants.audio ? ['microphone'] : []);
            });
          }
          if (window.Geolocation) {
            for (const name of ['getCurrentPosition', 'watchPosition']) wrap(Geolocation.prototype, name, () => ['location']);
          }
        })();
        """

    /// Receives the script's posts for one tab.
    final class Handler: NSObject, WKScriptMessageHandler {
        private weak var tab: Tab?

        init(tab: Tab) {
            self.tab = tab
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let names = message.body as? [String], let tab, let pool = tab.pool else { return }
            // Only what a page can ask for: a post of "photos" must not reach Save Image's line.
            let askable: Set<SystemFeature> = [.camera, .microphone, .location]
            let features = names.prefix(4).compactMap(SystemFeature.init(rawValue:)).filter(askable.contains)
            pool.pageAskedForSwitchedOff(features, in: tab)
        }
    }
}
#endif
