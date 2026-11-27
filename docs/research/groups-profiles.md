# Tab groups and profiles (research, 2026-11-27)

The question: what should Plain, a phone-first browser with tabs that archive themselves, offer
for keeping sets of tabs and logins apart? The answer: **profiles only, no tab groups.** A
profile is its own tabs, archive, history, favorites, and cookies and website data. It is
switched from the tab switcher. Private tabs stay a separate mode.

## What others do

### Safari (iOS 17 to 26)

- **Model:** two layers. Profiles hold their own favorites, history, tabs and tab groups, with
  separate cookies and website data. Tab groups sit inside a profile. Bookmarks and passwords
  are shared. ([Apple](https://support.apple.com/guide/iphone/create-multiple-safari-profiles-iphd27a9ff22/ios))
- **Create and delete:** in Settings > Apps > Safari, not in the browser. Deleting a profile
  erases its favorites, history and tab groups, closes its open sites, and warns "This action
  can't be undone".
- **Switch:** Tabs button > More > Profile; in iOS 26 a menu at the top of the tab view, and a
  swipe on the tab bar for groups. ([MacRumors](https://www.macrumors.com/guide/ios-26-safari-features/))
- **Confusing:** TidBITS found groups confusing on the iPhone because you forget to switch group
  before opening a tab ([TidBITS](https://tidbits.com/2021/09/23/hot-new-features-in-safari-in-ios-15-and-ipados-15/)).
  Switching reads as three levels: switcher, group menu, profile. Apple Community threads report
  groups and tabs that seem to vanish, for example a tab moved into a group by accident taking
  the others with it ([1](https://discussions.apple.com/thread/253737941),
  [2](https://discussions.apple.com/thread/256176055)). A MacRumors forum user never found a use
  for either ([thread](https://forums.macrumors.com/threads/ios-17-how-to-separate-your-browsing-habits-with-safari-profiles.2401018)).
- **Praised:** one profile per context (work, personal) by people who use them
  ([Podfeet](https://www.podfeet.com/blog/2024/11/tab-groups-profiles-safari/)).

### Arc and Arc Search

- **Arc (desktop):** a Space is a set of tabs, each Space is tied to one profile, and switching
  Space switches profile. Reviewers found Spaces versus Profiles unclear
  ([Arc help](https://resources.arc.net/hc/en-us/articles/19227964556183),
  [MPU forum](https://talk.macpowerusers.com/t/arc-browser-spaces-and-profiles/35872)).
- **Arc Search (iPhone):** no groups, spaces or profiles. An app-switcher-like tab switcher, and
  tabs archive after 12 hours to 30 days. MacStories made it the default browser and called the
  switcher "fast and fun to use" ([MacStories](https://www.macstories.net/reviews/arc-search-for-iphone/)).
- **Arc Sync (2024):** desktop Spaces show read-only on the phone; you swipe between them
  ([TidBITS](https://tidbits.com/2024/04/29/arc-search-iphone-app-now-syncs-arc-sidebar-tabs/)).

### Chrome (iOS)

- **Tab groups:** since Chrome 128 (September 2024): long-press a tab, Add Tab to New Group, with a
  name and color ([Google](https://blog.google/products/chrome/google-chrome-update-september-2024/)).
- **Profiles:** only a work/personal account switch (July 2025), aimed at managed accounts;
  people with two personal accounts still sign out and in
  ([MacRumors](https://www.macrumors.com/2025/07/21/chrome-ios-personal-work-account-swap/)).

### Others

- **Firefox iOS:** no groups, profiles or containers. Android got groups in July 2026; Mozilla
  calls them the most requested mobile feature of 2025, with no numbers
  ([Mozilla](https://blog.mozilla.org/en/firefox/tab-groups-android/)).
- **Brave iOS:** no groups ([forum](https://community.brave.app/t/support-for-tab-groups-ios-ipad-os/646458)).
- **Edge iOS:** one personal and one work profile.
- **Orion iOS:** no profiles; people ask for them to split work and personal
  ([feedback](https://orionfeedback.org/d/4313-profile-support-on-ios-and-ipados)).
- **DuckDuckGo:** no profiles; a Fire button wipes tabs and data, with "Fireproof" sites that keep
  their logins ([DuckDuckGo](https://duckduckgo.com/duckduckgo-help-pages/privacy/fire-tabs)).

## Do phone users want tab groups?

No reliable usage number exists; the one figure found (18% of Firefox "power users") has no
source. What there is points away from groups on a phone:

- Arc Search won reviewers over without them, and Firefox, Brave and Orion ship without them.
- The complaints about groups on the iPhone are about confusion and tabs that seem lost, not
  about missing features.
- Plain's tabs archive themselves after a day by default, so the list stays short: there is
  little left to sort.

What people do ask for is the thing groups can't give: two logins to the same site (work and
personal mail) and history that stays apart. Only profiles do that.

## WebKit facts

- `WKWebsiteDataStore(forIdentifier: UUID)` (iOS 17) makes a persistent store with that
  identifier, or opens it. Set it on the configuration before the web view is made.
  ([Apple](https://developer.apple.com/documentation/webkit/wkwebsitedatastore),
  [WebKit blog](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/))
- `WKWebsiteDataStore.remove(forIdentifier:)` deletes it and its data. It fails while a web view
  still uses the store: "Release any WKWebView instances using the data store before you call
  this method." `allDataStoreIdentifiers` lists the stores on disk.
- The default store and `.nonPersistent()` stores have no identifier.
- WebKit keeps only website data apart per store (cookies, storage, caches, service workers).
  History, favorites and site settings are the app's to split.
- A popup must use the configuration WebKit hands to `createWebViewWith`, which carries the
  opener's store, so a link or popup stays in its tab's profile.

## Decision

1. **No tab groups.** Auto-archive keeps the list short, groups are where Safari's iPhone
   confusion comes from, and they would add a second level to the switcher.
2. **Profiles as the one container**, like Arc's Spaces with their profile folded in: each has
   its own open tabs, archive, history, favorites, typed-input learning, and its own website data
   store. Settings, per-site choices, downloads and private tabs belong to the app.
3. **Switched from the tab switcher.** A capsule over the cards names the profile shown, with a
   menu of profiles. It appears only with a second profile; until then New Profile waits in the
   gallery's More menu. Making, renaming and deleting are in the same menu, not in Settings
   (Safari's Settings detour is extra friction).
4. **Private is a mode, not a profile.** One private list and one in-memory store, whatever the
   profile.
5. **Deleting asks once and says what goes**: open tabs (counted), archived tabs, history,
   favorites, and the logins and data sites kept. Then the tabs close, the profile's history
   database and its website data store are deleted; a store WebKit can't remove yet is retried
   at the next launch.
