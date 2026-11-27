#!/bin/zsh
# The device matrix (docs/device-matrix.md): runs the capture tests, and any UI tests you name, on
# every screen class Plain supports, one simulator at a time, and makes a contact sheet per screen.
#
#   scripts/matrix.sh [--quick|--full] [--rows <id,id>] [--out <dir>] [--host <name> | --local]
#                     [--no-build] [--resizable] [-only-testing:<test>]...
#
#   --quick      the five screen-class rows (default): se, 17, max, duo-outer, duo-inner.
#   --full       every row: also mini, air, landscape, Duo inner portrait, large text, dark,
#                Reduce Motion. Before each TestFlight release, when the machine allows.
#   --rows       only these rows (ids from the table below, or docs/device-matrix.md).
#   --out        where the shots, sheets and logs go (default build/matrix; relative paths are
#                from the repo root). Emptied first.
#   --host       run on this test Mac (scripts/lib/remote.zsh) and bring the results back to
#                --out. Default: PLAIN_TEST_HOST, from the environment or scripts/local.env.
#   --local      run on this Mac even when PLAIN_TEST_HOST is set.
#   --no-build   reuse the last scripts/build.sh output (build/sim).
#   --resizable  skip Device Hub: the Duo's inner rows use the resizable window stand-in.
#   -only-testing:PlainUITests/<Class>[/<test>]   the tests to run (repeatable). Without a
#                capture test among them, the default capture test runs too. Default:
#                FocusCaptureTests/testCaptureAddressFocus (--quick); CaptureTests and
#                FocusCaptureTests (--full).
#
# Output: <out>/<row>/<screen>.png, <out>/sheets/<screen>.png (that screen on every row, side by
# side), <out>/<row>/xcodebuild.log (and result.xcresult, on the Mac that ran it),
# <out>/summary.txt.
#
# Simulators: <prefix>-<row>, prefix PLAIN_SIM_PREFIX (default plain-matrix; must start with
# plain-matrix). Each is created for its row, booted alone, shut down after it and deleted; the
# exit trap deletes any this run made. No other simulator is touched.
# The Duo's fold comes from scripts/duo-fold.sh (Device Hub). When Device Hub can't be driven
# (Mac locked, no Accessibility access), the inner rows fall back to the resizable window
# (devicectl appResize at the inner screen's size) and summary.txt says so.
set -euo pipefail
setopt extended_glob
source "${0:A:h}/lib/common.zsh"

PREFIX=${PLAIN_SIM_PREFIX:-plain-matrix}
[[ $PREFIX == plain-matrix* ]] || { print -u2 "PLAIN_SIM_PREFIX must start with plain-matrix"; exit 1; }
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-2
DUO_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4

# id | device type | screen (fold state, or orientation) | text size | appearance | motion | in --quick
ROWS=(
  "se|iPhone-SE-3rd-generation|portrait|large|light|normal|quick"
  "mini|iPhone-13-mini|portrait|large|light|normal|"
  "17|iPhone-17|portrait|large|light|normal|quick"
  "air|iPhone-Air|portrait|large|light|normal|"
  "max|iPhone-18-Pro-Max|portrait|large|light|normal|quick"
  "17-land|iPhone-17|landscape|large|light|normal|"
  "max-land|iPhone-18-Pro-Max|landscape|large|light|normal|"
  "duo-outer|iPhone-Duo|Closed|large|light|normal|quick"
  "duo-inner|iPhone-Duo|Open|large|light|normal|quick"
  "duo-inner-portrait|iPhone-Duo|Open+Rotate Right|large|light|normal|"
  "17-xxxl|iPhone-17|portrait|extra-extra-extra-large|light|normal|"
  "se-ax3|iPhone-SE-3rd-generation|portrait|accessibility-extra-large|light|normal|"
  "17-dark|iPhone-17|portrait|large|dark|normal|"
  "duo-inner-dark|iPhone-Duo|Open|large|dark|normal|"
  "17-motion|iPhone-17|portrait|large|light|reduce|"
)

mode=quick out=build/matrix build=1 resizable=0 picked="" tests=() host="" local_run=0 forward=()
while (( $# )); do
  case $1 in
    --quick|--full) mode=${1#--}; forward+=$1 ;;
    --rows) picked=$2; forward+=($1 $2); shift ;;
    --out) out=$2; shift ;;
    --host) host=$2; shift ;;
    --local) local_run=1 ;;
    --no-build) build=0; forward+=$1 ;;
    --resizable) resizable=1; forward+=$1 ;;
    -only-testing:*) tests+=$1; forward+=$1 ;;
    -h|--help) sed -n '2,33p' $0; exit 0 ;;
    *) print -u2 "unknown argument: $1 (see --help)"; exit 1 ;;
  esac
  shift
done
out=${out:A}

rows=()
for row in $ROWS; do
  id=${row%%|*}
  if [[ -n $picked ]]; then
    [[ ",$picked," == *",$id,"* ]] && rows+=$row
  elif [[ $mode == full || $row == *"|quick" ]]; then
    rows+=$row
  fi
