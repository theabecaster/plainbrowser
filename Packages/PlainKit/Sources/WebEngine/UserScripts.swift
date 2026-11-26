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

    /// Remembers the element under the last finger down, so the link context menu can tell that a
    /// long press landed on an image (WebKit's public menu callback gives the link URL only). One
    /// passive listener storing a reference; nothing crosses to the app until a menu asks.
    static let pressedElementSource = """
        (() => {
          addEventListener('pointerdown', (event) => {
            globalThis.__plainPressed = event.target;
            globalThis.__plainPressedAt = Date.now();
          }, { passive: true, capture: true });
        })();
        """

    static let pressedElement = WKUserScript(
        source: pressedElementSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world
    )

    /// Asked when a link menu opens: the pressed image's address and its enclosing link, if any.
    static let pressedImageQuery = """
        // A press in an iframe never reaches this document, so an old press here is not this
        // menu's: only one from the last two seconds (a long press takes about half of one).
        if (!globalThis.__plainPressedAt || Date.now() - globalThis.__plainPressedAt > 2000) return null;
        const target = globalThis.__plainPressed;
        const image = target && target.closest ? target.closest('img') : null;
        if (!image || !image.isConnected) return null;
        const link = image.closest('a[href]');
        return { src: image.currentSrc || image.src, href: link ? link.href : null };
        """

    /// The name of the message handler `mediaSource` posts to.
    static let mediaHandlerName = "plainMedia"

    /// Reports whether media plays and whether a video is in picture in picture, per frame, only
    /// when either changes. Media events don't bubble, so the listeners capture at the window.
    /// Each frame posts with its own id; the app combines the frames.
    static let mediaSource = """
        (() => {
          const id = Math.random().toString(36).slice(2);
          const playing = new Set();
          let pip = null;
          let sent = 'false,false';
          const post = () => {
            const state = { id, playing: playing.size > 0, pip: pip !== null };
            const key = state.playing + ',' + state.pip;
            if (key === sent) return;
            sent = key;
            try { webkit.messageHandlers.\(mediaHandlerName).postMessage(state); } catch (e) {}
          };
          const isMedia = (target) => target instanceof HTMLMediaElement;
          addEventListener('playing', (e) => { if (isMedia(e.target)) { playing.add(e.target); post(); } }, true);
          for (const type of ['pause', 'ended', 'emptied', 'abort', 'error']) {
            addEventListener(type, (e) => { if (isMedia(e.target)) { playing.delete(e.target); post(); } }, true);
          }
          addEventListener('enterpictureinpicture', (e) => { pip = e.target; post(); }, true);
          addEventListener('leavepictureinpicture', (e) => { if (pip === e.target) pip = null; post(); }, true);
          addEventListener('webkitpresentationmodechanged', (e) => {
            const target = e.target;
            if (target.webkitPresentationMode === 'picture-in-picture') pip = target;
            else if (pip === target) pip = null;
            post();
          }, true);
          addEventListener('pagehide', () => { playing.clear(); pip = null; post(); });
        })();
        """

    static let media = WKUserScript(
        source: mediaSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world
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
