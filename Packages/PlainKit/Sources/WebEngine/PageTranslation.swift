#if canImport(UIKit)
import BrowserCore
import Foundation
import WebKit

/// What translation is doing on a tab's page (`Tab.translation`). The page menu offers "Translate
/// Page" on `.original` (when the page is in a language the user doesn't read) and "Show Original"
/// otherwise (docs/state-rules.md, section 4).
public enum TranslationState: Sendable, Equatable {
    /// As the site wrote it.
    case original
    /// Asked for; the first translated text is on its way (a language may be downloading).
    case translating
    /// Translated text is on screen, and text the page adds is translated as it arrives.
    case translated
}

/// The translation engine, provided by the shell (Apple's Translation framework on the device).
/// The engine finds the text and puts translations back; it never sees the framework.
public protocol PageTranslator: AnyObject {
    /// The language to translate a page in `language` into, or nil when the user reads it or the
    /// device can't translate it. Called once per page, off the critical path of the load.
    func target(for language: Locale.Language) async -> Locale.Language?
    /// Makes the pair ready, which may show the system's download sheet. False when the user
    /// declined or the download failed.
    func prepare(from source: Locale.Language, to target: Locale.Language) async -> Bool
    /// Translates `texts` in order. Throws when the pair can't be used (the page goes back to
    /// its original text).
    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String]
}

/// Translate Page (docs/research/translate.md): the page's own text nodes are translated in place,
/// on the device, and put back exactly as they were by Show Original.
///
/// Two scripts, both in their own content world (the page can't see or undo them):
/// - **Language check** (every page, main frame, at document end): reports `<html lang>` and a
///   sample of the visible text (`FixedChoices.translateSampleLength`), once. The app recognizes
///   the language off the main thread (`PageLanguage`).
/// - **Translator** (only on a page the user translates, injected then): collects the page's text
///   nodes, skipping code, form fields, `translate="no"` and `.notranslate`. Text near the screen
///   goes first, in batches (`FixedChoices.translateBatchCharacters`); the rest is translated as it
///   scrolls near (an `IntersectionObserver`), so a long page costs only what is read. Each
///   translation is written to the same text node's `nodeValue`, never as new nodes or HTML, so
///   layout, links, styles and frameworks that hold those nodes (React, Vue) keep working. A
///   `MutationObserver` (throttled to `FixedChoices.translateMutationDelay`) translates text the
///   page adds or changes; its own writes are recognized and skipped. Show Original writes every
///   original back where the page has not changed it since.
enum PageTranslation {
    static let world = WKContentWorld.world(name: "PlainTranslate")
    /// The one message handler, with replies (the translator awaits each batch).
    static let handlerName = "plainTranslate"

    static let languageScript = WKUserScript(
        source: languageSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world
    )

    static let languageSource = """
        (() => {
          if (window !== window.top || !/^https?:$/.test(location.protocol)) return;
          const h = globalThis.webkit && webkit.messageHandlers && webkit.messageHandlers.\(handlerName);
          if (!h) return;
          const SKIP = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|CODE|PRE|TEXTAREA|SVG|MATH)$/;
          const sample = () => {
            const root = document.body || document.documentElement;
            if (!root) return '';
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode: (n) =>
              n.parentElement && SKIP.test(n.parentElement.tagName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT });
            let text = '';
            while (text.length < \(FixedChoices.translateSampleLength) && walker.nextNode()) {
              const t = walker.currentNode.nodeValue.trim();
              if (t.length > 1) text += t + ' ';
            }
            return text.slice(0, \(FixedChoices.translateSampleLength));
          };
          const report = (text) => h.postMessage({ type: 'language', lang: document.documentElement.lang || '', sample: text }).catch(() => {});
          // A page shown again from the back-forward cache commits as a new page: its translation
          // (if any) is undone and its language reported again.
          addEventListener('pageshow', (event) => {
            if (!event.persisted) return;
            if (globalThis.__plainTranslate) globalThis.__plainTranslate.restore();
            report(sample());
          });
          const first = sample();
          // A page that builds its text with script has little at document end: wait for load.
          if (first.length >= \(FixedChoices.translateSampleLength / 4) || document.readyState === 'complete') report(first);
          else addEventListener('load', () => report(sample()), { once: true });
        })();
        """

    /// Starts translating the page (the translator is injected first, once per document).
    static let startSource = "globalThis.__plainTranslate.start();"
    /// Puts the original text back and stops watching the page.
    static let restoreSource = "globalThis.__plainTranslate && globalThis.__plainTranslate.restore();"

