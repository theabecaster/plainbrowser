#!/bin/zsh
# Run the perf tests (PlainUITests/Perf.xctestplan, Release build, no coverage), record the numbers in
# docs/perf-log.md, and fail on a breach.
#
# Usage: scripts/perf-gate.sh [--sim | --device]
#   --sim (default)  On the <prefix>-perf-duo simulator (iPhone Duo; prefix PLAIN_SIM_PREFIX, default
#                    `plain`). Shut down afterwards, and deleted when this run created it. Fails on a test failure, or when a metric is more than
#                    simRegressionTolerance (perf/budgets.json) worse than the previous `sim` row.
#                    The hitch ratio is device-only: XCTHitchMetric reports nothing on a simulator.
#   --device         On the device from PLAIN_DEVICE or scripts/local.env (also:
#                    PLAIN_PERF_TARGET=device). Fails on a test failure or when a metric reaches
#                    its `fail` budget in perf/budgets.json.
#
# Metrics are the median of each test's iterations. Every run appends one row to
# docs/perf-log.md with the date, git SHA and target, pass or fail.
# Exit codes: 0 pass, 1 breach/regression/test failure, 2 device locked or unreachable.
set -euo pipefail
source "${0:A:h}/lib/common.zsh"

MODE=${PLAIN_PERF_TARGET:-sim}
case "${1:-}" in
  --device) MODE=device ;;
  --sim) MODE=sim ;;
  "") ;;
  *) print -u2 "usage: scripts/perf-gate.sh [--sim | --device]"; exit 1 ;;
esac

BUDGETS=perf/budgets.json
LOG=docs/perf-log.md
METRICS=(launchMs searchFieldMs hitchMsPerS galleryMs swipeMs)
SIM_NAME=${PLAIN_SIM_PREFIX:-plain}-perf-duo
SIM_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-Duo
SIM_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4

extra=()
if [[ $MODE == device ]]; then
  require_device
  check_device_unlocked || exit 2
  destination="id=$PLAIN_DEVICE"
  # Device runs build "Plain Dev" (dev bundle id), beside the TestFlight app, never over it.
  extra=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration PLAIN_BUNDLE_SUFFIX=.dev "PLAIN_DISPLAY_SUFFIX= Dev")
else
  [[ $SIM_NAME == plain-* ]] || { print -u2 "PLAIN_SIM_PREFIX must start with plain"; exit 1; }
  udid=$(xcrun simctl list devices -j | jq -r --arg n $SIM_NAME '[.devices[][] | select(.name == $n)][0].udid // empty')
  created_sim=0
  if [[ -z "$udid" ]]; then
    udid=$(xcrun simctl create $SIM_NAME $SIM_TYPE $SIM_RUNTIME)
    created_sim=1
  fi
  destination="id=$udid"
  trap 'xcrun simctl shutdown "$udid" 2>/dev/null || true; (( created_sim )) && xcrun simctl delete "$udid" 2>/dev/null || true' EXIT
fi

sha=$(git rev-parse --short HEAD)
git diff --quiet HEAD -- . ':!docs/perf-log.md' || sha="$sha-dirty"
stamp=$(date +%Y%m%d-%H%M%S)
result=build/perf/$stamp-$MODE.xcresult
mkdir -p build/perf

echo "== perf tests on $MODE ($destination), Release"
xcodegen generate --quiet
tests_ok=1
xcodebuild -project Plain.xcodeproj -scheme Plain -testPlan Perf -configuration Release \
  -destination "$destination" -derivedDataPath build/perf/dd -resultBundlePath $result $extra \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 600 \
  -enableCodeCoverage NO test > build/perf/$stamp.log 2>&1 || tests_ok=0
if [[ ! -d $result ]]; then
  grep -E 'error:' build/perf/$stamp.log | sort -u | head -20 || true
  print -u2 "no test results; log: build/perf/$stamp.log"
  exit 1
fi

