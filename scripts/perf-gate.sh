#!/bin/zsh
# Run the perf tests (PlainUITests/Perf.xctestplan, Release build, no coverage), record the numbers in
# docs/perf-log.md, and fail on a breach.
#
# Usage: scripts/perf-gate.sh [--sim | --device]
#   --sim (default)  On the <prefix>-perf-duo simulator (iPhone Duo; prefix PLAIN_SIM_PREFIX, default
#                    `plain`). Shut down afterwards, and deleted when this run created it. Fails on a test failure, or when a metric is more than
#                    simRegressionTolerance (perf/budgets.json) worse than the previous `sim` row.
#                    Metrics marked deviceOnly (the hitch ratios: XCTHitchMetric reports nothing on a
#                    simulator) read n/a.
#   --device         On the device from PLAIN_DEVICE or scripts/local.env (also:
#                    PLAIN_PERF_TARGET=device). Fails on a test failure, when a metric reaches its
#                    `fail` budget, or on the ratchet: a metric more than ratchet.tolerance (plus its
#                    `slack`) worse than its best value in the last ratchet.window passing device rows.
#                    A metric whose iterations spread more than ratchet.rsdLimit (relative standard
#                    deviation) has its test rerun once, and the rerun's numbers count.
#
# Metrics are the median of each test's iterations. Every run appends one row to
# docs/perf-log.md with the date, git SHA and target, pass or fail. The metrics, their tests and
# their log columns come from perf/budgets.json, in its order; the log's header must match.
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
METRICS=(${(f)"$(jq -r '.metrics | keys_unsorted[]' $BUDGETS)"})
SIM_NAME=${PLAIN_SIM_PREFIX:-plain}-perf-duo
SIM_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-Duo
SIM_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4

budget() { jq -r --arg m $1 ".metrics[\$m].$2 // empty" $BUDGETS; }  # $1 metric, $2 field

# The log's table header, from the metrics' columns. Checked before anything runs.
header="| Date | SHA | Target |"
for m in $METRICS; do header+=" $(budget $m column) |"; done
header+=" Result |"
if [[ "$(grep -m1 '^| Date |' $LOG)" != "$header" ]]; then
  print -u2 "$LOG's table header does not match the metrics in $BUDGETS. Expected:"
  print -u2 "$header"
  exit 1
fi

# Every perf launch must use throwaway state: the phone is the owner's own. Refuse otherwise.
scripts/lib/check-isolation.zsh

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

run_tests() {  # $1 action (test | test-without-building), $2 result bundle, $3 log, then -only-testing flags
  local action=$1 bundle=$2 log=$3
  shift 3
  xcodebuild -project Plain.xcodeproj -scheme Plain -testPlan Perf -configuration Release \
    -destination "$destination" -derivedDataPath build/perf/dd -resultBundlePath $bundle $extra "$@" \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 600 \
    -enableCodeCoverage NO $action > $log 2>&1
}

echo "== perf tests on $MODE ($destination), Release; load average $(sysctl -n vm.loadavg)"
xcodegen generate --quiet
tests_ok=1
run_tests test $result build/perf/$stamp.log || tests_ok=0
if [[ ! -d $result ]]; then
  grep -E 'error:' build/perf/$stamp.log | sort -u | head -20 || true
  print -u2 "no test results; log: build/perf/$stamp.log"
  exit 1
fi

# "<median> <rsd>" of a metric's iterations in a result bundle, in the budget's units (ms, ms/s,
# MB); "— —" when it recorded nothing. RSD is the sample standard deviation over the mean, in %.
measure() {  # $1 metric, $2 result bundle
  local raw
  raw=$(xcrun xcresulttool get test-results metrics --path $2)
  jq -r --arg t "$(budget $1 test)" --argjson k "$(budget $1 scale)" "
    [.[] | select(.testIdentifier | startswith(\$t)) | .testRuns[].metrics[] | select($(budget $1 filter))][0].measurements
    | if . == null or length == 0 then \"— —\"
      else (map(. * \$k) | sort) as \$s | (\$s | length) as \$n | (\$s | add / \$n) as \$mean
        | (if \$n < 2 or \$mean == 0 then 0
           else ((\$s | map((. - \$mean) * (. - \$mean)) | add) / (\$n - 1) | sqrt) / \$mean * 100 end) as \$rsd
        | \"\(\$s[\$n / 2 | floor] * 10 | round / 10) \(\$rsd | round)\" end" <<<"$raw"
}
typeset -A value rsd
for m in $METRICS; do
  read -r v r <<<"$(measure $m $result)"
  value[$m]=$v; rsd[$m]=$r
done