    static let translatorSource = """
        (() => {
          if (globalThis.__plainTranslate) return;
          const h = webkit.messageHandlers.\(handlerName);
          const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','CODE','PRE','KBD','SAMP','VAR','TEXTAREA',
            'INPUT','SELECT','OPTION','SVG','MATH','CANVAS','IFRAME','OBJECT','EMBED','VIDEO','AUDIO']);
          const BATCH_CHARS = \(FixedChoices.translateBatchCharacters);
          const BATCH_COUNT = \(FixedChoices.translateBatchCount);
          const IN_FLIGHT = \(FixedChoices.translateBatchesInFlight);
          const MUTATION_DELAY = \(FixedChoices.translateMutationDelay);
          const LETTER = /\\p{L}/u;
          // Translations by original text, for this document: a repeated label or a second
          // Translate after Show Original costs nothing.
          const cache = new Map();
          let active = false, reported = false, failed = false;
          let originals = new Map();   // text node -> its text before Plain touched it
          let written = new Map();     // text node -> the text Plain wrote (to tell our writes apart)
          let waiting = new Map();     // element on watch -> its text nodes, until it nears the screen
          let queue = [];              // text nodes ready to translate, nearest the screen first
          let queued = new Set();
          let inFlight = 0, flushScheduled = false, mutationTimer = 0, records = [];
          let visible, mutations;

          const skipElement = (el) => SKIP.has(el.tagName) || el.isContentEditable ||
            el.getAttribute('translate') === 'no' || (el.classList && el.classList.contains('notranslate'));

          const collect = (root) => {
            if (root.nodeType === Node.TEXT_NODE) return consider(root);
            if (root.nodeType !== Node.ELEMENT_NODE) return;
            for (let el = root; el; el = el.parentElement) if (skipElement(el)) return;
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, { acceptNode: (n) =>
              n.nodeType === Node.ELEMENT_NODE && skipElement(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT });
            for (let n = walker.currentNode; n; n = walker.nextNode()) {
              if (n.nodeType === Node.TEXT_NODE) consider(n);
            }
          };

          const consider = (node) => {
            const text = node.nodeValue;
            if (!text || !LETTER.test(text) || written.get(node) === text || queued.has(node)) return;
            const parent = node.parentElement;
            if (!parent) return;
            let nodes = waiting.get(parent);
            if (!nodes) { nodes = []; waiting.set(parent, nodes); visible.observe(parent); }
            nodes.push(node);
          };

          const nearScreen = (entries) => {
            for (const entry of entries) {
              if (!entry.isIntersecting) continue;
              const nodes = waiting.get(entry.target) || [];
              waiting.delete(entry.target);
              visible.unobserve(entry.target);
              for (const node of nodes) if (!queued.has(node)) { queued.add(node); queue.push(node); }
            }
            scheduleFlush();
          };

          const scheduleFlush = () => {
            if (flushScheduled || !active) return;
            flushScheduled = true;
            setTimeout(() => { flushScheduled = false; flush(); }, 0);
          };

          const apply = (node, original, translated) => {
            if (!active || !node.isConnected || node.nodeValue !== original) return;
            const lead = original.match(/^\\s*/)[0], trail = original.match(/\\s*$/)[0];
            const value = lead + translated.trim() + trail;
            if (!originals.has(node)) originals.set(node, original);
            written.set(node, value);
            node.nodeValue = value;
          };

          const report = (type) => h.postMessage({ type }).catch(() => {});

          const flush = () => {
            while (active && inFlight < IN_FLIGHT && queue.length > 0) {
              const batch = [], texts = [];
              let chars = 0;
              while (queue.length > 0 && batch.length < BATCH_COUNT && chars < BATCH_CHARS) {
                const node = queue.shift();
                queued.delete(node);
                const original = node.nodeValue;
                if (!node.isConnected || !original || written.get(node) === original) continue;
                const key = original.trim();
                if (cache.has(key)) { apply(node, original, cache.get(key)); continue; }
                batch.push([node, original, key]);
                texts.push(key);
                chars += key.length;
              }
              if (batch.length === 0) { if (!reported && originals.size > 0) { reported = true; report('translated'); } continue; }
              inFlight++;
              h.postMessage({ type: 'translate', texts }).then((translations) => {
                if (!active) return;
                if (!Array.isArray(translations) || translations.length !== batch.length) return fail();
                batch.forEach(([node, original, key], i) => {
                  cache.set(key, translations[i]);
                  apply(node, original, translations[i]);
                });
                if (!reported) { reported = true; report('translated'); }
              }, fail).finally(() => { inFlight--; scheduleFlush(); });
            }
          };

          // A batch that can't be translated puts the whole page back: half a translation is
          // worse than none.
          const fail = () => {
            if (!active || failed) return;
            failed = true;
            restore();
            report('failed');
          };

          const onMutations = (list) => {
            records.push(...list);
            if (mutationTimer) return;
            mutationTimer = setTimeout(() => {
              mutationTimer = 0;
              const pending = records; records = [];
              for (const record of pending) {
                if (record.type === 'characterData') {
                  const node = record.target;
                  if (written.get(node) === node.nodeValue) continue;
                  // The page changed text Plain had translated: its new text is the original now.
                  originals.delete(node); written.delete(node);
                  consider(node);
                } else {
                  for (const node of record.addedNodes) collect(node);
                }
              }
            }, MUTATION_DELAY);
          };

          const start = () => {
            if (active) return;
            active = true; reported = false; failed = false;
            visible = new IntersectionObserver(nearScreen, { rootMargin: '\(FixedChoices.translateLookahead) 0px' });
            mutations = new MutationObserver(onMutations);
            mutations.observe(document.body || document.documentElement, { childList: true, characterData: true, subtree: true });
            collect(document.body || document.documentElement);
            if (waiting.size === 0) report('translated');
          };

          const restore = () => {
            active = false;
            if (visible) visible.disconnect();
            if (mutations) mutations.disconnect();
            clearTimeout(mutationTimer); mutationTimer = 0; records = [];
            for (const [node, original] of originals) {
              if (node.nodeValue === written.get(node)) node.nodeValue = original;
            }
            originals = new Map(); written = new Map(); waiting = new Map(); queue = []; queued = new Set();
          };

          globalThis.__plainTranslate = { start, restore };
        })();
        """
}
#endif
