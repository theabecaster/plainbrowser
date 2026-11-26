#!/bin/zsh
# Run every test that doesn't need the device:
#   1. `swift test` for Packages/PlainKit (BrowserCore, Storage) on macOS.
#   2. The Smoke test plan (UI tests minus perf) on two simulators this script owns:
#      plain-duo (iPhone Duo) and plain-17 (iPhone 17).
# The simulators are created when missing and deleted afterwards, unless KEEP_SIMS=1.
# Only simulators named plain-* are ever touched.
# Usage: scripts/test.sh            KEEP_SIMS=1 scripts/test.sh
set -euo pipefail
source "${0:A:h}/lib/common.zsh"

typeset -A SIMS=(
  plain-duo "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4"
  plain-17  "com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-2"
)

sim_udid() {
  xcrun simctl list devices -j | jq -r --arg n "$1" '[.devices[][] | select(.name == $n)][0].udid // empty'
}

echo "== swift test (PlainKit)"
(cd Packages/PlainKit && swift test 2>&1 | grep -E 'Test run with|error|failed' )

echo "== build for testing"
scripts/build.sh

created=()
cleanup() {
  [[ "${KEEP_SIMS:-0}" == 1 ]] && return
  for name in $created; do
    local udid=$(sim_udid $name)
    [[ -n "$udid" ]] && { xcrun simctl shutdown "$udid" 2>/dev/null || true; xcrun simctl delete "$udid"; }
  done
}
trap cleanup EXIT

mkdir -p build/test
failed=0
for name in plain-duo plain-17; do
  udid=$(sim_udid $name)
  if [[ -z "$udid" ]]; then
    udid=$(xcrun simctl create $name ${=SIMS[$name]})
    created+=$name
  fi
  echo "== UI smoke on $name"
  rm -rf build/test/$name.xcresult
  if xcodebuild -project Plain.xcodeproj -scheme Plain -testPlan Smoke -destination "id=$udid" \
      -derivedDataPath build/sim -resultBundlePath build/test/$name.xcresult \
      test-without-building > build/test/$name.log 2>&1; then
    xcrun xcresulttool get test-results summary --path build/test/$name.xcresult \
      | jq -r '"\(.result): \(.passedTests) passed, \(.failedTests) failed, \(.skippedTests) skipped"'
  else
    failed=1
    grep -E 'error:|failed' build/test/$name.log | head -20
    print -u2 "UI smoke failed on $name; log: build/test/$name.log"
  fi
done
exit $failed
