#!/bin/zsh
# The device matrix (docs/device-matrix.md): runs the capture tests, and any UI tests you name, on
# every screen class Plain supports, one simulator at a time, and makes a contact sheet per screen.
#
#   scripts/matrix.sh [--quick|--full] [--rows <id,id>] [--out <dir>] [--host <name> | --local]
#                     [--no-build] [--resizable] [-only-testing:<test>]...
#   scripts/matrix.sh --sheets-only --out <dir>    remake the contact sheets of an earlier run
#
#   --quick      the five screen-class rows (default): se, 17, max, duo-outer, duo-inner.
#   --full       every row: also mini, air, landscape, Duo inner portrait, large text, dark,
#                Reduce Motion. Before each TestFlight release, when the machine allows.
#   --rows       only these rows (ids from the table below, or docs/device-matrix.md).
#   --out        where the shots, sheets and logs go (default build/matrix; relative paths are
#                from the repo root). Emptied first.
#   --host       run on this test Mac (scripts/lib/remote.zsh) and bring the results back to
#                --out. `local`: this Mac's shared slot (waits for it). `auto:<name>`: this
#                Mac's slot when it is free, else <name>. Default: PLAIN_TEST_HOST, from the
#                environment or scripts/local.env.
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
# plain-matrix). Each is cloned from the Mac's template (scripts/lib/sim.zsh) for its row,
# booted alone, shut down after it and deleted; the exit trap deletes any this run made. No other
# simulator is touched (the templates stay; nothing boots them).
# The Duo's fold comes from scripts/duo-fold.sh (Device Hub). When Device Hub can't be driven
# (Mac locked, no Accessibility access), the inner rows fall back to the resizable window
# (devicectl appResize at the inner screen's size) and summary.txt says so.
set -euo pipefail
setopt extended_glob
source "${0:A:h}/lib/common.zsh"
source "${0:A:h}/lib/sim.zsh"

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

mode=quick out=build/matrix build=1 resizable=0 picked="" tests=() host="" local_run=0 forward=() sheets_only=0
while (( $# )); do
  case $1 in
    --quick|--full) mode=${1#--}; forward+=$1 ;;
    --rows) picked=$2; forward+=($1 $2); shift ;;
    --out) out=$2; shift ;;
    --host) host=$2; shift ;;
    --local) local_run=1 ;;
    --sheets-only) sheets_only=1 ;;
    --no-build) build=0; forward+=$1 ;;
    --resizable) resizable=1; forward+=$1 ;;
    -only-testing:*) tests+=$1; forward+=$1 ;;
    -h|--help) sed -n '2,36p' $0; exit 0 ;;
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

