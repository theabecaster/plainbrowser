# Safari on iPhone Duo: layout research

Researched 2026-11-27. Web sources only. No device was used.

Labels: **[S]** Sourced (URL in Sources). **[I]** Inferred (basis given). **[U]** Unverified.

## Bottom line

- Little Duo-specific Safari detail exists. No review measures Safari's inner-screen chrome or shows it in detail.
- The best hard data is WebKit's viewport table for Safari 27.1 (CSS px; 1 CSS px = 1 pt at default zoom on iOS [I]).
  All chrome sizes below come from subtracting those numbers from the screen sizes.
- Inner screen: Safari puts its tab/address bar **at the top, like iPad or Mac**, in both orientations [S1].
  The viewport is the full screen width (951 / 669) [S1]. So Safari does **not** use the ~84 pt side column on the inner screen [I].
- Outer screen and Split View: Safari uses the 84 pt trailing side column, with the tab bar at the bottom by default [S1, I].
- iOS 27.3 (beta, public release expected December) adds Vertical Tabs: a left-edge strip, icons by default, resizable to show titles [S3, S4, S5].

## Viewport data (WebKit, Safari 27.1) [S1]

SVH = page height with full chrome. LVH = page height with chrome collapsed after scrolling.

| Pose | Viewport W | SVH | LVH |
|---|---|---|---|
| Outer, portrait | 382 | 580 | 618 |
| Outer, landscape | 594 | 368 | 406 |
| Inner, portrait, one window | 669 | 867 | 902 |
| Inner, landscape, one window | 951 | 585 | 620 |
| Inner, two windows side by side (each) | 385 | 571 | 609 |

## Chrome sizes and page area

Screen sizes from the brief: outer 466x678 pt, inner 951x669 pt (landscape).
Page area % = viewport area / screen area. All rows are [I], arithmetic from [S1].

| State | Side chrome (W) | Vertical chrome, full / collapsed | Page area, full / collapsed |
|---|---|---|---|
| Inner landscape | 951-951 = 0 | 669-585 = 84 / 669-620 = 49 | 87.4% / 92.7% |
| Inner portrait | 669-669 = 0 | 951-867 = 84 / 951-902 = 49 | 91.2% / 94.8% |
| Outer portrait | 466-382 = 84 | 678-580 = 98 / 678-618 = 60 | 70.1% / 74.7% |
| Outer landscape | 678-594 = 84 | 466-368 = 98 / 466-406 = 60 | 69.2% / 76.3% |
| Split View, 2 windows | 951-770 = 181 total | 669-571 = 98 / 669-609 = 60 | 69.1% / 73.7% (both panes) |

Arithmetic samples:
- Inner landscape full: 951x585 = 556,335 / 636,219 = 87.4%.
- Outer portrait full: 382x580 = 221,560 / 315,948 = 70.1%.
- Split: 2x385x571 = 439,670 / 636,219 = 69.1%.

Notes on these numbers:
- Vertical chrome totals include the status area and any home-indicator inset. The split between top and bottom is not published [U].
- Collapse saves 35 pt on the inner screen and 38 pt on the outer screen and in Split View (SVH to LVH) [S1, S2].
- The 84 pt outer side column matches the ~84 pt `verticalBarEdge` width in the brief [I].
- Split View: 181 pt non-page width = 2 x 84 pt side columns + ~13 pt for the divider [I]. HIG says each app puts controls on its outer edge [S6].
- Split View panes use the same vertical chrome as the outer screen (98 / 60). So each pane behaves like a compact (outer-style) Safari [I].

## Inner landscape (flat)

- Address/tab bar: top edge, "similar to iPad or Mac" [S1]. Full screen width [I, from 951 viewport].
- Exact bar layout (compact merged bar vs. separate tab bar row) is not published [U].
  One forum user describes Safari showing "tabs under the address bar when unfolded" [S9]. That suggests an iPad-style separate tab strip [I].
- Toolbar: no side column for Safari here [I]. This differs from the general HIG rule that apps keep side bars in inner landscape [S6].
- Chrome: 84 pt tall expanded, 49 pt collapsed [I]. Page area 87.4% / 92.7% [I].
- Scroll: the tab bar "shrinks when the user scrolls" [S1]. What stays visible in the collapsed 49 pt is not described [U]. On iPhone and iPad it is a slim URL pill [U for Duo].
- Split View: two Safari windows side by side, 50/50 [S1, S7, S11]. Each is 385 pt wide, a "narrow portrait viewport" [S1].
- Reviewer: inner-screen scrolling is "one of the best examples of something that's better on the inner screen" [S8].
- Reviewer: many sites still serve the mobile layout on the unfolded screen. He wants iPad-style desktop-class browsing [S8].
- Reviewer: Safari beside Notes in Split View is "a huge productivity boost" [S8].

