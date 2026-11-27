# Cookie banner handling: research

Researched 2026-11-26. Every fact below came from the sources linked, or from the
npm tarball of `@duckduckgo/autoconsent@18.13.0`, which was unpacked and measured locally.

## Bottom line

- Bundle DuckDuckGo **autoconsent** (MPL-2.0) and run it in a private content world, with DDG's
  iOS wiring as the model. It is the only maintained reject-first engine. It ships rules daily
  and handles iframes, shadow DOM and page-world JS APIs.
- Keep the EasyList Cookie content rules as the hide-only fallback.
- MPL-2.0 can be combined with AGPL-3.0. Keep the MPL files and their license notice as shipped.
- A hand-written script for about 12 CMPs is cheaper to load. It would rot within months and
  miss the long tail, which is about 1,600 rules.

## 1. DuckDuckGo autoconsent

**License: MPL-2.0, confirmed.** npm `license` is `MPL-2.0`, the GitHub repo reports
`MPL-2.0`, and the readme says "MPLv2". No source file carries the Exhibit B notice
("Incompatible With Secondary Licenses"). The phrase appears only in the LICENSE text.
The source files carry no per-file Exhibit A header either. The root LICENSE is the only notice.
https://github.com/duckduckgo/autoconsent · https://www.npmjs.com/package/@duckduckgo/autoconsent

**Version and size.** The latest is **18.13.0**, published 2026-11-27 00:15 UTC.
DDG's apple-browsers repo pins **18.12.0**.

| File (npm `dist/`) | Raw | Minified | Gzip |
|---|---|---|---|
| `autoconsent.esm.js` (engine + class CMPs, no JSON rules) | 202 KB | 132 KB (esbuild) | 42 KB min / 56 KB raw |
| `autoconsent.standalone.js` (engine + all rules inlined, self-starting) | 844 KB | 700 KB | 176 KB min / 193 KB raw |
| `rules/compact-rules.json` (all JSON rules, compact encoding) | 599 KB | n/a | 135 KB |
| `rules/rules.json` (same rules, verbose) | 1.2 MB | n/a | n/a |
| DDG iOS `autoconsent-bundle.js` (rollup + terser of `userscript.js`) | 126,692 B | n/a | n/a |

**Rule types (v18).**
- **Class-based `AutoCMP`** in `lib/cmps/*.ts`, for CMPs that need branching logic. Ten are
  shipped: OneTrust, Cookiebot, Sourcepoint-frame, TrustArc-top, Klaro, consentmanager, Evidon,
  Admiral, Uniconsent and TikTok.
- **JSON rules** in `rules/autoconsent/*.json`: 1,606 rules in total. Of these, 872 are
  site-specific (`urlPattern`), 734 are generic, and 16 may run in frames. There are 198 `cosmetic: true`
  rules, which hide the banner without answering it.