# Median of each metric's measurements, in the units the budgets use (ms, ms/s).
raw=$(xcrun xcresulttool get test-results metrics --path $result)
median() {  # $1: test name, $2: jq filter selecting the metric, $3: scale
  jq -r --arg t "$1" --argjson k "$3" "
    [.[] | select(.testIdentifier | startswith(\$t)) | .testRuns[].metrics[] | select($2)][0].measurements
    | if . == null or length == 0 then \"—\"
      else sort | .[length / 2 | floor] * \$k | . * 10 | round / 10 end" <<<"$raw"
}
typeset -A value=(
  launchMs      "$(median 'PerfTests/testLaunch()' '.identifier | endswith("OSSignpost-launch.firstFrame.duration")' 1000)"
  searchFieldMs "$(median 'PerfTests/testLaunchToSearchFieldReady()' '.identifier | endswith("OSSignpost-launch.duration")' 1000)"
  hitchMsPerS   "$(median 'PerfTests/testPageScrollHitches()' '.displayName | test("hitch.*ratio"; "i")' 1)"
  galleryMs     "$(median 'PerfTests/testGalleryOpen()' '.identifier | endswith("OSSignpost-gallery.show.duration")' 1000)"
  swipeMs       "$(median 'PerfTests/testBarSwipe()' '.identifier | endswith("OSSignpost-tab.swipeSettle.duration")' 1000)"
)

# The previous sim row's values, by column (docs/perf-log.md: | Date | SHA | Target | launch | field | hitch |
# gallery | swipe | Result |). Rows from before the gallery and swipe columns hold the result there, which is
# not a number, so those two then have no previous value.
typeset -A previous
if [[ $MODE == sim ]]; then
  last=$(grep -E '^\| [0-9]{4}-' $LOG | awk -F'|' '$4 ~ /sim/' | tail -1 || true)
  if [[ -n "$last" ]]; then
    cols=("${(@s:|:)last}")
    previous=(launchMs "${cols[5]// /}" searchFieldMs "${cols[6]// /}" hitchMsPerS "${cols[7]// /}"
      galleryMs "${cols[8]// /}" swipeMs "${cols[9]// /}")
  fi
fi

failures=()
(( tests_ok )) || failures+="tests failed (log: build/perf/$stamp.log)"
tolerance=$(jq -r .simRegressionTolerance $BUDGETS)
for m in $METRICS; do
  v=${value[$m]}
  label=$(jq -r --arg m $m '.metrics[$m].label' $BUDGETS)
  line=$(printf '%-38s %8s' "$label" "$v")
  if [[ $v == "—" && $MODE == sim && $m == hitchMsPerS ]]; then
    # XCTHitchMetric reports nothing on a simulator (Xcode 27.2); the device measures it.
    value[$m]="n/a"
    line=$(printf '%-38s %8s' "$label" "n/a")"   (device only)"
  elif [[ $v == "—" ]]; then
    failures+="$m: no measurement"
  elif [[ $MODE == device ]]; then
    fail=$(jq -r --arg m $m '.metrics[$m].fail' $BUDGETS)
    target=$(jq -r --arg m $m '.metrics[$m].target' $BUDGETS)
    line+="   target $target, fail at $fail"
    (( v >= fail )) && failures+="$m $v ≥ fail budget $fail"
  else
    p=${previous[$m]:-—}
    if [[ $p == <->(|.<->) ]]; then
      limit=$(( p * (1 + tolerance) ))
      line+=$(printf '   previous sim %s, limit %.1f' $p $limit)
      (( v > limit )) && failures+="$m $v regressed more than $(printf %.0f $(( tolerance * 100 )))% from $p"
    else
      line+="   (no previous sim row)"
    fi
  fi
  echo $line
done

verdict=pass
(( ${#failures} == 0 )) || verdict=FAIL
echo "| $(date +%Y-%m-%d\ %H:%M) | $sha | $MODE | ${value[launchMs]} | ${value[searchFieldMs]} | ${value[hitchMsPerS]} | ${value[galleryMs]} | ${value[swipeMs]} | $verdict |" >> $LOG
echo "logged to $LOG; results: $result"

if (( ${#failures} )); then
  for f in $failures; do print -u2 "FAIL: $f"; done
  exit 1
fi
echo "perf gate passed ($MODE)"