## Inner portrait (669x951)

- Address/tab bar: top edge [S1]. Full width 669 [I].
- Horizontal bars are the system norm in this pose. It is the only pose without the side column [S6, S7, S10].
- Chrome: 84 pt expanded, 49 pt collapsed [I]. Page area 91.2% / 94.8%, the best of any state [I].
- Split View: not described for portrait [U].

## Partial fold (book pose)

- Safari shows PDFs as two side-by-side pages when partly folded. It returns to one page when flat or closed [S1, S11].
- Ordinary web pages: no published change. They keep the flat inner layout [I, from no mention in S1].
- System behavior (all apps): buttons and interactive elements move away from the fold. Scrollable content does not need to avoid it [S7].
  In portrait partial fold, interactive elements move to the bottom half [S7].
- Whether Safari's top bar moves in book pose is not published [U].
- Web devs can detect the fold: Device Posture API (`folded` / `continuous`) and Viewport Segments API, behind feature flags [S1].

## Outer screen (466x678)

- Controls: side column on the trailing edge, 84 pt wide [I, from 466-382 and 678-594]. Tab bar at the bottom of that column by default [S1].
- Web content does not extend behind the column. Safari fills it with the page's sampled background color [S1, S11].
- Page area 70.1% / 74.7% portrait, 69.2% / 76.3% landscape [I].
- Reviewers: the column "eats into the usable screen real estate in Safari especially" [S8]. Cookie banners can fill the screen [S8].
- Top-right corner is hard to reach one-handed [S8].
- Apple (Jen Simmons) is investigating letting pages go under the column, e.g. a full-width header background. No timeline [S1, S11, S12].
- Reader complaint with 31 votes: the side controls should minimize on scroll like the URL bar [S12].

## iOS 27.3 Vertical Tabs (beta)

- Tabs run down the **left** edge [S3, S4, S5]. Toggle: Settings > Apps > Safari > Vertical Tabs [S4].
- Default: icons only. Drag to widen and show titles [S3, S4, S5]. Widths not published [U].
- Works with Tab Groups and Topics. Drag to pin still works [S3, S13].
- Available on the Duo [S5]. Whether it shows on the outer screen, or only inner, is not published [U].
- Reviewer (gori.me): "incredibly useful" on the Duo, easier to scan than a horizontal row.
  Complaint: icon-only tabs are hard to tell apart [S13].
- Address bar position with Vertical Tabs: not published [U].

## iPad fallback evidence (iPad, not Duo)

- iPadOS 26.0 dropped the compact tab bar. iPadOS 26.4 restored it as an option; Separate Tab Bar is the default [S14, S15].
- Compact: address bar and current tab merge into one element at the top. Saves a few vertical points. Tab titles get short [S15].
- iPad sidebar can list all open tabs with long titles and close buttons ("faux vertical tabs"). It costs width [S15].
- iPad has "Hide Tab Bar While Scrolling" in Settings > Apps > Safari > Tabs [S14].
- iPhone iOS 26 offers Compact (default, bottom), Bottom, and Top tab layouts [S16]. Whether the Duo inner screen honors these is unknown.
  One forum report says the address bar cannot move to the bottom on the inner screen [U, S10b; page blocked, seen only in a search summary].

## Gestures

- No Duo-specific Safari gestures are published [U].
- Standard iPhone Safari: swipe the bottom bar to switch tabs. That gesture does not exist with a top bar [S17, iPhone not Duo].
- Split View: drag up from the bottom, pause, drag to an edge. Or long-press an icon > Open in Split View. Drag the divider to an edge to exit [S11].

## What makes it intuitive

1. One familiar model per screen: inner = iPad/Mac (top bar), outer = iPhone (bottom tab bar in a side column) [S1].
2. Chrome shrinks on scroll on every screen and gives back 35-38 pt [S1].
3. Inner screen gets the full width, no side column. Page area reaches 87-95% [I].
4. Content is never hidden under controls. Background color bleeds into the column so it feels continuous [S1].
5. Split View with two Safari windows is a 50/50 split with no setup [S1, S7, S8].
6. Book pose triggers two-page PDF reading. It is a small change, not a relayout [S1]. HIG warns against big relayouts on fold [S6].

