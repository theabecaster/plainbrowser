# Browse for Me and Summarize Page: research

Scope: on-device summaries for Plain (iOS 27.2, Swift 6) with Apple's Foundation Models framework.
Browse for Me reads a search's top results in hidden views and writes one answer with citations;
Summarize Page does the same for the page on screen. Checked 2026-11-27 against the iOS 27.2 SDK in
Xcode 27.2 (`FoundationModels.swiftinterface`) and the sources below.

## Arc Search's Browse for Me

- **Status:** The Browser Company turned Browse for Me and Arc's other mobile AI features off on
  2026-11-23. Arc itself shuts down on 2026-12-22, and Arc Search stays as a "lite" browser.
  Only docs and reviews remain to study. [arc.net](https://arc.net/)
- **Entry:** a "Browse for Me" button next to the query and each suggestion as you type. It was
  there even with Google as the engine.
  [MacStories](https://www.macstories.net/reviews/arc-search-for-iphone/) ·
  [Android Authority](https://www.androidauthority.com/arc-search-browser-3488152/) ·
  [TapSmart](https://www.tapsmart.com/apps/deep-dive-arc-search/)
- **While it works:** it names the sites it reads ("six pages… from Twitter to The Guardian").
  This took a few seconds; one 2026 review saw 10 pages.
  [9to5Mac](https://9to5mac.com/2024/01/29/arc-search/) ·
  [Android Police](https://www.androidpolice.com/arc-search-browser-chrome-alternative/)
- **Result page:**
  - A title, then bullets with bold lead-ins.
  - "More information" subheadings.
  - Key sources at the top and a full list lower down.
  - An image or video carousel.
  - A "Dive Deeper" list of links.
  - Sources open in separate tabs.
  - No review describes inline numbered citations.
  - [Allthings.how](https://allthings.how/using-browse-for-me-in-arc-search/) ·
    [TechCrunch](https://techcrunch.com/2024/01/28/arcs-new-iphone-browser-wants-to-be-your-search-companion)
- **Reviews:**
  - Praised: fast, uncluttered, and good for current events.
  - Criticized for accuracy: it mixed facts and errors "so you can't trust it without checking
    its sources", and its choice of sources looked random (9to5Mac). It also struggled to rank
    what matters most (Android Authority).
  - Pinch to Summarize was "clever but often miss[es] the mark".
    [TechCrunch](https://techcrunch.com/2024/02/23/arc-browsers-new-ai-powered-pinch-to-summarize-feature-is-clever-but-often-miss-the-mark/)
- **Publishers:** they objected that Arc read their pages and blocked their ads, which "completely
  upends the economics of publishing" (Arc's CEO). Users picked Browse for Me for about 32% of
  mobile queries.
  [Engadget](https://www.engadget.com/who-makes-money-when-ai-reads-the-internet-for-us-200246690.html)

**What Plain takes:**
- The entry next to the query.
- The honest progress line: which sites, which were skipped.
- Headings with short bullets.
- Sources at the end, opening in new tabs.

**What Plain adds:**
- Every point cites the numbered sources it came from. This answers the accuracy criticism: each
  claim can be checked in one tap.
- The summary is written on the phone, with no server at all.

**What Plain leaves out:**
- The image carousel: it costs time and memory, and hidden pages load without images' scripts.
- Follow-up questions.
- Emoji.

## Foundation Models facts used

From the iOS 27.2 SDK interface unless linked.

- **On device only.** `SystemLanguageModel.default` runs on the phone.
  `PrivateCloudComputeLanguageModel` is new in iOS 27, has a 32K context and needs an
  entitlement. Plain never uses it (`FixedChoices.summariesOnDeviceOnly`).
- **Availability.** `SystemLanguageModel.availability` is `.available` or `.unavailable(reason)`,
  with reason `.deviceNotEligible`, `.appleIntelligenceNotEnabled` or `.modelNotReady`.
  `supportsLocale(_:)` checks the language.
  - Apple's guidance: `.modelNotReady` usually means the model is still downloading, often after
    an OS update. In iOS 27, Apple Intelligence is on by default.
  - [Detecting available models](https://developer.apple.com/documentation/foundationmodels/detecting-available-apple-foundation-models)
- **Models.**
  - iOS 27 ships AFM 3 Core (3B, 4 to 8K context) and AFM 3 Core Advanced (20B sparse, 8K
    context). `SystemLanguageModel.variant` (`.core3`, `.coreAdvanced3`) says which one a phone has.
  - Each device has one variant, and the app can't pick it. iPhone Duo runs Core Advanced.
  - [AFM 3](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models)
- **Context.**
  - `contextSize` replaces the fixed 4096. It is back-deployed to 26.4 and returns 4096 before
    iOS 27. Apple says it can vary even within one variant, so it is read at run time.
  - Measured on this Mac (macOS 27.2): 8192. The WWDC26 sample also prints 8192.
  - `tokenCount(for:)` (26.4+) counts a prompt, instructions or a schema.
  - Everything counts toward the context: instructions, prompt, the `Generable` schema (included
    in the prompt by default) and the answer. A token is about 3 to 4 Latin characters, or about 1
    CJK character.
  - [TN3193](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window) ·
    [WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241)
- **Streaming.**
  - `streamResponse(to:generating:options:)` yields snapshots, not deltas. Each snapshot is the
    whole `PartiallyGenerated` value so far, with every property optional.
  - Properties generate in the order they are declared, which shapes both the animation and the
    quality. [WWDC25 286](https://developer.apple.com/videos/play/wwdc2025/286/)
- **Guided generation.**
  - `@Generable` with `@Guide(description:, .count(1...4))` caps an array's size.
  - Keep property names short, and add guides only where needed: the schema is in the prompt.
  - `maximumResponseTokens` is a runaway guard only; a tight cap produces broken output.
- **Prewarm.** `LanguageModelSession.prewarm(promptPrefix:)` loads the model and its instructions.
  Call it with at least a second of lead time. It is not guaranteed under load.
  [prewarm](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm(promptprefix:))
- **Errors.**
  - iOS 27 deprecates `LanguageModelSession.GenerationError` and splits it three ways:
    - `LanguageModelError`: `contextSizeExceeded`, `rateLimited`, `guardrailViolation`, `refusal`,
      `unsupportedLanguageOrLocale`, `timeout`, and others.
    - `SystemLanguageModel.Error.assetsUnavailable`.
    - `LanguageModelSession.Error`: `concurrentRequests`, `transcriptMutationWhileResponding`.
  - `rateLimited` fires only for an app over its limit in the background. The OS may delay
    concurrent requests without an error.
    [Forum](https://developer.apple.com/forums/thread/833642)
- **Guardrails.** `SystemLanguageModel(useCase:guardrails:)` takes
  `.permissiveContentTransformations` for transforming content the user supplied. Summaries of
  pages the user asked for are that case, so news about a war or an illness is not refused.
- **Prompt safety.** Instructions outrank the prompt, and untrusted content such as web pages
  must never go in the instructions.
  [WWDC25 248](https://developer.apple.com/videos/play/wwdc2025/248/)
- **Strengths.** The model is built for summarization, extraction and classification. It is not
  built for world knowledge or reasoning, and it hallucinates without facts in the prompt
  (WWDC25 286, 248). Browse for Me gives it the facts, the sources' text.
- **Long text.** Apple's recipe (TN3193) is to summarize chunks in new sessions and carry the
  summary forward. That costs one model pass per chunk before the first words show.
- **Speed.** Apple published no numbers for AFM 3. The 2024 model on iPhone 15 Pro ran about
  0.6 ms per prompt token before the first output token, then about 30 tokens/s.
  [Apple ML](https://machinelearning.apple.com/research/introducing-apple-foundation-models)
  - Measured on this Mac (M4 Max, loaded): a one-sentence answer took about 4 s, model start
    included.
- **Measured in Plain (simulator, the Mac's model, machine load 500+):**
  - Summarize Page on a 12-paragraph article: tap to first words on screen
    (`summary.firstWords`) 1.62 s average over 5 runs, 1% spread (`PerfTests/testSummaryStart`).
  - Browse for Me, live web ("how do ocean tides work", DuckDuckGo lite): 5 of 5 sources read,
    and the full answer written with citations, in about 25 s.
- **Simulator.** The iOS Simulator runs the host Mac's model when the Mac has Apple Intelligence
  on. Its variant can differ from the Duo's. Apple says to test on a device.
  [Forum](https://developer.apple.com/forums/thread/787199)

## Results pages (no API key)

- **DuckDuckGo lite** (`https://lite.duckduckgo.com/lite/?q=`): plain HTML, fetched 2026-11-27.
  - Results are `a.result-link`, with plain destination links. Older pages used
    `duckduckgo.com/l/?uddg=` redirects; Plain still unwraps them.
  - Sponsored rows are `tr.result-sponsored`, and ad links go through `duckduckgo.com/y.js`.
  - Fast repeated requests get a challenge page (`form#challenge-form`, `anomaly.js`).
  - Selectors are from [ddgs](https://github.com/deedy5/ddgs) and
    [SearchAI](https://github.com/jpjacobpadilla/SearchAI).
- **Google:**
  - It requires JavaScript (since 2025-01). In a hidden view it still showed only its "turn on
    JavaScript" page (measured 2026-11-27), so Plain doesn't read it.
  - Results are links holding an `h3` inside `#search` / `#rso`; ads sit in `#tads`, `#tadsb` and
    `[data-text-ad]`.
  - `/url?q=` redirects appear on the basic page; a captcha goes to `/sorry/`.
  - Sources: [openserp](https://github.com/karust/openserp), [SearXNG](https://github.com/searxng/searxng).
- **Bing:**
  - Results are `#b_results > li.b_algo h2 a`, and ads are `li.b_ad`.
  - Ad links start with `bing.com/aclick`.
  - `bing.com/ck/a?…&u=a1<base64url>` links are redirects: drop the leading `a1` and decode the rest.
- **Brave:** results are `div.snippet[data-type="web"]`, with the link around `.title`. Other
  `data-type`s are news, video and answers.

## Decisions for Plain

- **Entry, Browse for Me:** a row right above the search field, under the suggestions and apart
  from them, where Arc put its button beside Go. Its place is kept from the moment the field opens,
  so the suggestions never move: the row fades in while the text would search, and out while it
  is an address. It is not offered without the model.
- **Entry, Summarize Page:** in the page menu's captioned row with Find and Reader ("Summarize"),
  only on pages Reader can read (an article) or in the reader. Safari also offers Summarize only
  on pages that support it.
- **Without the model:** the entries are left out, with no explanation, in every case:
  - an ineligible phone, where they could never work;
  - Apple Intelligence off, which iOS 27 has on by default, so turning it off was a choice;
  - the model not ready, where they appear by themselves once it is.
  The answer is read again whenever Plain becomes active.
  A one-time explanation would need a place to show, and every place would be a button that
  can't work (state rules, principle 1).
- **Results source:** the user's engine when its page parses in a hidden view, then DuckDuckGo
  lite. Checked live on 2026-11-27 (simulator, a hidden view with JavaScript on):
  - **Bing:** 8 organic links (`li.b_algo a:has(h2)`; the `h2` sits inside the link).
  - **Google:** the "turn on JavaScript" page and an empty body, even after the load event, so
    Google users get lite.
  - **Brave:** 20 web results, but every link was an encrypted `search.brave.com/go/v1#…`
    redirect, so Brave users get lite.
  - **DuckDuckGo lite:** 8 links, 7 sites after the filters.
  - Everyone else (DuckDuckGo, Perplexity, ChatGPT, Kagi without a login, custom engines) goes
    straight to lite. See docs/decisions.md.
- **Organic results:**
  - Ads and ad redirects are skipped, and so are the engine's own pages.
  - Sites without article text are skipped: video, social, login walls.
  - One page per site.
  - The first five are read, and up to eight are kept so a failed page is replaced while the
    budget lasts.
- **Hidden views:**
  - The pool makes and owns them, one non-persistent store per run, so they are never tabs or
    history.
  - They get Plain's content blocking.
  - Sources load with their JavaScript off: the text is in the HTML, the page's trackers never
    run, and each view is lighter. Reader runs in its own world either way.
  - Results pages that build their list with script keep JavaScript on.
  - Frames, media, popups and downloads are refused.
  - Each view is released as soon as its text is read.
- **Time budget:**
  - The results page gets 4 s, then the next engine.
  - The sources are read in parallel for 7 s.
  - With nothing read by then, the first page within 3 more seconds is enough.
- **Fitting the context:**
  - Reserve the instructions and schema (700 tokens) and the answer (800).
  - Split the rest between the sources at 3 characters a token. A short page gives its unused
    share to the long ones (water-filling).
  - Then count the real prompt with `tokenCount(for:)` and shrink once if it is over.
  - A context error retries once with half the room.
  - Summarize Page condenses a long page to one pass: the opening (60%) plus paragraphs spread
    over the rest. Apple's chunked recipe would delay the first words by one model pass per chunk.
- **Answer shape:** `sections` (1 to 4), each with a `heading` and `points` (1 to 4). No
  generated title: the search or the page's title is the headline, and the first bullet comes
  sooner without one (design review, 2026-11-27).
  Each point is `text` then `sources` (numbers).
  - Citations are cleaned: numbers outside the sources and repeats are dropped, and a page's own
    summary cites nothing.
  - Greedy sampling, so the same pages give the same summary.
- **Streaming on screen:**
  - A new stage, source state, section or point shows at once, with the snappy fade.
  - Words growing inside a point redraw at most every 66 ms.
  - Nothing slides, and the text never re-lays out from the top.
- **Prompt safety:** the instructions are fixed. The pages go only in the prompt, fenced, and the
  instructions say text inside a source is material, never orders.
- **Prewarm:** the session for the kind of summary is made and prewarmed on the tap. For Browse
  for Me the model then loads while the pages are fetched (several seconds of lead).
