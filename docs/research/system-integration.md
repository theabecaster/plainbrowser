# System integration (v0.2): App Intents, Spotlight, widgets, controls, Handoff

Researched 2026-11-26 against Apple's documentation for iOS 26 and 27 and the WWDC 2024–2025
App Intents sessions. Verified facts first, then what Plain does with them.

## Verified API facts

**App Intents**

- `supportedModes: IntentModes` (iOS 26) replaces `openAppWhenRun`, which is deprecated.
  `.foreground` runs the intent with the app in front; `.foreground(.dynamic)` and
  `.foreground(.deferred)` start in the background and may come forward.
  ([IntentModes](https://developer.apple.com/documentation/appintents/intentmodes),
  [forum: openAppWhenRun deprecated](https://developer.apple.com/forums/thread/804015))
- `allowedExecutionTargets: IntentExecutionTargets` (iOS 27) tells the system which process
  performs an intent or query: `.main` (the app), `.appIntentsExtension`, `.widgetKitExtension`.
  Apple's own example: opening a browser tab only makes sense in the app's process.
  ([IntentExecutionTargets](https://developer.apple.com/documentation/appintents/intentexecutiontargets))
- `@AppIntent(schema: .system.searchInApp)` on a `ShowInAppSearchResultsIntent` with
  `criteria: StringSearchCriteria` (iOS 27) makes "search in <app>" work with Siri and Apple
  Intelligence. ([searchInApp](https://developer.apple.com/documentation/appintents/appschema/systemintent/searchinapp))
- The `.browser` schema domain exists but is Shortcuts-only (not Siri or Apple Intelligence) and
  expects tab, window and bookmark entities.
  ([App schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains))
- App Shortcut phrases must contain `\(.applicationName)`; a parameter in a phrase must be an
  `AppEntity` or `AppEnum` (not free text), and entity parameters need
  `updateAppShortcutParameters()` when the entities change.
- iOS 26 added interactive snippets (`SnippetIntent`) and `IndexedEntity` with
  `@Property(indexingKey:)`; iOS 27 added `IndexedEntityQuery`.
  ([App Intents updates](https://developer.apple.com/documentation/updates/appintents))
- App Intents metadata is extracted per target from that target's own sources. Intents in a
  Swift package need an `AppIntentsPackage` registered by both targets; a developer reports
  that is what made a control's open-app intent work
  ([forum 819995](https://developer.apple.com/forums/thread/819995)). Compiling the file into
  both targets is the documented route.

**Controls (iOS 18+)**

- A `ControlWidgetButton` performs an `AppIntent` or `OpenIntent`. To open the app, the intent
  conforms to `OpenIntent` and "the system requires the Target Membership of the app intent to be
  set to both the app and the widget extension".
  ([Creating controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system))
- Forum reports: a custom URL scheme does not open the app from a control
  ([forum 758911](https://developer.apple.com/forums/thread/758911),
  [forum 819995](https://developer.apple.com/forums/thread/819995)).

**Widgets**

- Widgets reach the app through `widgetURL` (whole widget) and `Link` (medium and larger).
  Lock Screen families are `accessoryCircular`, `accessoryRectangular`, `accessoryInline`;
  StandBy shows `systemSmall` widgets scaled up, without their removable background.
- Tinted and clear Home Screens render widgets in `.accented` mode: colors are replaced by the
  tint; `widgetAccentable()` marks what takes the accent.
- Widgets and their app share data through an App Group container; standard `UserDefaults` does
  not cross processes (DTS, [forum 762479](https://developer.apple.com/forums/thread/762479)).

**Spotlight**

- `CSSearchableIndex` items are on-device. An item without an `expirationDate` expires after a
  while (about 30 days), so permanent items set one.
  ([expirationDate](https://developer.apple.com/documentation/corespotlight/cssearchableitem/expirationdate))
- A tapped result reaches the app as an `NSUserActivity` of type `CSSearchableItemActionType`
  with the item's identifier under `CSSearchableItemActivityIdentifier`.

**Handoff**

- An `NSUserActivity` of type `NSUserActivityTypeBrowsingWeb` with a `webpageURL` continues in
  the other device's default browser (Safari on a Mac). No entitlement is needed to send it.
- To receive web pages, a browser lists `NSUserActivityTypeBrowsingWeb` in `NSUserActivityTypes`;
  iOS then hands it pages only when it is the default browser
  ([Mozilla 1030780](https://bugzilla.mozilla.org/show_bug.cgi?id=1030780),
  [Chromium handoff_manager](https://chromium.googlesource.com/chromium/src/+/HEAD/components/handoff/handoff_manager.mm)).

## What Plain does

- **Intents** (app target, `Plain/Intents`): Search in Plain (`system.searchInApp`), Open URL,
  New Tab, New Private Tab, Open Favorite (`OpenIntent` over a `FavoriteEntity` read from the
  App Group file), Show Tabs. All `.foreground`. Six App Shortcuts with "Plain" phrases; they
  also show as Spotlight action tiles. Search uses the engine chosen in Settings.
- **Not adopted:** the `.browser` schema (Shortcuts-only, and it needs tab and window entities
  Plain does not expose); interactive snippets (every Plain action ends in the app, so there is
  nothing to show inline); `IndexedEntity` (classic `CSSearchableItem` does the same for a short
  list, is testable through a seam, and keeps Core Spotlight out of the intents).
- **Controls** (widget extension): Search in Plain and New Private Tab, both one
  `OpenPlainIntent` (`OpenIntent` over an `AppEnum`), compiled into both targets,
  `allowedExecutionTargets = [.main]`, hidden from Shortcuts.
- **Widgets** (widget extension, views in PlainKit `WidgetUI`): one Search widget in small,
  medium, and the three Lock Screen families. Small: a dawn window over the search field. Medium:
  the field and the first four favorites. Every tap is a `plainbrowser:` link.
- **Spotlight:** favorites only (`FixedChoices.spotlightIndexesHistory` is false), indexed off
  the main thread whenever the favorites table changes. Clear History and Data empties Plain's
  index (and any saved activities), then puts the favorites back, since the clear keeps them.
- **Handoff:** the page on screen, never a private tab, never eligible for search or prediction.
  Receiving works once Plain is the default browser (web-browser entitlement).
