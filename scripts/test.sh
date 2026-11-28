#!/bin/zsh
# Run every test that doesn't need the device:
#   1. `swift test` for Packages/PlainKit (BrowserCore, Storage) on macOS.
#   2. The Smoke test plan (UI tests minus perf) on two simulators this script owns:
#      <prefix>-duo (iPhone Duo) and <prefix>-17 (iPhone 17); the prefix is PLAIN_SIM_PREFIX,
#      default `plain`. Agents running in parallel each set their own (e.g. plain-r).
# The simulators are made when missing (cloned from the Mac's template for that device,
# scripts/lib/sim.zsh) and deleted afterwards, unless KEEP_SIMS=1.
# Only simulators named plain-* are ever touched.
# Each test is capped by XCTest's execution time allowance, so a stuck test cannot hang the run.
# Usage: scripts/test.sh            KEEP_SIMS=1 scripts/test.sh     PLAIN_SIM_PREFIX=plain-r scripts/test.sh
set -euo pipefail
source "${0:A:h}/lib/common.zsh"
source "${0:A:h}/lib/sim.zsh"

PREFIX=${PLAIN_SIM_PREFIX:-plain}
[[ $PREFIX == plain || $PREFIX == plain-* ]] || { print -u2 "PLAIN_SIM_PREFIX must start with plain"; exit 1; }
typeset -A SIMS=(
  $PREFIX-duo "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4"
  $PREFIX-17  "com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-2"
)

# Every UI test launch must use throwaway state, wherever it runs. Refuse otherwise.
scripts/lib/check-isolation.zsh

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
for name in $PREFIX-duo $PREFIX-17; do
  udid=$(sim_udid $name)
  if [[ -z "$udid" ]]; then
    # A clone of the Mac's template for this device (scripts/lib/sim.zsh), first boot done.
    udid=$(sim_new $name ${=SIMS[$name]})
    created+=$name
  fi
  echo "== UI smoke on $name"
  rm -rf build/test/$name.xcresult
  if xcodebuild -project Plain.xcodeproj -scheme Plain -testPlan Smoke -destination "id=$udid" \
      -derivedDataPath build/sim -resultBundlePath build/test/$name.xcresult \
      -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
      -maximum-test-execution-time-allowance 300 \
      test-without-building > build/test/$name.log 2>&1; then
    xcrun xcresulttool get test-results summary --path build/test/$name.xcresult \
      | jq -r '"\(.result): \(.passedTests) passed, \(.failedTests) failed, \(.skippedTests) skipped"'
  else
    failed=1
    grep -E 'error:|failed' build/test/$name.log | head -20 || true
    print -u2 "UI smoke failed on $name; log: build/test/$name.log"
  fi
  # One booted simulator at a time: the machine is shared.
  xcrun simctl shutdown "$udid" 2>/dev/null || true
done
exit $failed
