#if canImport(UIKit)
import WebKit

/// Scripts the engine adds to every web view, in their own content world so pages can't see or
/// tamper with them.
enum UserScripts {
    static let world = WKContentWorld.world(name: "PlainEngine")

    /// Preconnect on touch (docs/plan.md, "Engine rules" 6). When a finger lands on a link to
    /// another origin, add `<link rel=preconnect>` for it, so DNS, TCP and TLS overlap the ~100 ms
    /// until the tap completes. Once per origin per page; passive listeners never delay scrolling.
    static let preconnectSource = """
        (() => {
          const seen = new Set([location.origin]);
          const onDown = (event) => {
            const link = event.target && event.target.closest ? event.target.closest('a[href]') : null;
            if (!link) return;
            let origin;
            try { origin = new URL(link.href, location.href).origin; } catch (e) { return; }
            if (!origin.startsWith('http') || seen.has(origin)) return;
            seen.add(origin);
            const hint = document.createElement('link');
            hint.rel = 'preconnect';
            hint.href = origin;
            (document.head || document.documentElement).appendChild(hint);
          };
          addEventListener('touchstart', onDown, { passive: true, capture: true });
          addEventListener('pointerdown', onDown, { passive: true, capture: true });
        })();
        """

    static let preconnect = WKUserScript(
        source: preconnectSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world
    )

    /// Reads a `blob:` URL from inside the page that made it and returns it as base64. The fallback
    /// for blob downloads WebKit could not turn into a `WKDownload`.
    static let readBlobSource = """
        const response = await fetch(url);
        const blob = await response.blob();
        const dataURL = await new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = () => reject(reader.error);
          reader.readAsDataURL(blob);
        });
        return { type: blob.type, data: dataURL.slice(dataURL.indexOf(',') + 1) };
        """
}
#endif
