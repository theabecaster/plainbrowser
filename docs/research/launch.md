# What a browser shows when it opens with tabs (2026-11-27)

The owner: "When I open Plain and I have tabs open, open to the last one, not a new-tab thing — or
maybe do that, but with the last tab in the back. See what Arc does and copy it, but make it nicer
and smoother." This note records what the reference browsers do on a cold launch and on a return
from the background when tabs exist, and the rule Plain takes from them.

Tags: **[C]** confirmed by a source, **[I]** inferred.

## Arc Search (iOS)

- **Cold launch with tabs:** a search sheet with the keyboard up, over the tabs. Reviewers: it
  opens to "a keyboard and search field, not your usual collection of tabs"; TidBITS: "a sheet with
  a search field and a few pinned or suggested sites". **[C]** [TechCrunch], [TidBITS]
- **Keyboard setting:** 1.13.0 (May 2024) added "Toggle Keyboard Visibility on App Launch"; 1.14.0
  says the auto-open keyboard applies "regardless of whether you have any tabs open". With it off,
  the keyboard does not come up on a relaunch, or "when reactivating the app with no open tabs".
  It lives under the tab switcher's gear. **[C]** [Arc release notes]
- **Return from the background:** the release note implies the search sheet also comes back on
  reactivation. No time threshold was found. **[I]**
- **Back to the last tab:** swipe the search sheet down; the tab is behind it. **[C]** [TidBITS]
- **Archive:** "Archive Inactive Tabs" after 12 hours, 1, 3, 7 or 30 days; 1 day by default.
  **[C]** [TechCrunch]
- Arc's AI features turned off on 2026-11-23; the app still works as a browser. **[C]**

## Safari (iOS)

- **Cold launch and return:** the last active tab, as it was. The start page shows only in a new
  tab: "When you open a new tab, you begin on your start page." **[C]** [Apple]
- No time-away rule. Settings > Safari > Close Tabs (Manually by default, or after a day, week or
  month) deletes tabs; it does not change what Safari opens to. **[C]** [MacRumors]

## Chrome (iOS)

- **Rule:** on each return to the foreground Chrome checks how long it was in the background (the
  time is saved, so a cold launch counts too). At **4 hours** or more it opens the New Tab Page (an
  existing one if there is one) and remembers the last tab; below that, the last tab as it was.
  **[C]** [Chromium `start_surface_scene_agent.mm`]
- **Exceptions:** nothing changes if the tab grid is showing or the tab on screen is already a New
  Tab Page. **[C]**
- **Threshold:** `GetReturnToHomeSurfaceDuration()` is `base::Hours(4)`; only a hidden developer
  switch changes it. A user setting ("Open a new tab when you return to Chrome after 4 hours")
  exists behind a flag that is off by default. **[C]** [Chromium `system_flags.mm`]
- **Back to the last tab:** a "Return to recent tab" tile on the New Tab Page with the tab's title
  and "· N h ago". **[C]** [Chromium `ios_strings.grd`]

## Firefox (iOS)

- **Setting "Opening Screen":** Homepage, Last tab, or Homepage after four hours of inactivity.
  Mozilla's help says the four-hour option is the default (the code's built-in default is last tab,
  likely switched remotely). Skipped when the app opens from a link. **[C]** [Mozilla],
  [firefox-ios `StartAtHomeHelper.swift`]

## The common pattern

1. Away a short time (under about 4 hours): the last tab, exactly as it was (Safari always; Chrome
   and Firefox below 4 hours).
2. Away long: a fresh start (search or a start page) with an obvious way back to the last tab,
   which is not closed. Chrome and Firefox both use 4 hours.
3. Arc Search is the outlier: always a search sheet over the last tab, swiped down to get back.
4. A link from another app always wins: it opens its page, never a start page (Firefox, Chrome).

## What Plain does (decided in docs/decisions.md, "Launch: the last tab first")

- **Tabs, away under 4 hours** (cold launch or return): the last tab, exactly where it was, the
  bar resting, no keyboard. On a cold launch its saved picture is on screen from the first frame
  and the live page takes over without a flash.
- **Tabs, away 4 hours or more:** Arc's search sheet over the last tab, the keyboard up, the tab
  visible behind it under a paper veil (70% paper, no blur). Swipe down or tap outside to get back to the tab. A search
  from there opens a new tab, so the old page stays as it was (Chrome's new tab, Arc's sheet).
- **No tabs:** search first with the keyboard up, as before.
- **A link from another app:** its page, as before.

The 4-hour line is Chrome's and Firefox's tested default, and it sits well inside Plain's
shortest auto-archive interval (12 hours), so a tab is never archived before the fresh search
could show over it.

## Sources

- [Arc release notes]: https://resources.arc.net/hc/en-us/articles/23528454620311-Arc-Search-for-iOS-Release-Notes
- [TidBITS]: https://tidbits.com/2024/04/29/arc-search-iphone-app-now-syncs-arc-sidebar-tabs/
- [TechCrunch]: https://techcrunch.com/2024/01/28/arcs-new-iphone-browser-wants-to-be-your-search-companion
- [Apple]: https://support.apple.com/guide/iphone/customize-your-safari-settings-iphb3100d149/ios
- [MacRumors]: https://www.macrumors.com/how-to/auto-close-old-safari-tabs-in-ios/
- [Chromium `start_surface_scene_agent.mm`]: https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/browser/start_surface/ui_bundled/start_surface_scene_agent.mm
- [Chromium `system_flags.mm`]: https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/browser/shared/public/features/system_flags.mm
- [Chromium `ios_strings.grd`]: https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/app/strings/ios_strings.grd
- [Mozilla]: https://support.mozilla.org/en-US/kb/choose-your-opening-screen-firefox-ios
- [firefox-ios `StartAtHomeHelper.swift`]: https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Client/Frontend/Browser/StartAtHome/StartAtHomeHelper.swift
