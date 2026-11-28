# Plain as an iPhone app on a Mac (2026-11-28)

TestFlight users can run Plain on an Apple Silicon Mac ("Designed for iPhone"; `TARGETED_DEVICE_FAMILY` is iPhone only). A user on a MacBook could not pick an icon in the intro; that one is fixed (the intro and Settings leave the picker out where the icon can't change, `AppIconSupport`; docs/research/notes.md, "Alternate app icons").

This is a quick list of what else is likely broken or odd there, from reading the code and Apple's documented Mac limits. Nothing here is fixed or checked on a Mac yet. Each line says how sure it is: **sure** (documented or certain from the code), **likely**, or **guess**.

- **Haptics:** every `Haptic` is silent; a Mac has no Taptic Engine for iPhone apps, so refusals that rely on the "nothing there" bump (rubber band plus bump) show only the rubber band. Likely.
- **Gestures on a trackpad:** the bar swipe, swipe up into the switcher, card flick to close and edge swipes are pan gestures; a two-finger trackpad scroll does not start them (no `allowedScrollTypesMask` anywhere), so they need click-and-drag, which few users will find. Likely.
- **Pointer:** no `UIPointerInteraction` or hover anywhere: buttons get no hover highlight and the × on tab cards has no hover state. Sure (code); how odd it feels is a guess.
- **Keyboard:** Command-L, Escape and Command-period exist (`BrowserViewController.keyCommands`), but no Command-T, Command-W, Command-R, Command-[ / ] or Command-F, which every Mac browser user expects. Sure.
- **No on-screen keyboard:** the intro's finish and the empty tab expect "the keyboard rises" (`keyboardWillShow`, `keyboardLayoutGuide`); with a hardware keyboard only, the search sheet's layout above the keyboard and anything waiting for the keyboard frame may sit low or wait for nothing. Likely.
- **iPhone Duo code:** `verticalBarEdge`, `reservedRegions` and the fold paths never trigger (no foldable, no status zone); harmless as long as they stay keyed to traits. Sure.
- **Window size:** an iPhone-only app gets a phone-shaped window on the Mac; side tabs and the side pane (regular width and height) never show, and the Tab Layout row stays hidden, as it should. Likely.
- **Default browser:** the intro's default-browser step and card (when on) open iOS Settings, which does not exist on a Mac; the browser entitlement does not make an iPhone app the Mac's default browser. Likely.
- **Settings links:** "Off in Settings" toasts and Turn On Apple Intelligence open `openSettingsURLString`; on a Mac that opens System Settings at best, not Plain's page, and Apple Intelligence lives elsewhere there. Likely.
- **Dictation:** the field's microphone needs `SFSpeechRecognizer.supportsOnDeviceRecognition`; it may be true on the Mac, but microphone prompts and audio session behave like a Mac app's. Guess.
- **Share:** `UIActivityViewController` works but shows the Mac share menu; Save to Photos and Print may differ. Guess.
- **Downloads:** Show in Files opens `shareddocuments://`, which has no Files app on a Mac to open; the button likely does nothing. Likely.
- **Widgets, Spotlight, Handoff, App Shortcuts:** iPhone widgets can run on the Mac desktop from an iPhone nearby, not from this app's Mac copy; Spotlight and Handoff donations may index or hand off oddly. Guess.
- **Apple Intelligence:** Browse for Me and Summarize use FoundationModels; on a Mac with Apple Intelligence on it should work, but availability is read the iPhone way. Guess.
- **Launch splash:** follows `AppIcons.current`, which is always Dawn on a Mac now; correct, since the Dock shows Dawn. Sure.
