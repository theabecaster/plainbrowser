#!/bin/zsh
# Refuses a test run unless every UI test launch is isolated from the device owner's data
# (docs/development.md, "Test isolation"). scripts/test.sh and scripts/perf-gate.sh run it first;
# a failure stops them before anything is built or launched, on a simulator or the phone.
#
# Checks, statically:
#   1. UI tests make Plain only through XCUIApplication.isolated() (IsolatedApplication, which
#      refuses to launch without an isolation argument and stops when the app doesn't report it).
#      The only other XCUIApplication allowed is Springboard.
#   2. No test overwrites or edits launchArguments (which could drop the isolation argument);
#      tests only append with +=. The factory's one assignment is the exception.
#   3. The app honors the isolation arguments in every build configuration: TestIsolation has no
#      #if DEBUG, and the app's store and the shared website data, thumbnails and downloads read it.
#   4. App code touches the owner's state (standard defaults, general pasteboard, default website
#      data, icon, Documents, scene state, Photos, tips, Spotlight, widgets, App Groups and their
#      defaults, Handoff, App Shortcuts and intent donations, Keychain) only in the files that
#      route it through TestIsolation; the system hooks' files must check TestIsolation.isActive.
#   5. The hosted unit tests (PlainTests) launch their host app isolated: the Smoke plan passes
#      the isolation argument to it.
set -euo pipefail
cd "${0:A:h:h:h}"

