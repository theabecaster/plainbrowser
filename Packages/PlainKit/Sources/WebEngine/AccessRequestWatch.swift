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
/// the page's calls, so it is installed only while a feature is off (`watched(by:)`) and wraps
/// only the APIs of the features that are off: with everything on, pages get nothing of Plain's.
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

    static func script(watching features: Set<SystemFeature>) -> WKUserScript {
        WKUserScript(source: source(watching: features), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    static func source(watching features: Set<SystemFeature>) -> String {
        let camera = features.contains(.camera)
        let microphone = features.contains(.microphone)
        let location = features.contains(.location)
        return """
            \(marker)
            (() => {
              const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
              if (!handler) return;
              const post = (features) => { if (features.length) { try { handler.postMessage(features); } catch (e) {} } };
              const wrap = (target, name, needs) => {
                const original = target && target[name];
                if (typeof original !== 'function') return;
                const wrapped = { [name](...args) { post(needs(args)); return original.apply(this, args); } }[name];
                try { Object.defineProperty(target, name, { value: wrapped, writable: true, configurable: true }); } catch (e) {}
              };
              // The prototypes, never the instances: a property set on a DOM wrapper is lost when
              // JavaScriptCore remakes the wrapper (docs/research/notes.md, WebKit).
              if (\(camera || microphone) && window.MediaDevices) {
                wrap(MediaDevices.prototype, 'getUserMedia', (args) => {
                  const wants = args[0] || {};
                  const needs = [];
                  if (\(camera) && wants.video) needs.push('camera');
                  if (\(microphone) && wants.audio) needs.push('microphone');
                  return needs;
                });
              }
              if (\(location) && window.Geolocation) {
                for (const name of ['getCurrentPosition', 'watchPosition']) wrap(Geolocation.prototype, name, () => ['location']);
              }
            })();
            """
    }

    /// Receives the script's posts for one tab.
    final class Handler: NSObject, WKScriptMessageHandler {
        private weak var tab: Tab?

        init(tab: Tab) {
            self.tab = tab
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let names = message.body as? [String], let tab, let pool = tab.pool else { return }
            let features = names.prefix(4).compactMap(SystemFeature.init(rawValue:))
            pool.pageAskedForSwitchedOff(features, in: tab)
        }
    }
}
#endif