# Picks each shot's screen: a test may attach every screen (FocusCaptureTests), and on the Duo
# the screen that is off (the inner one while closed, the outer one while open) is black. The
# shot is the largest screen that shows something. In the resizable window that is the whole
# Resizable display, cut here to the window in its top left corner (<row>/.crop).
pick_shots() {
  local dir=$1 f base best area best_area crop="" picked=""
  [[ -f $dir/.crop ]] && crop=$(<$dir/.crop)
  local -A bases
  for f in $dir/*@*.png(N); do bases[${${f:t}%@*}]=1; done
  for base in ${(k)bases}; do
    best="" best_area=-1
    for f in $dir/$base@*.png(N); do
      # A black screen: (almost) no light in a small copy.
      (( $(magick $f -scale 64x64 -format '%[fx:int(mean*1000)]' info:) > 5 )) || continue
      area=$(magick identify -format '%[fx:w*h]' $f)
      (( area > best_area )) && { best=$f; best_area=$area; }
    done
    [[ -n $best ]] || best=$(ls -S $dir/$base@*.png | head -1)
    if [[ -n $crop && $best == *@2560x1440.png ]]; then
      magick $best -crop $crop +repage $dir/$base.png
    else
      magick $best $dir/$base.png
    fi
    picked=${best:t}
    rm -f $dir/$base@*.png(N)
  done
  if [[ -n $crop && -n $picked && $picked != *@2560x1440.png ]]; then
    print -r -- "${dir:t}: the resizable window showed nothing; its shots are another screen (see their sizes)" >> $out/summary.txt
  fi
  rm -f $dir/.crop
}

# A contact sheet per screen: that screen on every row, in the matrix's order, the same height,
# each labeled with its row and pixel size. Needs ImageMagick; without it (a test Mac) the Mac
# that pulls the results makes them.
make_sheets() {
  if ! command -v magick >/dev/null; then
    print "sheets: none here (no ImageMagick)" >> $out/summary.txt
    return
  fi
  local font=/System/Library/Fonts/Helvetica.ttc
  local -A seen
  local order=() s f row id tiles tmp
  for row in $rows; do
    pick_shots $out/${row%%|*}
    for f in $out/${row%%|*}/*.png(N); do
      s=${f:t:r}
      (( ${+seen[$s]} )) || { seen[$s]=1; order+=$s; }
    done
  done
  mkdir -p $out/sheets
  tmp=$out/sheets/.tiles
  for s in $order; do
    rm -rf $tmp; mkdir -p $tmp
    tiles=()
    for row in $rows; do
      id=${row%%|*}
      f=$out/$id/$s.png
      [[ -f $f ]] || continue
      magick $f -resize x900 -background '#e8e8e8' -gravity south -splice 0x40 -font $font \
        -pointsize 22 -annotate +0+8 "$id $(magick identify -format '%wx%h' $f)" \
        -bordercolor '#e8e8e8' -border 16 $tmp/${#tiles}.png
      tiles+=$tmp/${#tiles}.png
    done
    magick $tiles +append -background '#e8e8e8' -gravity north -splice 0x48 -font $font \
      -pointsize 28 -annotate +0+12 $s $out/sheets/$s.png
  done
  rm -rf $tmp
  sed -i '' '/^sheets: /d' $out/summary.txt
  print -r -- "sheets: ${#order} in $out/sheets" | tee -a $out/summary.txt
}

if (( sheets_only )); then
  [[ -f $out/summary.txt ]] || { print -u2 "no matrix run in $out"; exit 1; }
  rows=()
  for row in $ROWS; do [[ -d $out/${row%%|*} ]] && rows+=$row; done
  rm -rf $out/sheets
  make_sheets
  exit 0
fi

# --host local, or auto:<name> while this Mac's one shared slot is free: the same matrix here,
# nice'd, in that slot (scripts/lib/remote.zsh), then the build output removed. Otherwise, on a
# test Mac: sync this checkout there, run the same matrix in one of its job slots, bring the
# shots, sheets, logs and summary back (not the result bundles), and make the sheets here if the
# host could not.
if [[ ${PLAIN_MATRIX_ON_HOST:-0} != 1 ]] && (( ! local_run )); then
  source scripts/lib/remote.zsh
  [[ -n $host ]] || host=$(remote_default_host)
  if [[ $host == local || $host == auto:* ]]; then
    here="PLAIN_MATRIX_ON_HOST=1 ${PLAIN_SIM_PREFIX:+PLAIN_SIM_PREFIX=${(q)PLAIN_SIM_PREFIX}} scripts/matrix.sh ${(j: :)${(@q)forward}} --out ${(q)out}; r=\$?; rm -rf build/sim build/build.log; exit \$r"
    rc=0
    if [[ $host == local ]]; then
      print "== matrix on this Mac (local slot)"
      local_slot_run wait $here || rc=$?
      exit $rc
    fi
    local_slot_run try $here || rc=$?
    if (( rc != 75 )); then
      print "results: $out (this Mac's local slot)"
      exit $rc
    fi
    host=${host#auto:}
    print "matrix: this Mac's slot is taken; running on $host"
  fi
  if [[ -n $host ]]; then
    lane=$(remote_lane)
    remote_out=build/matrix-out
    print "== matrix on $host (lane $lane)"
    rc=0
    remote_run $host $lane \
      "rm -rf $remote_out; PLAIN_MATRIX_ON_HOST=1 ${PLAIN_SIM_PREFIX:+PLAIN_SIM_PREFIX=${(q)PLAIN_SIM_PREFIX}} scripts/matrix.sh ${(j: :)${(@q)forward}} --out $remote_out" \
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

# Keeps the app in the simulator's resizable window at the given size while the tests run,
# starting a new appResize session each time the tests relaunch the app.
keep_resized() {
  local udid=$1 size=$2 last="" pid session=""
  while true; do
    pid=$(xcrun simctl spawn $udid launchctl list 2>/dev/null | awk '/UIKitApplication:dev\.abrahamgonzalez\.plainbrowser\[/ {print $1; exit}')
    # A new app (the tests relaunched it), or a session that ended without taking the app.
    [[ -n $session ]] && ! kill -0 $session 2>/dev/null && last=""
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
  # A clone of the Mac's template for this device (scripts/lib/sim.zsh): its first-boot setup is
  # already done.
  udid=$(sim_new $name com.apple.CoreSimulator.SimDeviceType.$type $runtime)
  created+=$udid
  sim_boot $udid
  xcrun simctl ui $udid appearance $appearance
  xcrun simctl ui $udid content_size $size
  # A new simulator's keyboard first shows its slide-to-type introduction over the keys.
  xcrun simctl spawn $udid defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true
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
    # Every screen a test attached, as <screen>@<width>x<height>.png (FocusCaptureTests names
    # each <screen>-<width>x<height>); make_sheets picks one per screen (pick_shots).
    if xcrun xcresulttool export attachments --path $result --output-path $dir/attachments >/dev/null 2>&1; then
      jq -r '.[].attachments[] | [.exportedFileName, .suggestedHumanReadableName] | @tsv' \
        $dir/attachments/manifest.json | while IFS=$'\t' read -r file label; do
        [[ $file == *.png || $file == *.jpeg || $file == *.jpg ]] || continue
        shot=${label%.*}
        shot=${shot%_[0-9]*_*}              # Xcode's _<index>_<uuid> suffix
        size=main
        if [[ $shot == *-[0-9]##x[0-9]## ]]; then
          size=${shot##*-}
          shot=${shot%-*}
        fi
        shot=${shot//[^A-Za-z0-9._-]/_}
        sips -s format png $dir/attachments/$file --out $dir/$shot@$size.png >/dev/null
      done
    fi
    rm -rf $dir/attachments
    # In the resizable window the shots are the whole Resizable display (3x), the window in its
    # top left corner.
    [[ -n $extra ]] && print -r -- "$(( ${window%x*} * 3 ))x$(( ${window#*x} * 3 ))+0+0" > $dir/.crop
  fi
  note "$id: $verdict${counts:+ ($counts)}$([[ -f $result/Info.plist ]] || print ' (no complete result bundle)'); log: $id/xcodebuild.log"
  # One booted simulator at a time: the machine is shared and often loaded.
  xcrun simctl shutdown $udid 2>/dev/null || true
  xcrun simctl delete $udid
  created=(${created:#$udid})
done

make_sheets
exit $failed
