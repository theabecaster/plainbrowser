#!/bin/zsh
# Runs this checkout's committed state on GitHub's hosted runners (.github/workflows/ci.yml) and
# waits for the result: swift test, the Smoke plan sharded over several runners on the iPhone Duo
# and iPhone 17 simulators, and, when asked, matrix rows (one runner each). Free (public
# repository, standard runners), and nothing is left behind: the ci branch and the run are
# deleted afterwards (--keep keeps them).
#
#   scripts/ci.sh [--tests '<PlainUITests/Class[/test]> ...'] [--shards 1-4] [--devices duo,17]
#                 [--matrix none|quick|full] [--rows <id,id>] [--matrix-tests '<test> ...']
#                 [--no-unit] [--no-smoke] [--out <dir>] [--keep]
#
#   --tests         only these tests (on each device) instead of the whole Smoke plan
#   --shards        Smoke runners per device (default 3; ignored with --tests)
#   --matrix        scripts/matrix.sh rows on hosted runners: the Duo's inner rows use the
#                   resizable window (no Device Hub there). Shots and sheets land in --out
#                   (default build/ci-matrix), made here (ImageMagick).
#   --no-smoke      skip the Smoke plan (e.g. a matrix-only run)
#
# What goes up: one commit with no parents (this checkout's HEAD tree, uncommitted changes NOT
# included, plus .github/ci-request.json), by "Plain CI", pushed to ci/<lane> (PLAIN_LANE or the
# folder name). Nothing else: no history, no local.env, no signing config, no machine names.
# The repository is public, and so are the run's logs and artifacts while they exist.
# Exit status: 0 when every job passed.
set -euo pipefail
source "${0:A:h}/lib/common.zsh"

tests="" shards=3 devices="duo,17" matrix=none rows="" matrix_tests="" unit=true smoke=1 out=build/ci-matrix keep=0
while (( $# )); do
  case $1 in
    --tests) tests=$2; shift ;;
    --shards) shards=$2; shift ;;
    --devices) devices=$2; shift ;;
    --matrix) matrix=$2; shift ;;
    --rows) rows=$2; shift ;;
    --matrix-tests) matrix_tests=$2; shift ;;
    --no-unit) unit=false ;;
    --no-smoke) smoke=0 ;;
    --out) out=$2; shift ;;
    --keep) keep=1 ;;
    -h|--help) sed -n '2,24p' $0; exit 0 ;;
    *) print -u2 "unknown argument: $1 (see --help)"; exit 1 ;;
  esac
  shift
done
out=${out:A}
lane=${PLAIN_LANE:-${ROOT:t}}
[[ $lane =~ '^[A-Za-z0-9._-]+$' ]] || { print -u2 "PLAIN_LANE must be letters, digits, . _ -"; exit 1; }
branch=ci/$lane
git diff --quiet HEAD -- && git diff --cached --quiet HEAD -- \
  || print -u2 "ci: uncommitted changes are not included (only HEAD's tree goes up)"

devices_json=$(print -r -- ${(s:,:)devices} | tr ' ' '\n' | jq -R . | jq -sc 'map(select(length > 0))')
(( smoke )) || devices_json='[]'
request=$(jq -n --arg tests "$tests" --argjson shards $shards --argjson devices "$devices_json" \
  --arg matrix $matrix --arg rows "$rows" --arg mt "$matrix_tests" --argjson unit $unit '
  {tests: ($tests | split(" ") | map(select(length > 0))), shards: $shards, devices: $devices,
   matrix: $matrix, rows: $rows, matrixTests: ($mt | split(" ") | map(select(length > 0))), unit: $unit}')

# A parentless commit of HEAD's tree plus the request, in a throwaway index (the checkout, its
# index and its branches are untouched).
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
export GIT_INDEX_FILE=$tmp/index
git read-tree HEAD
blob=$(print -r -- $request | git hash-object -w --stdin)
git update-index --add --cacheinfo 100644,$blob,.github/ci-request.json
tree=$(git write-tree)
unset GIT_INDEX_FILE
commit=$(GIT_AUTHOR_NAME="Plain CI" GIT_AUTHOR_EMAIL=ci@plain.invalid GIT_COMMITTER_NAME="Plain CI" \
  GIT_COMMITTER_EMAIL=ci@plain.invalid git commit-tree $tree -m "ci: $lane")

repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
cleanup_remote() {
  (( keep )) && return
  git push -q origin --delete $branch 2>/dev/null || true
  [[ -n ${run:-} ]] && gh run delete $run -R $repo >/dev/null 2>&1 || true
}
trap 'cleanup_remote; rm -rf $tmp' EXIT
trap 'exit 130' INT TERM

git push -q -f origin $commit:refs/heads/$branch
print "ci: pushed $branch (${commit:0:10}); waiting for the run"
run=""
for i in {1..60}; do
  run=$(gh run list -R $repo --branch $branch --json databaseId,headSha \
    -q "[.[] | select(.headSha == \"$commit\")][0].databaseId // empty")
  [[ -n $run ]] && break
  sleep 5
done
[[ -n $run ]] || { print -u2 "ci: no run started for $branch"; exit 1; }
print "ci: run https://github.com/$repo/actions/runs/$run"
rc=0
gh run watch $run -R $repo --interval 30 --exit-status >/dev/null 2>&1 || rc=$?
gh run view $run -R $repo --json jobs -q '.jobs[] | "\(.conclusion // .status)\t\(.name)\t\((((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601)) / 60 | floor)) min"' 2>/dev/null \
  | column -t -s $'\t' || true
# Each Smoke job's summary and slowest tests.
gh run view $run -R $repo --log 2>/dev/null \
  | grep -E $'^smoke [^\t]*\tSmoke\t.*(Succeeded|Failed|passed, [0-9]+ failed|[0-9]+s (Failed|Expected))' \
  | sed -E $'s/\t[^\t]*\t[0-9TZ:.-]+ /: /' | head -80 || true

if [[ $(jq -r .matrix <<<$request) != none ]]; then
  rm -rf $out $tmp/dl
  mkdir -p $out
  if gh run download $run -R $repo -D $tmp/dl >/dev/null 2>&1; then
    for d in $tmp/dl/matrix-*(N/); do
      cp -R $d/. $out/
      [[ -f $d/summary.txt ]] && cat $d/summary.txt >> $tmp/summary.txt
    done
    [[ -f $tmp/summary.txt ]] && mv $tmp/summary.txt $out/summary.txt
    scripts/matrix.sh --sheets-only --out $out || true
    print "ci: matrix results in $out"
  else
    print -u2 "ci: could not download the matrix rows"
  fi
fi
exit $rc
