#!/bin/zsh
# Splits the Smoke test plan into <count> shards and prints shard <index>'s -only-testing flags,
# one per line. Used by .github/workflows/ci.yml to run Smoke on several runners at once.
#
#   scripts/lib/smoke-shards.zsh <count> <index>     index 1..count
#   scripts/lib/smoke-shards.zsh <count> --check     print the shards
#   scripts/lib/smoke-shards.zsh <count> --verify <file>
#        <file>: the test identifiers Xcode enumerates for the Smoke plan (Target/Class/test, one
#        per line; `xcodebuild -enumerate-tests`). Fails unless the shards' classes are exactly
#        the enumerated ones: none missing, none extra.
#
# The units are the Smoke plan's test classes: every XCTestCase subclass in PlainUITests except
# the ones Smoke.xctestplan skips (PerfTests), plus the hosted unit tests (PlainTests). A class is
# never split, so its setUp and order stay as they are. Shards are balanced by the tests that
# really run (a capture test that skips unless asked, "runs on request only", counts as nothing;
# every class at least 1), largest first, each to the lightest shard, so the split is the same on
# every runner.
# A new test class joins a shard by itself; a skipped class added to the plan leaves by itself.
set -euo pipefail
cd "${0:A:h:h:h}"

count=${1:?usage: smoke-shards.zsh <count> <index|--check>}
which=${2:?usage: smoke-shards.zsh <count> <index|--check>}
[[ $count == <1-> ]] || { print -u2 "count must be a positive number"; exit 1; }

skipped=(${(f)"$(jq -r '.testTargets[] | select(.target.name == "PlainUITests") | .skippedTests[]? | sub("/.*"; "")' PlainUITests/Smoke.xctestplan)"})
# Only whole classes may be skipped: a skipped single test would run in its shard.
if jq -e '.testTargets[] | select(.target.name == "PlainUITests") | .skippedTests[]? | select(contains("/"))' \
    PlainUITests/Smoke.xctestplan >/dev/null; then
  print -u2 "Smoke.xctestplan skips single tests; smoke-shards.zsh only knows whole classes"
  exit 1
fi
if jq -e '.testTargets[] | select(.selectedTests != null)' PlainUITests/Smoke.xctestplan >/dev/null; then
  print -u2 "Smoke.xctestplan selects tests; smoke-shards.zsh assumes it runs every test but the skipped classes"
  exit 1
fi

# "<tests> <target>/<class>" for every unit, sorted largest first, then by name.
setopt extended_glob
ui_files=(PlainUITests/**/*.swift(N))
unit_files=(PlainTests/**/*.swift(N))
# A test class must say XCTestCase itself: a class on a base of its own would be missed here
# (--verify, run by the CI, would also catch it).
while IFS= read -r line; do
  [[ -n $line ]] && { print -u2 "smoke-shards: a class with tests that is not a direct XCTestCase subclass: $line"; exit 1; }
done < <(for f in $ui_files $unit_files; do
  awk -v f=$f '
    /^[[:space:]]*((final|public|open|internal) )*class [A-Za-z0-9_]+ *:/ {
      cls = $0; direct = ($0 ~ /: *XCTestCase/) }
    /^[[:space:]]*func test/ && cls != "" && !direct { print f ": " cls; cls = "" }' $f
done)

units=()
for f in $ui_files; do
  for cls in ${(f)"$(grep -oE '^(final )?class [A-Za-z0-9_]+ *: *XCTestCase' $f | sed -E 's/.*class ([A-Za-z0-9_]+).*/\1/')"}; do
    [[ -z $cls ]] && continue
    (( ${skipped[(Ie)$cls]} )) && continue
    n=$(awk -v c=$cls '
      $0 ~ "class "c"[ :]" { inside = 1; next }
      inside && /^(final )?class / { inside = 0 }
      inside && /^[[:space:]]*func test/ { n++ }
      inside && /runs on request only/ { gated++ }
      END { n -= gated; print (n > 0 ? n : 0) }' $f)
    units+="$n PlainUITests/$cls"
  done
done
units+="$(cat $unit_files | grep -cE '^[[:space:]]*func test' || true) PlainTests"
units=(${(f)"$(print -l -- $units | sort -k1,1nr -k2,2)"})

typeset -A load shard_of
for i in {1..$count}; do load[$i]=0; done
for u in $units; do
  n=${u%% *} name=${u#* } best=1
  for i in {1..$count}; do (( load[$i] < load[$best] )) && best=$i; done
  shard_of[$name]=$best
  load[$best]=$(( load[$best] + (n > 0 ? n : 1) ))
done

if [[ $which == --verify ]]; then
  ids=${3:?usage: smoke-shards.zsh <count> --verify <file>}
  # The enumerated classes, as the shards name them: PlainUITests/<Class>, and PlainTests whole.
  enumerated=(${(f)"$(grep -E '^Plain(UI)?Tests/' $ids | awk -F/ '$1 == "PlainTests" { print "PlainTests"; next } { print $1 "/" $2 }' | sort -u)"})
  sharded=(${(f)"$(for u in $units; do print -r -- ${u#* }; done | sort -u)"})
  (( ${#enumerated} )) || { print -u2 "smoke-shards: no tests in $ids"; exit 1; }
  missing=(${enumerated:|sharded}) extra=(${sharded:|enumerated})
  # A class can be in the shards without tests Xcode lists (all gated by a condition it can't
  # see at enumeration time); that is harmless. A class Xcode lists that no shard runs is not.
  (( ${#missing} )) && { print -u2 "smoke-shards: in the Smoke plan but in no shard: ${missing[*]}"; exit 1; }
  (( ${#extra} )) && print "smoke-shards: sharded but not enumerated (no tests listed): ${extra[*]}"
  print "smoke-shards: ${#enumerated} enumerated classes, all in exactly one of $count shards"
  exit 0
fi
if [[ $which == --check ]]; then
  for i in {1..$count}; do
    print -r -- "shard $i: ${load[$i]} tests: $(for u in $units; do [[ ${shard_of[${u#* }]} == $i ]] && print -n "${u#* } "; done)"
  done
  (( ${#shard_of} == ${#units} )) || { print -u2 "a unit has no shard"; exit 1; }
  exit 0
fi
[[ $which == <1-> ]] && (( which <= count )) || { print -u2 "index must be 1..$count"; exit 1; }
for u in $units; do
  [[ ${shard_of[${u#* }]} == $which ]] && print -r -- "-only-testing:${u#* }"
done
true