# Device: a test whose metric spread more than rsdLimit runs once more, and its rerun counts.
if [[ $MODE == device ]]; then
  rsd_limit=$(jq -r '.ratchet.rsdLimit * 100' $BUDGETS)
  typeset -U noisy_tests=()
  for m in $METRICS; do
    [[ ${rsd[$m]} == <-> ]] && (( ${rsd[$m]} > rsd_limit )) && noisy_tests+=$(budget $m test)
  done
  if (( ${#noisy_tests} )); then
    echo "== rerunning (RSD over ${rsd_limit}%): ${(j:, :)noisy_tests}"
    only=()
    for t in $noisy_tests; do only+=(-only-testing:PlainUITests/${t%\(\)}); done
    rerun=build/perf/$stamp-$MODE-rerun.xcresult
    run_tests test-without-building $rerun build/perf/$stamp-rerun.log $only || tests_ok=0
    if [[ -d $rerun ]]; then
      for m in $METRICS; do
        (( ${noisy_tests[(Ie)$(budget $m test)]} )) || continue
        read -r v r <<<"$(measure $m $rerun)"
        [[ $v == "—" ]] && continue
        value[$m]=$v; rsd[$m]=$r
      done
    fi
  fi
fi

# A logged row's cells by the header's column names. Rows from before a column hold the result
# (or nothing) there, which is not a number, so that metric has no value in them.
typeset -A col_index
cols=("${(@s:|:)header}")
for i in {1..${#cols}}; do col_index[${${cols[$i]## }%% }]=$i; done
cell() {  # $1 row, $2 metric: the row's value for the metric, or empty
  local cells=("${(@s:|:)1}")
  local c=${cells[${col_index[$(budget $2 column)]}]:-}
  c=${c// /}
  [[ $c == <->(|.<->) ]] && print -r -- $c
  return 0
}
log_rows() {  # $1 target: that target's rows, oldest first
  grep -E '^\| [0-9]{4}-' $LOG | awk -F'|' -v t=$1 '$4 ~ t' || true
}

# Sim: the previous sim row. Device: the last `window` passing device rows (the result cell, the
# row's last, starts with "pass").
typeset -A previous best
if [[ $MODE == sim ]]; then
  last=$(log_rows sim | tail -1)
  [[ -n "$last" ]] && for m in $METRICS; do previous[$m]=$(cell "$last" $m); done
else
  window=$(jq -r .ratchet.window $BUDGETS)
  passing=(${(f)"$(log_rows device | awk -F'|' '{ r = $(NF-1); gsub(/^ +/, "", r); if (r ~ /^pass/) print }' | tail -$window)"})
  for m in $METRICS; do
    for row in $passing; do
      v=$(cell "$row" $m)
      [[ -z $v ]] && continue
      if [[ -z ${best[$m]:-} ]] || (( v < ${best[$m]} )); then best[$m]=$v; fi
    done
  done
fi

failures=()
(( tests_ok )) || failures+="tests failed (log: build/perf/$stamp.log)"
sim_tolerance=$(jq -r .simRegressionTolerance $BUDGETS)
ratchet_tolerance=$(jq -r .ratchet.tolerance $BUDGETS)
for m in $METRICS; do
  v=${value[$m]}
  label=$(budget $m label)
  line=$(printf '%-44s %8s' "$label" "$v")
  [[ $v != "—" ]] && line+=$(printf '  RSD %3s%%' ${rsd[$m]})
  if [[ $v == "—" && $MODE == sim && $(budget $m deviceOnly) == true ]]; then
    # XCTHitchMetric reports nothing on a simulator (Xcode 27.2); the device measures it.
    value[$m]="n/a"
    line=$(printf '%-44s %8s' "$label" "n/a")"   (device only)"
  elif [[ $v == "—" ]]; then
    failures+="$m: no measurement"
  elif [[ $MODE == device ]]; then
    fail=$(budget $m fail)
    target=$(budget $m target)
    line+="   target $target, fail at $fail"
    (( v >= fail )) && failures+="$m $v ≥ fail budget $fail"
    if [[ -n ${best[$m]:-} ]]; then
      b=${best[$m]}
      slack=$(budget $m slack)
      limit=$(( b + (b * ratchet_tolerance > slack ? b * ratchet_tolerance : slack) ))
      line+=$(printf ', best %s, ratchet limit %.1f' $b $limit)
      (( v > limit )) && failures+="$m $v regressed past $(printf %.1f $limit) (best of the last $window passing device rows: $b)"
    else
      line+=", no passing device row yet"
    fi
  else
    p=${previous[$m]:-}
    if [[ -n $p ]]; then
      limit=$(( p * (1 + sim_tolerance) ))
      line+=$(printf '   previous sim %s, limit %.1f' $p $limit)
      (( v > limit )) && failures+="$m $v regressed more than $(printf %.0f $(( sim_tolerance * 100 )))% from $p"
    else
      line+="   (no previous sim value)"
    fi
  fi
  echo $line
done

verdict=pass
(( ${#failures} == 0 )) || verdict=FAIL
row="| $(date +%Y-%m-%d\ %H:%M) | $sha | $MODE |"
for m in $METRICS; do row+=" ${value[$m]} |"; done
echo "$row $verdict |" >> $LOG
echo "logged to $LOG; results: $result"

if (( ${#failures} )); then
  for f in $failures; do print -u2 "FAIL: $f"; done
  exit 1
fi
echo "perf gate passed ($MODE)"