problems=()
tests=(PlainUITests/*.swift)
# file:line: code, with comment lines left out.
code_matching() { grep -nE "$1" $tests | grep -vE '^[^:]+:[0-9]+: *//' || true; }

while IFS= read -r line; do
  [[ -n $line ]] && problems+="bare XCUIApplication (use XCUIApplication.isolated()): $line"
done < <(code_matching 'XCUIApplication\(' | grep -v -e 'bundleIdentifier: "com.apple.springboard"' -e 'bundleIdentifier: "com.apple.Preferences").activate()' \
  -e 'bundleIdentifier: "com.apple.Spotlight")' || true)

while IFS= read -r line; do
  [[ -n $line ]] && problems+="launchArguments overwritten or edited (append with +=): $line"
done < <(code_matching 'launchArguments *(=[^=]|\.remove|\.insert|\[)' \
  | grep -v 'app.launchArguments = \[IsolatedApplication.inMemoryArgument\]' || true)

grep -q 'override func launch()' PlainUITests/SmokeTests.swift \
  || problems+="IsolatedApplication.launch() (the launch-time isolation check) is missing"
# A Plain link spelled out in a test reaches the TestFlight app from a Plain Dev run, unisolated:
# tests take the scheme of the app under test (PlainLinkScheme in PlainUITests/Info.plist).
while IFS= read -r line; do
  [[ -n $line ]] && problems+="literal plainbrowser: link in a UI test (use the PlainLinkScheme of the app under test): $line"
done < <(code_matching '"plainbrowser(\.[a-z]+)?:' || true)
grep -q 'override func open(_ url: URL)' PlainUITests/SmokeTests.swift \
  || problems+="IsolatedApplication.open(_:) (the isolation check for a launch from a link) is missing"

isolation=Packages/PlainKit/Sources/BrowserCore/TestIsolation.swift
if [[ ! -f $isolation ]]; then
  problems+="$isolation is missing"
elif grep -q '#if DEBUG' $isolation; then
  problems+="$isolation must not depend on the build configuration (#if DEBUG)"
fi
grep -q 'TestIsolation.directory' Plain/SceneDelegate.swift \
  || problems+="Plain/SceneDelegate.swift does not take its store folder from TestIsolation"
grep -q 'TestIsolationMarker.install' Plain/SceneDelegate.swift \
  || problems+="Plain/SceneDelegate.swift does not install the isolation marker"
for needle in 'AppWebsiteData.store' 'TestIsolation.folder("Thumbnails")' 'TestIsolation.folder(EngineChoices.downloadsFolderName)'; do
  grep -qF "$needle" Packages/PlainKit/Sources/WebEngine/WebViewPool.swift \
    || problems+="WebViewPool does not use $needle"
done

# 4. App code reaches the owner's state only through the isolation-aware places. A new use of one of
#    these elsewhere must go through TestIsolation (or join this list after a look at isolation).
sources=(Plain/**/*.swift(N) PlainWidgets/**/*.swift(N) Packages/PlainKit/Sources/**/*.swift(N))
typeset -A allowed=(
  'UserDefaults\.standard'        'BrowserCore/TestIsolation.swift'
  'UIPasteboard\.general'         'WebEngine/AppWebsiteData.swift|FeatureUI/Pasteboard.swift'
  'WKWebsiteDataStore\.default'   '^$'
  'setAlternateIconName\('        'FeatureUI/Intro/AppIconChoice.swift'
  'documentDirectory|documentsDirectory' 'WebEngine/WebViewPool.swift'
  'applicationSupportDirectory'   'Plain/SceneDelegate.swift'
  'session\.userInfo|sessionRole' 'ShellUI/SceneState.swift|Plain/AppDelegate.swift'
  'PHPhotoLibrary'                'WebEngine/LinkMenu.swift'
  'Tips\.configure'               'ShellUI/TabsMenuTip.swift'
  'SecItem(Add|Update|Delete|CopyMatching)' '^$'
  # The system hooks (docs/development.md, "Test isolation"): an isolated run keeps its own App
  # Group folder and never indexes Spotlight, reloads widgets, offers Handoff or updates Shortcuts.
  'CSSearchableIndex|deleteAllSavedUserActivities' 'SystemSync/SpotlightIndex.swift'
  'WidgetCenter|ControlCenter\.shared' 'SystemSync/SystemSync.swift'
  'CoreSpotlightIndex\(\)|[^A-Za-z]SystemSync\(' 'SystemSync/SystemSync.swift'
  'containerURL\(forSecurityApplicationGroupIdentifier' 'PlainShared/SharedFavorites.swift'
  'UserDefaults\(suiteName' 'BrowserCore/TestIsolation.swift|WebEngine/AppWebsiteData.swift'
  'becomeCurrent\(|NSUserActivity\(' 'ShellUI/BrowserViewController\+System.swift'
  'updateAppShortcutParameters|IntentDonationManager|\.donate\(' 'ShellUI/TabsMenuTip.swift|Plain/SceneDelegate.swift'
)
for pattern in ${(k)allowed}; do
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    file=${line%%:*}
    [[ $file =~ ${allowed[$pattern]} ]] && continue
    problems+="owner state outside TestIsolation ($pattern): $line"
  done < <(grep -nE "$pattern" $sources | grep -vE '^[^:]+:[0-9]+: *//' || true)
done

# The files above that reach the system for Plain decide with TestIsolation themselves, and the
# app makes its sync only through SystemSync.live (isolated stand-ins in a test run).
for file in Packages/PlainKit/Sources/SystemSync/SpotlightIndex.swift Packages/PlainKit/Sources/SystemSync/SystemSync.swift \
    Packages/PlainKit/Sources/PlainShared/SharedFavorites.swift Packages/PlainKit/Sources/ShellUI/BrowserViewController+System.swift; do
  [[ -f $file ]] || continue
  grep -vE '^ *//' $file | grep -q 'TestIsolation.isActive' \
    || problems+="$file reaches the system without checking TestIsolation.isActive"
done
# The only App Shortcuts update is SystemSync.live's onChange (dropped in an isolated run): within
# the three lines after `SystemSync.live {`.
while IFS= read -r line; do
  [[ -z $line ]] && continue
  n=${${line#*:}%%:*}
  sed -n "$(( n > 3 ? n - 3 : 1 )),$(( n - 1 ))p" ${line%%:*} | grep -q 'SystemSync.live {' \
    || problems+="App Shortcuts updated outside SystemSync.live's onChange (isolated runs skip only that): $line"
done < <(grep -nE 'updateAppShortcutParameters' $sources | grep -vE '^[^:]+:[0-9]+: *//' || true)

# 5. A plan that runs the hosted unit tests passes the isolation argument to their host app.
for plan in PlainUITests/*.xctestplan(N); do
  grep -q '"name" : "PlainTests"' $plan || continue
  grep -q '"argument" : "-PlainInMemoryStore"' $plan \
    || problems+="$plan runs PlainTests without -PlainInMemoryStore for the host app"
done

if (( ${#problems} )); then
  print -u2 "test isolation check failed: a test could touch the device owner's data."
  for p in $problems; do print -u2 "  - $p"; done
  exit 1
fi
echo "test isolation: ok"