- **Consent-O-Matic rules are no longer supported.** The changelog for v16.0.0 (2026-06-23) says
  "Drop support for consent-o-matic rules" (#1393). The prompt's assumption that they are still
  used is out of date.
- **Heuristic detection** (`enableHeuristicDetection`, `heuristicMode`) classifies popups and
  buttons by text regex when no rule matches. DDG gates it behind remote config.
- Each rule has `detectCmp`, `detectPopup`, `optOut`, `optIn` and optional `prehideSelectors` and `test`.
  Step primitives: `exists`, `visible`, `waitFor`, `waitForThenClick`, `click`, `hide`,
  `eval`, `if/then/else`, `any`, and `stylesheet`. An array selector pierces open shadow roots and
  same-origin iframes, for example `["#usercentrics-root", "[data-testid=uc-deny-all-button]"]`.
  https://github.com/duckduckgo/autoconsent/blob/main/docs/rule-syntax.md

**Flow** (docs/api.md):
1. The content script sends `init` and the host replies `initResp {rules, config}`. The host may
   instead pass the config to the constructor.
2. The script prehides known selectors (opacity / z-index), waits for DOMContentLoaded, detects a CMP and
   sends `cmpDetected`. It then detects a visible popup and sends `popupFound`.
3. If `config.autoAction = "optOut"`, the script proceeds by itself. Otherwise the host sends `optOut`.
4. The script runs the steps, then sends `optOutResult`, then `autoconsentDone {cmp, isCosmetic, duration, totalClicks}`.
5. Optional: the host sends `selfTest` and the script replies `selfTestResult`. The script also
   sends `report` periodically, and `autoconsentError` on failure.
6. **`eval`**: the script sends `{type:"eval", id, code}`. The host runs the code in the page main
   world and replies `{type:"evalResp", id, result}`. The script needs this because it runs in an
   isolated world and cannot reach `window.OneTrust`, `window.Cookiebot` and similar objects.

`lib/messages.ts` lists the full message set. Content script to host: `init`, `eval`, `visualDelay`,
`cmpDetected`, `popupFound`, `optOutResult`, `optInResult`, `selfTestResult`,
`autoconsentDone`, `autoconsentError`, `report`. Host to content script: `initResp`, `evalResp`,
`optOut`, `optIn`, `selfTest`.

**Standalone build.** `dist/autoconsent.standalone.js` (source `standalone/content.ts`)
needs no background script. It inlines `compact-rules.json`, filters the rules by URL,
sets `isMainWorld: true` and logs to the console. It is a 700 KB debug/Playwright build meant to be
injected into the page world. It is not suitable for production. For production, use the
ESM engine with a native host, as DDG does. `new AutoConsent(send, config, rules)` with a
config skips the `init` round trip.

**How often rules change.** npm shows 57 releases between 2026-08-26 and 2026-11-27,
roughly one per weekday, almost all rule fixes. The CHANGELOG is 449 KB.

### How DDG iOS wires it (duckduckgo/apple-browsers, `iOS/DuckDuckGo/Autoconsent/`)

- `userscript.js` (540 B) imports `@duckduckgo/autoconsent`. It calls `new AutoConsent(send)`,
  where `send` posts each message to `window.webkit.messageHandlers[message.type]` and feeds
  the reply promise back into `autoconsent.receiveMessageCallback`. It also exposes
  `window.autoconsentMessageCallback` for host-initiated messages. Rollup then produces an
  IIFE, `autoconsent-bundle.js`.
- `AutoconsentUserScript.swift` is a `WKScriptMessageHandlerWithReply`. It registers one
  handler name per message type (`init`, `cmpDetected`, `eval`, `popupFound`, `optOutResult`,
  `optInResult`, `selfTestResult`, `autoconsentDone`, `autoconsentError`, `report`).
  The script is set to `injectionTime = .atDocumentStart` and `forMainFrameOnly = false` (all frames).
- **Content world: `.defaultClient`.** The UserScript protocol defaults
  `requiresRunInPageContentWorld` to false, so the script runs in `.defaultClient`. The self-test
  call is `evaluateJavaScript("window.autoconsentMessageCallback({type:'selfTest'})", in: frameInfo, in: .defaultClient)`.
- **`eval`** wraps the code as `(() => { try { return !!(CODE); } catch (e) { return; } })()`.
  It runs through `webView.evaluateJavaScript(script, in: message.frameInfo, in: WKContentWorld.page)`
  and replies with `evalResp`, so the code runs in the page world of the exact frame that asked.
- **`init`** handling:
  - Ignores non-http(s) URLs.
  - Respects the user setting and the per-domain remote allowlist (`config.isFeature(.autoconsent, enabledForDomain:)`).
  - Turns off `autoAction` when it detects a reload loop. A reload loop is the same CMP handled again after reload.
  - Replies `initResp` with `rules: {compact: remoteConfig["compactRuleList"]}`. The rules come from
    DDG's remote privacy config, not from the app bundle. The reply's config is `autoAction:"optOut"`,
    `enablePrehide`, `enableCosmeticRules`, `detectRetries:20`, `isMainWorld:false`, `disabledCmps`
    and the heuristic flags.
- `autoconsentDone` posts `.newSiteCookiesManaged`, which drives the "cookies managed" animation
  and the privacy-dashboard state. `isCosmetic` tells the app whether the popup was rejected or only hidden.
- **New path:** iOS 18.4 or later with the `embeddedExtension` feature flag runs autoconsent as an
  embedded **WKWebExtension** instead. The user script then defers (`isAutoconsentExtensionAvailable`).

Source: https://github.com/duckduckgo/apple-browsers/blob/main/iOS/DuckDuckGo/Autoconsent/AutoconsentUserScript.swift

## 2. MPL-2.0 inside an AGPL-3.0-only app

The MPL 2.0 LICENSE text quoted below is from the autoconsent package.

> **1.12. "Secondary License"** means either the GNU General Public License, Version 2.0, the GNU
> Lesser General Public License, Version 2.1, the GNU Affero General Public License, Version 3.0,
> or any later versions of those licenses.

> **3.3. Distribution of a Larger Work.** You may create and distribute a Larger Work under terms of
> Your choice, provided that You also comply with the requirements of this License for the Covered
> Software. If the Larger Work is a combination of Covered Software with a work governed by one or
> more Secondary Licenses, and the Covered Software is not Incompatible With Secondary Licenses, this
> License permits You to additionally distribute such Covered Software under the terms of such
> Secondary License(s) [...]

**Verdict: compatible.** AGPL-3.0 is named as a Secondary License. Autoconsent has no Exhibit B
notice, so §3.3 applies. Obligations when shipping unmodified files:
- Keep the MPL notice. Ship autoconsent's LICENSE in-repo, for example
  `ThirdParty/autoconsent/LICENSE`, and list it in the app's acknowledgements screen.
  §3.4 forbids removing or altering license notices.
- §3.2(a) source availability: the executable form (the minified bundle in the IPA) must come with a
  way to get the source. Plain is AGPL and public, so the vendored source or a link to the exact
  npm version or tag is enough. Record the version, for example `18.13.0`, next to the bundle.
- Changes to MPL files stay MPL at file level, and their source must be published. That happens
  anyway in a public repo. Keep Plain's own glue (Swift and the small JS shim) in separate files
  under AGPL.
- https://www.mozilla.org/en-US/MPL/2.0/ · https://www.mozilla.org/en-US/MPL/2.0/FAQ/

## 3. Brave

- **"Block cookie consent notices"** subscribes to Fanboy's Cookiemonster list, shown in the UI as the
  "EasyList-Cookie List". It **hides** banners and fixes scroll lock with cosmetic and procedural
  filters. It never clicks. The feature shipped in 1.45 (2022-09-28) and became on by default
  on 2023-06-09. iOS was promised "soon after", and the translated posts place the toggle in the iOS
  Shields settings.
- Brave's reason for not auto-clicking "reject": the click still sends a signal to every CMP, and
  research found many CMPs track users after a rejection anyway.
  https://brave.com/privacy-updates/21-blocking-cookie-notices/
- Plain already does what Brave does through its cookie content rules.

**"I don't care about cookies"** (IDCAC) is now published by Avast, part of Gen Digital.
AMO lists it under **GPL-3.0-only**. It **does not prefer reject**. It hides most banners. Where a
site breaks otherwise, it accepts "either all cookies or only the necessary ones, whichever is
easier". The community fork "I still don't care about cookies" (OhMyGuus) is also GPL-3.0.
GPL-3.0 can be combined with AGPL-3.0 through §13 of both licenses. IDCAC's accept-when-easier
policy conflicts with Plain's reject-first goal, so do not use it.
https://www.i-dont-care-about-cookies.eu/ · https://addons.mozilla.org/firefox/addon/i-dont-care-about-cookies/ ·
https://github.com/OhMyGuus/I-Still-Dont-Care-About-Cookies

## 4. Firefox Cookie Banner Reduction: removed

- **Design.** Per-site rules came from `mozilla/cookie-banner-rules-list` (MPL-2.0) and were applied in two
  ways: **cookie injection**, which set the CMP's "rejected" cookie before load, and **click rules**
  (presence selector, hide selector, reject-button selector). The service mode was 1 for reject or
  2 for reject-then-accept. It launched in Firefox 120, on by default only in German private windows.
  https://support.mozilla.org/kb/cookie-banner-reduction
- **Status.** The rules repo is **archived**. Its last push was 2025-01-07, and its README says PRs are not
  accepted "since Cookie Banner Handling is currently not enabled in Firefox". Bug **2058143**,
  "Remove cookie banner handling implementation", is RESOLVED FIXED with milestone **Firefox 155**.
  Its notes say "no prior deprecation and no replacement". Mozilla's support page now points users
  to uBlock Origin's cookie-notice lists.
  https://bugzilla.mozilla.org/show_bug.cgi?id=2058143 · https://github.com/mozilla/cookie-banner-rules-list
- Lesson: a browser vendor's own per-site rule list died for lack of maintenance. Do not hand-maintain one.

## 5. Consent-O-Matic (CAVI, Aarhus University)

- **MIT license** (© 2019-2022 Kristensen and Bagge), so it is compatible with AGPL.
  The repo was last pushed on 2026-02-07 and has about 4.3k stars. It is a WebExtension with JSON CMP rules
  and per-category choices. Its rule engine is less maintained than autoconsent's, and DDG dropped
  its rule format in v16. Use it only as a fallback reference for selectors.
  https://github.com/cavi-au/Consent-O-Matic

## 6. Common CMPs: how to reject

The selectors below come from autoconsent v18.13.0 rules. "API" means a page-world call, which needs
`eval` in the `.page` world.

| CMP | First-layer reject (DOM) | DOM quirks | Page-world API |
|---|---|---|---|
| OneTrust | `#onetrust-reject-all-handler`; else `.ot-pc-refuse-all-handler`; close button only if its text says reject or without | Wait for SDK (`#onetrust-style`); many US banners have no reject button | `OneTrust.RejectAll()` (documented; also `AllowAll()`, `Close()`) |
| Cookiebot | `#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll`, `#CybotCookiebotDialogBodyButtonDecline` | Custom templates reuse its IDs | No `decline()`. Documented methods: `show/hide/renew/getScript/runScripts/withdraw/submitCustomConsent`. Autoconsent uses `withdraw()` + `hide()`, test `Cookiebot.declined` |
| Didomi | `#didomi-notice-disagree-button`, `.didomi-continue-without-agreeing` | Some sites have no first-layer reject (`#acceptationCMPWall`, a consent-or-pay wall) | `Didomi.setUserDisagreeToAll()` |
| Quantcast (Choice) | `#disagree-btn:not([disabled])`; else secondary summary button | Reject renders disabled with a loader, so wait. US (`#qc-cmp2-usp`) needs toggles plus confirm | `__tcfapi` only |
| Usercentrics | `["#usercentrics-root","[data-testid=uc-deny-all-button]"]` | **Open shadow DOM**; v3 root is `#usercentrics-cmp-ui` `[data-action-type=deny]` | `UC_UI.denyAllConsents()` (v2, used by autoconsent); `__ucCmp.denyAllConsents()` (v3, documented) |
| Sourcepoint | `.sp_choice_type_13` or `REJECT_ALL` in the message iframe; else manage `.sp_choice_type_12`, then `SAVE_AND_EXIT` | **Cross-origin iframe** (`*.sp-prod.net`, `message_id=`). The top frame only hides the container and restores scroll | none useful |
| TrustArc | `#truste-consent-required` | Old banner uses an iframe (`.truste_popframe`); new CM is `trustarc-newcm` | `truste.eu.bindMap` (test only) |
| Complianz | `.cmplz-cookiebanner .cmplz-deny` | cookieconsent-based variants (`.cc-deny`) | none |
| CookieYes | `.cky-consent-container [data-cky-tag=reject-button]`; legacy `#cky-btn-reject` | US variant: "do not sell" toggle | none |
| Osano | `.osano-cm-denyAll`, `.osano-cm-deny` | Bar variant may have only close, so hide it | `Osano.cm` (detect) |
| Klaro | `.klaro .cn-decline` | | `klaro.getManager()` API opt-out |
| Borlabs | `.brlbs-btn-accept-only-essential`, `a[data-cookie-refuse]` | Older versions only offer save | none |
| iubenda | `.iubenda-cs-reject-btn`; else customize, `.iub-btn-reject`, `#iubFooterBtn` | Some sites lack reject (Italian RTI sites use custom rules) | none |
| consentmanager.net | n/a | | `__npcmp('reject')` (new) / `__cmp` |

The CMPs that need iframes or shadow DOM are Sourcepoint (cross-origin iframe), TrustArc (iframe,
legacy), Usercentrics (shadow DOM) and Axeptio (styled container). Sourcepoint's and TrustArc's
frames are cross-origin, so the script must run in every frame (`forMainFrameOnly = false`).
WKWebView user scripts do run in cross-origin subframes.

Some CMPs have no reject button on the first layer. These include OneTrust (many configs), Didomi
consent-or-pay walls, Quantcast's US dialog, older Borlabs and some iubenda setups. For these the
script must go through the settings screen, which is where hand-written scripts usually break.

## 7. Other iOS browsers

- **Safari:** no automatic handling. iOS 18 added "Hide Distracting Items", a manual per-element hide.
  It does not answer the banner and does not reliably persist for dynamic content.
  https://support.apple.com/120682
- **Chrome iOS:** no cookie-banner feature found.
- **Arc Search:** its App Store text says it will "automatically try to deny those annoying cookie consent
  prompts". A later release adds "if we can't reliably deny the cookie prompt, we'll leave it alone".
  That release fixed broken scrolling caused by over-eager blocking, which shows how this approach fails.
  https://apps.apple.com/app/arc-search/id6472513080
- **DuckDuckGo iOS:** autoconsent, default on, with a per-site off switch through its protections toggle.
- **Brave iOS:** hides banners through the cookie list, as described in section 3.

## Recommendation for Plain

**Choose (a): bundle autoconsent's ESM engine and rules, wired like DDG's. Keep the cookie content
rules as the fallback.**

| | (a) autoconsent | (b) own ~12-CMP script |
|---|---|---|
| Coverage | 10 class CMPs + 1,606 JSON rules + heuristics | ~12 CMPs; long tail falls to hide-only |
| Reject quality | Second-layer flows, waits, US/CCPA variants, self-tests | First-layer buttons only, unless we rebuild those flows |
| Maintenance | `npm update` + rebuild; rules ship ~daily upstream | We find breakage ourselves; Firefox's list died this way |
| Size in IPA | ~132 KB engine (42 KB gz) + 599 KB compact rules | ~5-10 KB |
| Per-frame cost | Parse ~130 KB JS per frame + rule decode; JSON rules for subframes are only the 16 frame rules | Negligible |
| Integration | ~300 lines of Swift (DDG pattern) + JS shim + LICENSE notice | ~150 lines of JS + small handler |
| License | MPL-2.0, compatible, keep notice | AGPL, ours |

How to build (a) cheaply:
1. JS shim, about 20 lines, like DDG's `userscript.js`. Bundle it with esbuild as an IIFE.
   Inject it at `.atDocumentStart` with `forMainFrameOnly: false` into a **named content world**
   (`WKContentWorld.world(name: "plain.cookies")`), not `.page`, so pages cannot see or spoof it.
2. One `WKScriptMessageHandlerWithReply`. In it:
   - Reply to `init` with `initResp`, carrying `autoAction: "optOut"`, `enablePrehide`, `enableCosmeticRules` and `isMainWorld: false`.
   - Handle `eval` by running the code through `evaluateJavaScript(_:in: frameInfo, in: .page)`, wrapped in `!!(...)` with try/catch as DDG does.
   - On `autoconsentDone`, record the result per site (rejected vs cosmetic) for a small status hint.
3. Per-site off: skip injection, or answer `init` with `enabled: false`, for hosts on the user's list.
   Add DDG-style reload-loop protection: if the same CMP is handled twice in a row on the same
   host, stop auto-acting for that tab.
4. Rules:
   - Ship `compact-rules.json` in the bundle. Optionally pre-filter per frame on the native side with
     `index.frameRuleRange` and `index.genericRuleRange`, so a subframe receives about 16 rules
     instead of 599 KB over the bridge.
   - Run heuristics in `"off"` or a conservative mode at first. A wrong click is worse than a visible banner.
   - Update by bumping the npm version at each release. No remote config is needed at first.
5. Keep the EasyList Cookie content rules on. They hide whatever autoconsent misses, at zero JS cost.
   Watch for conflicts. A hidden banner (`display:none`) fails autoconsent's `visible` checks, so the
   site never records a rejection. DDG's prehide uses opacity rather than display for this reason.
   Measure how often the two overlap. If it is often, exempt the top CMP container selectors from
   the cosmetic list so autoconsent can answer them.
6. Perf gate: measure added time to first paint and memory on a page with several iframes, with
   and without autoconsent. If per-frame parse cost is too high, inject only into the main frame
   plus frames whose URL matches known CMP hosts. Do this check from the `init` handler, which
   carries `frameInfo`.

Option (b) is only better if the perf gate fails badly. Even then the better fallback is autoconsent
restricted to the main frame, not a fork. A hand-written list of ~12 CMPs covers the selectors in
the table above. It still misses the settings-screen flows, the US variants and the timing fixes
that make up most of autoconsent's changelog.
