# Translate Page: research

Scope: on-device, in-place page translation for Plain (iOS 27.2, WKWebView, Swift 6, UIKit shell).
Researched 2026-11-26. Apple doc links use the `.md` form, which returns the raw doc text and availability metadata.

## 1. Apple Translation framework

### Getting a session

- Two ways to get a `TranslationSession`: from SwiftUI `.translationTask(...)`, or, "for contexts where there's no UI", directly through `init(installedSource:target:)`. [TranslationSession](https://developer.apple.com/documentation/translation/translationsession.md)
- Direct initializer, **iOS 26.0+**: `convenience init(installedSource source: Locale.Language, target: Locale.Language?)`. It needs an explicit source language. "If one or both of the languages aren't installed on the device already, attempting to translate will throw errors." With it "you don't need a `.translationTask()`". [init(installedSource:target:)](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:).md)
- Strategy variant, **iOS 26.4+**: `convenience init(installedSource source: Locale.Language, target: Locale.Language?, preferredStrategy: TranslationSession.Strategy)`. [init(installedSource:target:preferredStrategy:)](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:preferredstrategy:).md)
- A directly created session **cannot request downloads**. `canRequestDownloads` (iOS 26.0+) is always true for `.translationTask` sessions and false for `init(installedSource:)` sessions. If you translate with missing languages, it throws `TranslationError.notInstalled`. [canRequestDownloads](https://developer.apple.com/documentation/translation/translationsession/canrequestdownloads.md)
- So the download prompt still needs SwiftUI. Use `.translationTask` on a view that is in a window, then call `prepareTranslation()` or translate. UIKit apps host that view in a `UIHostingController`. Apple forum replies give the same advice. [Forum 756837](https://developer.apple.com/forums/thread/756837), [Forum 758156](https://developer.apple.com/forums/thread/758156)
- A `.translationTask` session "is tied to the view it was anchored to, so it won't work if the underlying view disappears". Do not store it outside the view's lifetime. [WWDC24 10117](https://developer.apple.com/videos/play/wwdc2024/10117/) (Best practices chapter). Developers report a `fatalError` when they use it after the view goes away, for example in reused cells. [Forum 765326](https://developer.apple.com/forums/thread/765326)
- `.translationTask` signatures:
  - `translationTask(_ configuration: TranslationSession.Configuration?, action: @escaping (TranslationSession) async -> Void)` (iOS 18) [doc](https://developer.apple.com/documentation/swiftui/view/translationtask(_:action:).md)
  - `translationTask(source:target:preferredStrategy:action:)` (iOS 26.4) [doc](https://developer.apple.com/documentation/swiftui/view/translationtask(source:target:preferredstrategy:action:).md)
- `TranslationSession.Configuration`: `init(source:target:)`, plus `init(source:target:preferredStrategy:)` (iOS 26.4). Call `invalidate()` to re-run the action with the same languages. `nil` source means auto-detect. `nil` target means the system picks one from `Locale.preferredLanguages`. [Configuration](https://developer.apple.com/documentation/translation/translationsession/configuration.md), [init(source:target:preferredStrategy:)](https://developer.apple.com/documentation/translation/translationsession/configuration/init(source:target:preferredstrategy:).md)

### Session API (iOS 18 unless noted)

- `func translate(_: String) async throws -> Response` and an `AttributedString` overload that keeps formatting. [TranslationSession](https://developer.apple.com/documentation/translation/translationsession.md)
- `func translations(from batch: [TranslationSession.Request]) async throws -> [TranslationSession.Response]` returns everything at once, in request order. [translations(from:)](https://developer.apple.com/documentation/translation/translationsession/translations(from:).md)
- `func translate(batch: [TranslationSession.Request]) -> TranslationSession.BatchResponse` returns an `AsyncSequence` that streams results, possibly out of order. Match each result by `clientIdentifier`. [translate(batch:)](https://developer.apple.com/documentation/translation/translationsession/translate(batch:).md)
- `Request.init(sourceText: String, clientIdentifier: String?)`. The `clientIdentifier` lives on the **Request and Response**, not on the session. [Request](https://developer.apple.com/documentation/translation/translationsession/request.md)
- All strings in one batch must be in the same source language. [translations(from:)](https://developer.apple.com/documentation/translation/translationsession/translations(from:).md)
- `func prepareTranslation() async throws` asks permission to download. It returns without a prompt if the languages are already installed or downloading. It throws `unableToIdentifyLanguage` if the source is `nil`. [prepareTranslation()](https://developer.apple.com/documentation/translation/translationsession/preparetranslation().md)
- `var isReady: Bool { get async }` (iOS 26.0+) reports whether both languages are installed. Languages can still be deleted after you check. [isReady](https://developer.apple.com/documentation/translation/translationsession/isready.md)
- `func cancel()` (iOS 26.0+): later requests throw `alreadyCancelled`. [cancel()](https://developer.apple.com/documentation/translation/translationsession/cancel().md)
- `TranslationSession.Strategy` (iOS 26.4+):
  - `.highFidelity` uses Apple Intelligence models when present, needs no download, supports more languages, and is slower.
  - `.lowLatency` uses the traditional models.
  - [Strategy](https://developer.apple.com/documentation/translation/translationsession/strategy.md), [highFidelity](https://developer.apple.com/documentation/translation/translationsession/strategy/highfidelity.md)
- Batch calls show system UI when needed: a download prompt, progress, and a source-language picker if detection fails. If the user dismisses the progress view, the call throws `CocoaError.userCancelled` and the download continues in the background. "Calls to this function can take several minutes while languages download." [translations(from:)](https://developer.apple.com/documentation/translation/translationsession/translations(from:).md)
- Batching is the efficient path: "it's best and most efficient to use one of the batch translation functions". [WWDC24 10117](https://developer.apple.com/videos/play/wwdc2024/10117/)
- Everything runs on device. Apple may collect usage metrics (bundle ID, language pair) but never the content. [TranslationSession](https://developer.apple.com/documentation/translation/translationsession.md)
- The simulator is not supported. Develop on a physical device. [WWDC24 10117](https://developer.apple.com/videos/play/wwdc2024/10117/), [sample notes](https://developer.apple.com/documentation/translation/translating-text-within-your-app.md)
- Same-language pairs are unsupported (for example en-GB to en-US). [Translating text within your app](https://developer.apple.com/documentation/translation/translating-text-within-your-app.md)
- Limits: Apple documents **no** maximum request size, batch count, concurrency, or rate limit. Size batches by measurement, not by spec.

### Threading (Swift 6)

- The `translate` methods are `@concurrent`, so the work runs off the main actor. Apple DTS: wrap the closure body in `Task { @MainActor in ... }`, and "`translate` will still run in the background because it's a '@concurrent instance method'". `@preconcurrency import Translation` also silences the Swift 6 "sending main actor-isolated 'session'" error. [Forum 816900](https://developer.apple.com/forums/thread/816900)
- A known glitch: if the hosting view's state changes while the download sheet is up, the sheet can auto-dismiss with `TranslationErrorDomain` 14/20 errors. Keep the host view stable during `prepareTranslation()`. [Forum 783311](https://developer.apple.com/forums/thread/783311)

### LanguageAvailability

- `LanguageAvailability()` is available from iOS 18. `init(preferredStrategy:)` arrived with Strategy (iOS 26.4). [LanguageAvailability](https://developer.apple.com/documentation/translation/languageavailability.md)
- `func status(from: Locale.Language, to: Locale.Language?) async -> LanguageAvailability.Status`. [LanguageAvailability](https://developer.apple.com/documentation/translation/languageavailability.md)
- `func status(for text: String, to target: Locale.Language?) async throws -> Status` (iOS 18) detects the language from sample text. It throws `TranslationError` if detection fails. "For best results ... at least 20 characters". [status(for:to:)](https://developer.apple.com/documentation/translation/languageavailability/status(for:to:).md)
- `Status` has three cases:
  - `.installed`: ready to use.
  - `.supported`: needs a download.
  - `.unsupported`: not available.
  - [Status](https://developer.apple.com/documentation/translation/languageavailability/status.md)
- `var supportedLanguages: [Locale.Language] { get async }`. [supportedLanguages](https://developer.apple.com/documentation/translation/languageavailability/supportedlanguages.md)

### TranslationError

- Cases: `nothingToTranslate`, `unableToIdentifyLanguage`, `internalError`, `alreadyCancelled`, `notInstalled`, `unsupportedSourceLanguage`, `unsupportedTargetLanguage`, `unsupportedLanguagePairing`. Match with `~=`. [TranslationError](https://developer.apple.com/documentation/translation/translationerror.md)

### iOS 26 / 27 changes

- **iOS 26.0** added the direct `init(installedSource:target:)`, `canRequestDownloads`, `isReady`, and `cancel()` (availability metadata in the docs above).
- **iOS 26.4** added `Strategy` (`highFidelity` / `lowLatency`) across the session, the configuration, `translationTask`, and `LanguageAvailability`.
- **iOS 27**: I found no Translation API additions in the docs or WWDC26 sessions. The only iOS 27 change I found is more languages in the Translate app. [9to5Mac](https://9to5mac.com/?p=1060086)
- Text-based detection, `status(for:to:)`, is not new. It has existed since iOS 18.

## 2. Language detection

- `<html lang>` is author-declared. It is often missing, wrong, or a CMS default such as `en` on non-English pages. Treat it as a hint only.
- `NLLanguageRecognizer`: `processString`, then read `dominantLanguage` or `languageHypotheses(withMaximum:)`. Apple says accuracy is lower for "very short inputs of only a few words". With short or ambiguous text, inspect the hypotheses. [Identifying the language in text](https://developer.apple.com/documentation/naturallanguage/identifying-the-language-in-text.md), [NLLanguageRecognizer](https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer.md)
- A few KB of body text is plenty. Close pairs such as Danish and Norwegian Bokmål give split probabilities (56% / 43%), so require a margin before you trust the top result. [NSHipster](https://nshipster.com/nllanguagerecognizer/)
- `languageHints` and `languageConstraints` can bias the result. Use the `lang` attribute as a hint here. Some languages are missing: Malay is not recognized. [Forum 852335](https://developer.apple.com/forums/thread/852335)
- WWDC24 advice: pass a `nil` source when you can. Otherwise use `NLLanguageRecognizer` and convert the result to `Locale.Language`. [WWDC24 10117](https://developer.apple.com/videos/play/wwdc2024/10117/)
- No published latency benchmark exists. Detection is a small on-device model call. Run it off the main thread on at most about 2 KB of text.
- Compare languages with `Locale.Language`:
  - Use `languageCode` plus the script from `maximalIdentifier` (always includes script, e.g. `zh-Hant-TW`). Then zh-Hans and zh-Hant count as different languages, while en-GB and en-US count as the same.
  - `isEquivalent(to:)` and `hasCommonParent(with:)` also exist.
  - [swift-foundation source](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationInternationalization/Locale/Locale+Components_ICU.swift)
- Offer translation only when the page language differs from **every** entry in `Locale.preferredLanguages`, comparing language plus script. Region does not matter.

## 3. How other iOS browsers do it

- **Safari iOS**:
  - The translate control sits in the address-bar page menu (the "AA" / page-format button). "View Original" restores the page.
  - Apple labels it beta, not available in all regions, and page content goes to Apple (server-side).
  - [Apple iPhone guide](https://support.apple.com/en-kg/guide/iphone/browse-the-web-iph1fbef4daa/14.0), [MacRumors](https://www.macrumors.com/how-to/safari-webpage-translation-ios/)
  - Safari drives WebKit **private SPI**: `_WKTextManipulationConfiguration`, `_startTextManipulationsWithConfiguration:`, `_completeTextManipulationForItems:`, `_translationDelegate`, `_displayedTranslationLocaleIdentifier`. App Store apps cannot use these. [WKWebViewPrivate.h](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewPrivate.h)
- **Chrome iOS**:
  - The translate infobar or badge appears near the omnibox, with "Translate…" in the overflow menu and "Show original".
  - `TranslateController` plus `TranslateJavaScriptFeature` inject the translate script into the WKWebView, using Google's server-side Translate element.
  - [components/translate/ios/browser](https://chromium.googlesource.com/chromium/src/+/main/components/translate/ios/browser/), [ios/chrome/browser/translate/model](https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/browser/translate/model/)
  - Google Translate wraps text in `<font>` elements. This is the source of the React crash below.
- **Firefox iOS (146+)**:
  - On device, using the Bergamot engine in WebAssembly, not Apple's API.
  - A translate icon appears in the address bar when the page language differs from the device language. It translates the whole page, into the device language only, and is in a progressive rollout.
  - [Mozilla support](https://support.mozilla.org/en-US/kb/translate-firefox-ios), [How-To Geek via Yahoo](https://tech.yahoo.com/apps/articles/firefoxs-local-page-translation-finally-194737978.html)
- **Brave iOS**:
  - A setting under All Settings enables it. A translate icon then appears in the address bar, and pages translate "to languages supported by your iOS device".
  - The engine is not documented publicly.
  - [Brave help](https://support.brave.app/hc/en-us/articles/35317963641101-How-do-I-use-Brave-Translate-iOS)
- **Arc Search**: up-arrow menu, then Display Options, then Translate. It uses the Google Translate header, with "once / always" choices. [Arc help](https://resources.arc.net/hc/en-us/articles/20887042551831), [TechCrunch](https://techcrunch.com/2024/01/28/arcs-new-iphone-browser-wants-to-be-your-search-companion)
- **DuckDuckGo iOS**: I found no built-in page translation.
- Common pattern: every browser surfaces translate from the address bar or page menu. Every browser offers a single "Show original" toggle. Only Chrome and Firefox add a banner or infobar.

### Firefox `TranslationsDocument` (most relevant design)

Source: [translations-document.sys.mjs](https://github.com/mozilla-firefox/firefox/blob/main/toolkit/components/translations/content/translations-document.sys.mjs). License: **MPL-2.0** (file header). File-level copyleft: you may copy ideas freely. Copied code must stay MPL in its own files with source available. Mixing it into AGPL is allowed (MPL §3.3 secondary-license compatibility).

- **Subdivide**: walk the DOM from the roots and find "blocks", meaning elements whose children are all inline or text. Display is read from computed style, `display !== "inline"`. Each block is one translation unit.
- **Unit payload**:
  - A text node or a leaf element (`innerHTML === textContent`) goes as plain text.
  - Anything else goes as **innerHTML**, with each child tagged `data-moz-translations-id`.
- **Write-back**: `updateElement` parses the translated HTML with `DOMParser`. It then **merges** into the live tree, reusing the original element nodes by id and moving them into the translated order. Only text changes and inline tags survive with their identity, so listeners and styles stay intact.
- **Write-back guards**: it pins `<option>` values and restores `<select>` values, so form submissions do not change.
- **Exclusions**:
  - `[translate=no]`, `.notranslate`.
  - Tags: CODE, KBD, SAMP, VAR, ACRONYM, MATH, EMBED, OBJECT, IFRAME, NOSCRIPT, STYLE, SCRIPT, TEMPLATE, TEXTAREA, HEAD, and others. `<pre>` is not excluded.
- **Attributes**: `title`, `aria-label`/`aria-description`/`aria-placeholder`/…, `alt` (img/area/input), `placeholder` (input/textarea), `label` (option/track), `value` (only input type button/reset, never submit), meta description/keywords `content`.
- **Priority**: four `IntersectionObserver`s, split into content vs attributes and in-viewport vs beyond.
  - In-viewport roots use `rootMargin: "0%"`.
  - Beyond-viewport roots use `"150% 50% 150% 50%"` for content and `"100% 50% 100% 50%"` for attributes.
  - Nodes queue by priority: visible content, then near content, then attributes. A scheduler paces requests to engine throughput.
- **Cancellation**: requests are cancelled when the page is hidden, when the user scrolls far, when a node's viewport context changes, or when a node mutates.
- **Mutations**:
  - One `MutationObserver` watches `childList`, `characterData`, and a filtered set of translatable attributes.
  - It batches mutated nodes into a **double requestAnimationFrame**.
  - It pauses the observer while writing translations, so its own writes are ignored. Profiled cost: stop about 5 µs, start about 30 µs.
- **DOM writes**: batched every `DOM_UPDATE_INTERVAL_MS = 25`.
- **Cache**: source to target, keyed separately for text and HTML. It also tracks a set of already-translated outputs, so a mutation that writes back translated text is not re-translated.
- **Shadow DOM**: shadow roots are observed as extra roots and subdivided recursively.
- **Show original**: Firefox restores by reload, not by an in-memory revert.

## 4. Pitfalls

- **Opt-outs**: honor `translate="no"` (an HTML global attribute, inherited) and the `notranslate` class (a Google convention). [MDN translate](https://developer.mozilla.org/en-US/docs/Web/HTML/Global_attributes/translate), [Firefox exclusion list](https://github.com/mozilla-firefox/firefox/blob/main/toolkit/components/translations/content/translations-document.sys.mjs)
- **Skip**: `script`, `style`, `noscript`, `template`, `code`, `kbd`, `samp`, `var`, `textarea`, `input` values, `contenteditable` areas, `svg metadata`, `math`. `<pre>` is a judgment call: skip `pre > code` and translate prose `pre`.
- **Attributes worth translating**: `placeholder`, `title`, `alt`, `aria-label`, button-type `value`. Never translate `value` on submit inputs or on text inputs (user data).
- **Shadow DOM**: open shadow roots are reachable through `element.shadowRoot`. Closed shadow roots are not reachable from page JS. Observe each open root with its own MutationObserver.
- **iframes**: a `WKUserScript` with `forMainFrameOnly: false` runs in every frame, including cross-origin frames. Each frame must translate itself and report to native through its frame-scoped message handler.
- **React/Vue hydration and reconciliation**: frameworks hold references to the text nodes they created. Replacing those nodes breaks reconciliation, and wrapping them (as Google does with `<font>`) breaks it too. The result is "Failed to execute 'removeChild' on 'Node': The node to be removed is not a child of this node." React closed the issue as unfixable on their side and suggested `translate="no"` on roots. [react#11538](https://github.com/facebook/react/issues/11538)
  - **Mitigation**: never replace or wrap text nodes. Set `textNode.nodeValue` on the existing nodes. React then sees the same node and simply overwrites the text on its next render. Then detect re-render (the `characterData` mutation) and re-translate.
  - Firefox's innerHTML-merge keeps element identity, but it can still move nodes. Pure `nodeValue` swaps are the safest choice for framework pages.
  - Hydration: translating before hydration finishes can cause text-mismatch warnings or re-renders. Start after `DOMContentLoaded` plus idle time, and rely on the MutationObserver for anything the framework rewrites.
- **Revert**: keep a `WeakMap<Text, original>` and a `WeakMap<Element, Map<attr, original>>`. "Show Original" restores in place. Pages that mutated meanwhile keep their new text.

## 5. Performance guidance

- **Visible first**: translate blocks intersecting the viewport first, then pre-translate near-viewport blocks (Firefox prefetches 1.5 viewport heights above and below). [Firefox source](https://github.com/mozilla-firefox/firefox/blob/main/toolkit/components/translations/content/translations-document.sys.mjs)
- **Batching**:
  - Apple publishes no limits. Start at about 20–50 requests and under about 4 KB of source text per batch.
  - Stream with `translate(batch:)` so the first results paint early.
  - Tune on a real device (the simulator has no translation).
- **Units**: one request per block. A block is the text nodes of one paragraph joined with a delimiter, or each text node alone. Do not send a whole page: whole-page requests add latency and weaken streaming.
- **Bridge**: send units to native in chunks of `postMessage` calls through `WKScriptMessageHandlerWithReply`. Apply results in JS in batches every 16–25 ms, inside `requestAnimationFrame`.
- **MutationObserver**: coalesce records to the next double rAF or about 100 ms. Disconnect or ignore while applying your own writes, and dedupe through a source-to-translation cache. [Firefox source](https://github.com/mozilla-firefox/firefox/blob/main/toolkit/components/translations/content/translations-document.sys.mjs)
- **Cache**: keep a per-tab `[source: translation]` map. It makes infinite-scroll repeats and re-renders free.
- **Cancel**: on navigation or a tab switch, call `session.cancel()` (iOS 26). After cancelling, create a new session.

## Recommendation for Plain

1. **Session**: use `TranslationSession(installedSource: src, target: dst)` (iOS 26.0) for all real translation work. It is UI-free, works from a UIKit controller, and needs no SwiftUI lifetime coupling. Create one per tab per language pair. Re-create it after `cancel()`.
2. **Gate**: before you offer or run translation, call `LanguageAvailability().status(from: src, to: dst)`. `.installed` means translate now. `.supported` means run the download step first. `.unsupported` means hide the menu item.
3. **Download step**: one tiny `UIHostingController` with an invisible SwiftUI view carrying `.translationTask(config) { try await $0.prepareTranslation() }`. Add it to the browser window only for the download, keep it stable until the call returns, then remove it. This is the only SwiftUI in the feature.
4. **Strategy**: `.lowLatency` by default. It is faster and predictable for whole pages. `.highFidelity` may be worth trying later behind a measurement, not a setting.
5. **Detection**: run `NLLanguageRecognizer` on about 2 KB of visible body text, with `<html lang>` as a hint. Accept the result only above about 0.6 confidence with a clear margin. Compare `languageCode` plus script against `Locale.preferredLanguages`. The target is the first preferred language that the pair supports.
6. **Extraction**: one injected JS module, in the spirit of Firefox's design (patterns only, no copied MPL code).
   - Walk block elements.
   - Collect **text nodes** per block, honoring the exclusion list, `translate="no"`, `.notranslate`, and open shadow roots.
   - Add a short attribute list: `placeholder`, `title`, `alt`, `aria-label`, button `value`.
7. **Write-back**: only `textNode.nodeValue = translated`, never innerHTML and never new nodes. This keeps React/Vue alive.
   - Per-node translation loses some cross-node context (inline links mid-sentence).
   - Fix that later by sending a block as delimiter-joined segments and splitting the result back, without moving to HTML.
8. **Order and pacing**: an IntersectionObserver queues visible blocks first, then blocks within 1.5 viewports. Native streams `translate(batch:)` responses keyed by `clientIdentifier`. JS applies them in rAF batches about every 25 ms.
9. **Dynamic content**: one MutationObserver on `childList`, `characterData`, and attributes, coalesced to a double rAF. Ignore your own writes through a written-value set. Re-translate only new or changed text, using a per-tab cache.
10. **Frames**: inject with `forMainFrameOnly: false`. Each frame translates its own content through the same handler. Cross-origin frames work because the script runs inside them.
11. **UI**: in the page menu, one item, "Translate to <Language>". Once the page is translated, it becomes "Show Original", which restores from a `WeakMap` in place, with no reload. A thin progress cue on the address bar is the only feedback while translating. Show at most one quiet, one-time hint the first time a foreign page loads (for example, the menu button pulses once). No banner and no per-site toggles.
12. **Errors**: `notInstalled` triggers the download step and one retry. `unsupported*` hides the item. `userCancelled` and `alreadyCancelled` fail silently. Anything else shows one inline "Couldn't translate" message and reverts.
