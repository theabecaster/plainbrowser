// Plain's cookie banner script: DuckDuckGo autoconsent's engine (MPL-2.0, unmodified, bundled from
// npm) with a small bridge to the app. It runs in Plain's own content world, so pages can't see it.
//
// The app answers every message through one WKScriptMessageHandlerWithReply named
// `plainCookieBanners` (ContentBlocking/CookieBanners.swift):
// - `init`: the reply is `initResp` with the config (reject automatically) and the rules for this
//   frame as JSON strings: `generic` (main frames only) and `specific` (rules whose address pattern
//   matches the frame), each a self-contained compact ruleset.
// - `eval`: the app runs the snippet in the frame's page world and replies `evalResp`.
// - the rest (`popupFound`, `optOutResult`, `autoconsentDone`, ...) are reports; no reply.
import AutoConsent, { decodeRules } from '@duckduckgo/autoconsent';

(() => {
    if (!/^https?:$/.test(location.protocol)) return;
    const handler = globalThis.webkit && webkit.messageHandlers && webkit.messageHandlers.plainCookieBanners;
    if (!handler || globalThis.__plainCookieBanners) return;
    globalThis.__plainCookieBanners = true;

    let consent = null;
    const send = async (message) => {
        let reply;
        try {
            reply = await handler.postMessage(message);
        } catch (e) {
            return;
        }
        if (!reply || !consent) return;
        if (reply.type === 'initResp') {
            const rules = { autoconsent: [] };
            if (reply.generic) rules.compact = JSON.parse(reply.generic);
            for (const json of reply.specific || []) {
                rules.autoconsent.push(...decodeRules(JSON.parse(json)));
            }
            consent.receiveMessageCallback({ type: 'initResp', config: reply.config, rules });
            return;
        }
        consent.receiveMessageCallback(reply);
    };
    // Without a config the engine asks for one with `init` right away; the reply arrives after the
    // constructor returns (it is awaited), so `consent` is set by then.
    consent = new AutoConsent(send);
})();