done
(( ${#rows} )) || { print -u2 "no rows match: $picked"; exit 1; }

# A contact sheet per screen: that screen on every row, in the matrix's order, the same height.
# Needs ImageMagick; without it (a test Mac) the Mac that pulls the results makes them.
make_sheets() {
  if ! command -v magick >/dev/null; then
    print "sheets: none here (no ImageMagick)" >> $out/summary.txt
    return
  fi
  mkdir -p $out/sheets
  local -A seen
  local order=() s f row id args
  for row in $rows; do
    for f in $out/${row%%|*}/*.png(N); do
      s=${f:t:r}
      (( ${+seen[$s]} )) || { seen[$s]=1; order+=$s; }
    done
  done
  for s in $order; do
    args=()
    for row in $rows; do
      id=${row%%|*}
      f=$out/$id/$s.png
      [[ -f $f ]] && args+=(-label "$id $(magick identify -format '%wx%h' $f)" $f)
    done
    magick montage $args -tile x1 -geometry x900+16+16 -pointsize 22 -background '#e8e8e8' \
      -title $s $out/sheets/$s.png
  done
  sed -i '' '/^sheets: none here/d' $out/summary.txt
  print -r -- "sheets: ${#order} in $out/sheets" | tee -a $out/summary.txt
}

# On a test Mac: sync this checkout there, run the same matrix under the host's simulator lock,
# bring the shots, sheets, logs and summary back (not the result bundles), and make the sheets
# here if the host could not.
if [[ ${PLAIN_MATRIX_ON_HOST:-0} != 1 ]] && (( ! local_run )); then
  source scripts/lib/remote.zsh
  [[ -n $host ]] || host=$(remote_default_host)
  if [[ -n $host ]]; then
    lane=$(remote_lane)
    remote_out=build/matrix-out
    print "== matrix on $host (lane $lane)"
    rc=0
    remote_run $host $lane \
      "PLAIN_MATRIX_ON_HOST=1 ${PLAIN_SIM_PREFIX:+PLAIN_SIM_PREFIX=${(q)PLAIN_SIM_PREFIX}} scripts/matrix.sh ${(j: :)${(q)forward}} --out $remote_out" \
      || rc=$?
    rm -rf $out
    mkdir -p $out
    remote_pull $host $lane $remote_out/ $out/ --exclude '*.xcresult' || true
    [[ -f $out/summary.txt ]] || { print -u2 "no results came back from $host"; exit 1; }
    [[ -d $out/sheets ]] || make_sheets
    print "results: $out"
    exit $rc
  fi
fi

if [[ ${PLAIN_MATRIX_ON_HOST:-0} != 1 ]]; then
  print "matrix: running on this Mac (no --host, no PLAIN_TEST_HOST)"
fi
if (( ! ${#tests} )) || [[ "${tests[*]}" != *Capture* ]]; then
  if [[ $mode == full ]]; then
    tests+=(-only-testing:PlainUITests/CaptureTests -only-testing:PlainUITests/FocusCaptureTests)
  else
    tests+=(-only-testing:PlainUITests/FocusCaptureTests/testCaptureAddressFocus)
  fi
fi

# Every launch is isolated from the owner's data (docs/development.md, "Test isolation").
scripts/lib/check-isolation.zsh
(( build )) && scripts/build.sh

rm -rf $out
mkdir -p $out
summary=$out/summary.txt
note() { print -r -- "$*" | tee -a $summary; }

created=() background=()
cleanup() {
  for pid in $background; do kill $pid 2>/dev/null || true; done
  for udid in $created; do
    pkill -f "appResize start --device $udid" 2>/dev/null || true
    xcrun simctl shutdown $udid 2>/dev/null || true
    xcrun simctl delete $udid 2>/dev/null || true
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

sim_udid() {
  xcrun simctl list devices -j | jq -r --arg n "$1" '[.devices[][] | select(.name == $n)][0].udid // empty'
}

# Pixel area of an image (sips ships with macOS).
area() {
  sips -g pixelWidth -g pixelHeight $1 2>/dev/null | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w*h+0}'
}

# Keeps the app in the simulator's resizable window at the given size while the tests run,
# starting a new appResize session each time the tests relaunch the app.
keep_resized() {
  local udid=$1 size=$2 last="" pid session=""
  while true; do
    pid=$(xcrun simctl spawn $udid launchctl list 2>/dev/null | awk '/UIKitApplication:dev\.abrahamgonzalez\.plainbrowser\[/ {print $1; exit}')
    if [[ -n $pid && $pid != - && $pid != $last ]]; then
      [[ -n $session ]] && kill $session 2>/dev/null
      sleep 1
      xcrun devicectl device appResize start --device $udid --preferred-size $size >/dev/null 2>&1 &
      session=$!
      last=$pid
    fi
    sleep 2
  done
}

note "matrix: $mode, ${#rows} rows, tests: ${tests[*]#-only-testing:}"
note "started $(date '+%Y-%m-%d %H:%M'), $(git rev-parse --short HEAD 2>/dev/null || print unknown)"
failed=0
for row in $rows; do
  IFS='|' read -r id type screen size appearance motion _ <<<"$row"
  name=$PREFIX-$id
  dir=$out/$id
  mkdir -p $dir
  print "== $id ($type, $screen, text $size, $appearance, motion $motion)"

  # A simulator left by an earlier, killed run of this script has the same name: replace it.
  while udid=$(sim_udid $name) && [[ -n $udid ]]; do
    xcrun simctl shutdown $udid 2>/dev/null || true
    xcrun simctl delete $udid
  done
  runtime=$RUNTIME
  [[ $type == iPhone-Duo ]] && runtime=$DUO_RUNTIME
  udid=$(xcrun simctl create $name com.apple.CoreSimulator.SimDeviceType.$type $runtime)
  created+=$udid
  xcrun simctl boot $udid
  timeout 600 xcrun simctl bootstatus $udid >/dev/null
  xcrun simctl ui $udid appearance $appearance
  xcrun simctl ui $udid content_size $size
  if [[ $motion == reduce ]]; then
    xcrun simctl spawn $udid defaults write com.apple.Accessibility ReduceMotionEnabled -bool true
  fi

  orientation=portrait extra="" how=""
  case $screen in
    landscape) orientation=landscape ;;
    portrait) ;;
    *)  # The Duo: a fold state, then a rotation for the inner portrait rows.
      how="Device Hub"
      for step in ${(s:+:)screen}; do
        if (( resizable )) || ! scripts/duo-fold.sh $name $step >>$dir/duo-fold.log 2>&1; then
          how=""
          break
        fi
        sleep 2
      done
      if [[ -z $how && $screen == Open* ]]; then
        how="the resizable window, not the Duo's inner screen (Device Hub not driven: see $id/duo-fold.log)"
        extra="-PlainIgnoreOcclusions"
        window=951x669
        [[ $screen == *Rotate* ]] && window=669x951
        keep_resized $udid $window &
        background+=$!
      elif [[ -z $how ]]; then
        how="the simulator's default (closed); Device Hub not driven"
      fi
      ;;
  esac
  [[ -n $how ]] && note "$id: fold from $how"

  result=$dir/result.xcresult
  if env TEST_RUNNER_PLAIN_CAPTURE=1 TEST_RUNNER_PLAIN_CAPTURE_FAVORITES=1 TEST_RUNNER_PLAIN_CAPTURE_HISTORY=1 \
      TEST_RUNNER_PLAIN_CAPTURE_TAG=focus TEST_RUNNER_PLAIN_MATRIX_ARGS="$extra" \
      TEST_RUNNER_PLAIN_MATRIX_ORIENTATION=$orientation \
      xcodebuild -project Plain.xcodeproj -scheme Plain -destination "id=$udid" \
      -derivedDataPath build/sim -resultBundlePath $result \
      -test-timeouts-enabled YES -default-test-execution-time-allowance 300 \
      -maximum-test-execution-time-allowance 600 $tests \
      test-without-building > $dir/xcodebuild.log 2>&1; then
    verdict=passed
  else
    verdict=failed
    failed=1
  fi
  if [[ -n $extra ]]; then
    kill ${background[-1]} 2>/dev/null || true
    pkill -f "appResize start --device $udid" 2>/dev/null || true
  fi
  counts=""
  if [[ -f $result/Info.plist ]]; then
    counts=$(xcrun xcresulttool get test-results summary --path $result 2>/dev/null \
      | jq -r '"\(.passedTests) passed, \(.failedTests) failed, \(.skippedTests) skipped"' 2>/dev/null) || counts=""
    # The shots: one per screen name, the largest when a test attached every screen (the open
    # Duo's inner screen; FocusCaptureTests names those <screen>-<width>x<height>).
    if xcrun xcresulttool export attachments --path $result --output-path $dir/attachments >/dev/null 2>&1; then
      jq -r '.[].attachments[] | [.exportedFileName, .suggestedHumanReadableName] | @tsv' \
        $dir/attachments/manifest.json | while IFS=$'\t' read -r file label; do
        [[ $file == *.png || $file == *.jpeg || $file == *.jpg ]] || continue
        shot=${label%.*}
        shot=${shot%_[0-9]*_*}              # Xcode's _<index>_<uuid> suffix
        shot=${shot%-[0-9]##x[0-9]##}       # FocusCaptureTests' size suffix
        shot=${shot//[^A-Za-z0-9._-]/_}
        src=$dir/attachments/$file
        dst=$dir/$shot.png
        if [[ ! -f $dst ]] || (( $(area $src) > $(area $dst) )); then
          sips -s format png $src --out $dst >/dev/null
        fi
      done
    fi
    rm -rf $dir/attachments
  fi
  note "$id: $verdict${counts:+ ($counts)}$([[ -f $result/Info.plist ]] || print ' (no complete result bundle)'); log: $id/xcodebuild.log"
  # One booted simulator at a time: the machine is shared and often loaded.
  xcrun simctl shutdown $udid 2>/dev/null || true
  xcrun simctl delete $udid
  created=(${created:#$udid})
done

make_sheets
exit $failed