## What is annoying

1. Outer screen loses 84 pt of width to controls. Page area is only ~70% [I]. Top reviewers and readers complain [S8, S12].
2. Side controls do not hide on scroll [S12].
3. Icon-only vertical tabs are hard to read [S13].
4. Sites serve mobile layouts on the inner screen [S8].
5. Possibly no bottom address bar option on the inner screen [U].

## Takeaways for Plain

1. Inner screen, both orientations: put the address bar at the top, full width, iPad-style. Do not use the 84 pt side column there. Safari does not [S1, I].
2. Target ~84 pt expanded and ~49 pt collapsed for total vertical chrome on the inner screen. That matches Safari's page area of 87% / 93% landscape [I].
3. Collapse chrome on scroll to a slim bar. Restore on scroll-up or a tap at the top [S1 for collapse; restore trigger U].
4. Offer a left icon strip for tabs (Vertical Tabs model): icons by default, drag to widen to titles [S3-S5].
   Fix Safari's flaw: show the title on hover/long-press or keep a minimum label width [I, from S13].
5. In Split View, assume a 385 pt pane with compact chrome. Reuse the outer-screen layout there [I].
6. Outer screen: follow `verticalBarEdge`. Beat Safari by letting the side column auto-hide on scroll. This is the top complaint [S12].
7. Book pose: change little. Keep bar positions; move tappable items off the crease [S6, S7].
8. Never cover page content with chrome. Extend the page background into unused chrome areas [S1].

## Sources

- S1 WebKit, "WebKit Features for Safari 27.1": https://webkit.org/blog/18486/webkit-features-for-safari-27-1/
- S2 PPC Land, viewport analysis: https://ppc.land/safari-27-1-on-iphone-duo-runs-web-pages-from-382-to-951-pixels-wide/
- S3 MacRumors, iOS 27.3 Safari: https://macrumors.com/2026/11/03/ios-27-3-safari
- S4 9to5Mac, iOS 27.3 vertical tabs: https://9to5mac.com/2026/11/03/ios-27-3-and-macos-27-3-add-vertical-tabs-adaptive-dark-mode-and-more-to-safari/
- S5 Macworld, vertical tabs: https://macworld.com/article/3273418/apple-finally-brings-vertical-tabs-to-safari-in-surprise-27-3-feature-drop.html
- S6 Apple HIG, Designing for iPhone Duo: https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
- S7 Apple Tech Talk 111466: https://developer.apple.com/videos/play/tech-talks/111466/
- S8 9to5Mac, iPhone Duo review: https://9to5mac.com/2026/10/21/iphone-duo-review/ and https://9to5mac.com/2026/10/23/apple-exploring-fix-for-safaris-cramped-layout-on-the-iphone-duos-outer-display/
- S9 MacRumors Forums, Halfsheet browser thread: https://forums.macrumors.com/threads/developer-halfsheet-browser-–-a-browser-built-for-the-iphone-duo.2494496/
- S10 Apple Developer Forums, inner portrait tab bar: https://developer.apple.com/forums/thread/846028 ; DuoApps bar rules: https://www.duoapps.com/patterns/where-the-bars-go/
- S10b MacRumors Forums, first impressions (HTTP 403, not read): https://forums.macrumors.com/threads/iphone-duo-is-here-first-impressions-and-photos-thread.2492438/page-16
- S11 Gadget Hacks, two Safari windows: https://apple.gadgethacks.com/news/how-to-open-two-safari-windows-side-by-side-on-iphone-duo/
- S12 MacRumors, Apple wants to fix Safari on Duo (incl. comments): https://macrumors.com/2026/10/25/apple-wants-to-fix-safari-on-iphone-duo
- S13 gori.me, vertical tabs on Duo (Japanese): https://gori.me/ios/ios-news/172043/
- S14 MacRumors, compact tab bar back on Mac and iPad: https://macrumors.com/how-to/safaris-compact-tab-bar-back-on-mac-and-ipad/
- S15 MacStories, compact tab bar and vertical tabs on iPad: https://www.macstories.net/notes/well-i-guess-i-like-safaris-compact-tab-bar-in-ipados-24-also-using-vertical-tabs-in-safari-for-ipad/
- S16 iDownloadBlog, iOS 26 three tab bar designs: https://www.idownloadblog.com/2025/06/12/ios-26-safari-tab-bar-designs/
- S17 MacRumors, top or bottom address bar: https://www.macrumors.com/how-to/use-original-safari-design-ios/
