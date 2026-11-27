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
set -euo pipefail
cd "${0:A:h:h:h}"

problems=()
tests=(PlainUITests/*.swift)
# file:line: code, with comment lines left out.
code_matching() { grep -nE "$1" $tests | grep -vE '^[^:]+:[0-9]+: *//' || true; }

while IFS= read -r line; do
  [[ -n $line ]] && problems+="bare XCUIApplication (use XCUIApplication.isolated()): $line"
done < <(code_matching 'XCUIApplication\(' | grep -v 'bundleIdentifier: "com.apple.springboard"' || true)

while IFS= read -r line; do
  [[ -n $line ]] && problems+="launchArguments overwritten or edited (append with +=): $line"
done < <(code_matching 'launchArguments *(=[^=]|\.remove|\.insert|\[)' \
  | grep -v 'app.launchArguments = \[IsolatedApplication.inMemoryArgument\]' || true)

grep -q 'override func launch()' PlainUITests/SmokeTests.swift \
  || problems+="IsolatedApplication.launch() (the launch-time isolation check) is missing"

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

if (( ${#problems} )); then
  print -u2 "test isolation check failed: a test could touch the device owner's data."
  for p in $problems; do print -u2 "  - $p"; done
  exit 1
fi
echo "test isolation: ok"
