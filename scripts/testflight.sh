#!/bin/zsh
# Ship the current checkout to TestFlight: archive a Release build on this Mac, upload it, wait
# for App Store Connect to process it, set "What to Test", and give it to the beta group. For an
# external group it also submits the build to Beta App Review and waits for approval.
#
# Usage: scripts/testflight.sh <notes-file> [--build N] [--skip-upload] [--cloud | --auto] [--dry-run]
#   notes-file     the "What to Test" text (at most 4000 characters)
#   --build N      build number (default yyMMddHHmm); must be higher than the last upload
#   --skip-upload  continue with build N, already uploaded (needs --build)
#   --cloud        archive the pushed branch head on Xcode Cloud instead of this Mac
#   --auto         --cloud when this Mac is busy and Xcode Cloud can take it, else local
#   --dry-run      check the setup with read-only calls; builds, uploads and changes nothing
#
# Settings come from the environment or scripts/local.env: ASC_KEY_ID, ASC_ISS, optional ASC_KEY,
# TESTFLIGHT_APP_ID, TESTFLIGHT_GROUP_ID, XCODE_CLOUD_WORKFLOW_ID (for --cloud and --auto).
# See docs/development.md, TestFlight and Xcode Cloud.
set -euo pipefail
source "${0:A:h}/lib/common.zsh"
# scripts/local.env fills in what the environment leaves unset; the environment wins.
typeset -A _env
for v in ASC_KEY_ID ASC_ISS ASC_KEY TESTFLIGHT_APP_ID TESTFLIGHT_GROUP_ID XCODE_CLOUD_WORKFLOW_ID; do [[ -n ${(P)v:-} ]] && _env[$v]=${(P)v}; done
[[ -f scripts/local.env ]] && source scripts/local.env
for v in ${(k)_env}; do typeset -g $v=${_env[$v]}; done

usage() { print -u2 "usage: scripts/testflight.sh <notes-file> [--build N] [--skip-upload] [--cloud | --auto] [--dry-run]"; exit 2; }
die() { print -u2 "testflight.sh: $*"; exit 1; }
say() { print -r -- "$(date +%H:%M:%S) $*"; }

NOTES_FILE="" BUILD="" SKIP_UPLOAD=0 DRY=0 WHERE=local
while (( $# )); do
  case $1 in
    --build) (( $# >= 2 )) || usage; BUILD=$2; shift 2 ;;
    --skip-upload) SKIP_UPLOAD=1; shift ;;
    --cloud) [[ $WHERE == local ]] || usage; WHERE=cloud; shift ;;
    --auto) [[ $WHERE == local ]] || usage; WHERE=auto; shift ;;
    --dry-run) DRY=1; shift ;;
    -*) usage ;;
    *) [[ -z $NOTES_FILE ]] || usage; NOTES_FILE=$1; shift ;;
  esac
done
[[ -n $NOTES_FILE ]] || usage
(( SKIP_UPLOAD )) && [[ -z $BUILD ]] && die "--skip-upload needs --build"
(( SKIP_UPLOAD )) && [[ $WHERE != local ]] && die "--skip-upload builds nothing, so it takes no --cloud or --auto"
BUILD=${BUILD:-$(date +%y%m%d%H%M)}
[[ $BUILD =~ '^[0-9]+$' ]] || die "build number '$BUILD' must be digits"
[[ -f $NOTES_FILE ]] || die "no notes file at $NOTES_FILE"
NOTES=$(<$NOTES_FILE)
[[ -n ${NOTES//[[:space:]]/} ]] || die "$NOTES_FILE is empty"
(( ${#NOTES} <= 4000 )) || die "notes have ${#NOTES} characters; App Store Connect takes 4000"

for v in ASC_KEY_ID ASC_ISS TESTFLIGHT_APP_ID TESTFLIGHT_GROUP_ID; do
  [[ -n ${(P)v:-} ]] || die "$v is not set (environment or scripts/local.env)"
done
export ASC_KEY_ID ASC_ISS
ASC_KEY=${ASC_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
export ASC_KEY
[[ -f $ASC_KEY ]] || die "no API key file at $ASC_KEY"
APP_ID=$TESTFLIGHT_APP_ID GROUP_ID=$TESTFLIGHT_GROUP_ID

# asc METHOD PATH [BODY]: prints the body; fails with Apple's error text unless the status is 2xx.
asc() {
  local out code body
  out=$(node scripts/asc.mjs "$@") || { print -u2 "testflight.sh: $1 $2 did not complete"; return 1; }
  code=${out%%$'\n'*}; body=${out#*$'\n'}
  if [[ $code != 2?? ]]; then
    print -u2 "testflight.sh: $1 $2 answered $code: $(print -r -- "$body" | json 'd.errors?.map(e=>e.detail||e.title).join("; ")' 2>/dev/null)"
    return 1
  fi
  print -r -- "$body"
}
# json EXPR: evaluates EXPR on the JSON read from stdin (`d` is the value) and prints it.
json() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const d=JSON.parse(s);const v=new Function("d","return ("+process.argv[1]+")")(d);console.log(v??"")})' "$1"
}
build_state() {
  asc GET "/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD&fields%5Bbuilds%5D=processingState&limit=1" \
    | json 'd.data?.[0] ? d.data[0].id+" "+d.data[0].attributes.processingState : ""'
}
review_state() {
  asc GET "/v1/builds/$1/betaAppReviewSubmission?fields%5BbetaAppReviewSubmissions%5D=betaReviewState" 2>/dev/null \
    | json 'd.data?.attributes?.betaReviewState' 2>/dev/null || true
}

APP=$(asc GET "/v1/apps/$APP_ID?fields%5Bapps%5D=name,bundleId" | json 'd.data.attributes.name+" ("+d.data.attributes.bundleId+")"') \
  || die "App Store Connect has no app $APP_ID for this key"
GROUP=$(asc GET "/v1/betaGroups/$GROUP_ID?fields%5BbetaGroups%5D=name,isInternalGroup" \
  | json 'd.data.attributes.name+(d.data.attributes.isInternalGroup?" internal":" external")') \
  || die "App Store Connect has no beta group $GROUP_ID"
INTERNAL=0; [[ $GROUP == *" internal" ]] && INTERNAL=1
BRANCH=$(git rev-parse --abbrev-ref HEAD)
say "build $BUILD of $BRANCH $(git rev-parse --short HEAD) for $APP, group ${GROUP% *}"

# Why this Mac is too busy to archive, or nothing. Two xcodebuilds already compete for the CPU.
# A 1-minute load above 1.5x the core count means every core already has more work queued than it
# runs (one archive alone sits near 1x), so a local archive would take far longer and slow the rest.
busy_reason() {
  local cores load builds
  cores=$(sysctl -n hw.ncpu); load=$(sysctl -n vm.loadavg | awk '{print $2}')
  builds=$({ pgrep -x xcodebuild || true; } | wc -l | tr -d ' ')
  if (( builds >= 2 )); then print -r -- "$builds xcodebuild processes running"
  elif (( load > cores * 1.5 )); then print -r -- "1-minute load $load is over 1.5 x $cores cores"
  fi
}
# Why Xcode Cloud can't build what this checkout would ship, or nothing. It builds the pushed head.
cloud_blocker() {
  [[ -n ${XCODE_CLOUD_WORKFLOW_ID:-} ]] || { print "Xcode Cloud is not set up (no XCODE_CLOUD_WORKFLOW_ID)"; return; }
  [[ $BRANCH != HEAD ]] || { print "HEAD is detached"; return; }
  [[ -z $(git status --porcelain) ]] || { print "uncommitted changes would not ship"; return; }
  [[ $(git ls-remote origin "refs/heads/$BRANCH" | cut -f1) == $(git rev-parse HEAD) ]] \
    || print "HEAD is not the pushed head of origin/$BRANCH"
}
CLOUD_FALLBACK=0
if (( ! SKIP_UPLOAD )); then
  if [[ $WHERE == auto ]]; then
    WHY=$(busy_reason)
    if [[ -z $WHY ]]; then
      WHERE=local; say "this Mac is free: archiving here"
    elif B=$(cloud_blocker); [[ -n $B ]]; then
      WHERE=local; say "busy ($WHY), but $B: archiving here"
    else
      WHERE=cloud CLOUD_FALLBACK=1; say "busy ($WHY): archiving on Xcode Cloud"
    fi
  elif [[ $WHERE == cloud ]]; then
    B=$(cloud_blocker); [[ -z $B ]] || die "--cloud: $B"
  fi
fi
export TESTFLIGHT_APP_ID XCODE_CLOUD_WORKFLOW_ID

if (( DRY )); then
  [[ -z $(git status --porcelain) ]] || say "note: uncommitted changes would ship"
  (( SKIP_UPLOAD )) || [[ -z $(build_state) ]] || die "build $BUILD already exists; pick a higher number"
  if [[ $WHERE == cloud ]] && ! node scripts/xcode-cloud.mjs start "$BRANCH" --dry-run; then
    (( CLOUD_FALLBACK )) || die "Xcode Cloud can't start"
    say "Xcode Cloud can't start; would archive here"
  fi
  say "dry run: setup is fine; nothing built or changed"
  exit 0
fi

if (( ! SKIP_UPLOAD )); then
  [[ -z $(build_state) ]] || die "build $BUILD already exists; pick a higher number"
  TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Signing.local.xcconfig 2>/dev/null | head -1)
  [[ -n $TEAM ]] || die "no DEVELOPMENT_TEAM in Config/Signing.local.xcconfig"
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISS")
  OUT=build/testflight; rm -rf $OUT; mkdir -p $OUT
  cat > $OUT/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF
  ARCHIVE=$OUT/Plain.xcarchive
  if [[ $WHERE == cloud ]]; then
    if node scripts/xcode-cloud.mjs start "$BRANCH" > $OUT/cloud.log 2>&1; then
      cat $OUT/cloud.log; RUN=$(tail -1 $OUT/cloud.log)
    else
      cat $OUT/cloud.log >&2
      (( CLOUD_FALLBACK )) || die "Xcode Cloud did not start"
      WHERE=local; say "Xcode Cloud did not start: archiving here"
    fi
  fi
  if [[ $WHERE == cloud ]]; then
    node scripts/xcode-cloud.mjs wait "$RUN" || die "no cloud archive; see run $RUN"
    ARCHIVE=$(node scripts/xcode-cloud.mjs fetch "$RUN" $OUT/cloud | tail -1) || die "could not download the archive of run $RUN"
    # Xcode Cloud builds with its own number; the upload gets this script's, so the order holds.
    # The export below re-signs the app, so changing its Info.plist here is safe.
    /usr/libexec/PlistBuddy -c "Set :ApplicationProperties:CFBundleVersion $BUILD" "$ARCHIVE/Info.plist"
    for P in "$ARCHIVE"/Products/Applications/*.app/Info.plist(N) "$ARCHIVE"/Products/Applications/*.app/PlugIns/*.appex/Info.plist(N); do
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$P"
    done
    say "cloud archive of run $RUN is build $BUILD"
  else
    xcodegen generate --quiet
    say "archiving (log: $OUT/archive.log)"
    xcodebuild -project Plain.xcodeproj -scheme Plain -configuration Release -destination 'generic/platform=iOS' \
        -archivePath $ARCHIVE -derivedDataPath build/device "${AUTH[@]}" \
        CURRENT_PROJECT_VERSION=$BUILD archive > $OUT/archive.log 2>&1 \
      || { grep -E 'error:' $OUT/archive.log | sort -u | head -20; die "archive failed"; }
  fi
  say "uploading (log: $OUT/upload.log)"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist $OUT/ExportOptions.plist \
      -exportPath $OUT/export "${AUTH[@]}" > $OUT/upload.log 2>&1 \
    || { grep -iE 'error' $OUT/upload.log | sort -u | head -20; die "upload failed"; }
  rm -rf $OUT/Plain.xcarchive $OUT/cloud $OUT/export
  # The tag marks what each build contains, so the next build's notes start from it.
  git tag "tf/$BUILD" HEAD && git push -q origin "tf/$BUILD" || say "note: could not tag tf/$BUILD"
fi

ID="" ST=""
for i in {1..90}; do
  R=$(build_state) || R=""
  [[ -n $R ]] && { ID=${R%% *}; ST=${R#* }; }
  say "processing: ${ST:-not there yet}"
  [[ $ST == VALID ]] && break
  [[ $ST == (INVALID|FAILED) ]] && die "build $BUILD is $ST in App Store Connect"
  sleep 30
done
[[ -n $ID && $ST == VALID ]] || die "build $BUILD did not become VALID in 45 minutes; rerun with --skip-upload --build $BUILD"

NOTES_JSON=$(print -r -- "$NOTES" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>console.log(JSON.stringify(s.replace(/\n$/,""))))')
LOCS=$(asc GET "/v1/builds/$ID/betaBuildLocalizations?fields%5BbetaBuildLocalizations%5D=locale" | json 'd.data.map(x=>x.id).join(" ")')
if [[ -z $LOCS ]]; then
  asc POST /v1/betaBuildLocalizations "{\"data\":{\"type\":\"betaBuildLocalizations\",\"attributes\":{\"locale\":\"en-US\",\"whatsNew\":$NOTES_JSON},\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$ID\"}}}}}" >/dev/null \
    || die "could not set the notes"
else
  for LOC in ${=LOCS}; do
    asc PATCH "/v1/betaBuildLocalizations/$LOC" "{\"data\":{\"type\":\"betaBuildLocalizations\",\"id\":\"$LOC\",\"attributes\":{\"whatsNew\":$NOTES_JSON}}}" >/dev/null \
      || die "could not set the notes"
  done
fi
say "notes set"

if (( ! INTERNAL )); then
  OUT_ERR=$(mktemp); trap "rm -f $OUT_ERR" EXIT
  if [[ -z $(review_state $ID) ]]; then
    # Only one build per version can be in review; wait for the one ahead (up to 4 hours).
    for i in {1..120}; do
      asc POST /v1/betaAppReviewSubmissions "{\"data\":{\"type\":\"betaAppReviewSubmissions\",\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$ID\"}}}}}" >/dev/null 2>$OUT_ERR \
        && break
      grep -q "already in beta review" $OUT_ERR || { cat $OUT_ERR >&2; die "could not submit for Beta App Review"; }
      (( i == 1 )) && say "another build is in review; waiting to submit"
      # Testers only need the newest build: a newer upload takes over this build's place in line.
      NEWEST=$(asc GET "/v1/builds?filter%5Bapp%5D=$APP_ID&sort=-version&fields%5Bbuilds%5D=version&limit=1" | json 'd.data?.[0]?.attributes.version')
      if (( NEWEST > BUILD )); then say "build $NEWEST is newer; not submitting $BUILD"; exit 0; fi
      sleep 120
    done
    grep -q "already in beta review" $OUT_ERR 2>/dev/null && [[ -z $(review_state $ID) ]] && die "the build ahead stayed in review for 4 hours; rerun with --skip-upload --build $BUILD"
    say "submitted for Beta App Review"
  fi
  RS=""
  for i in {1..120}; do
    RS=$(review_state $ID)
    say "review: ${RS:-unknown}"
    [[ $RS == APPROVED ]] && break
    [[ $RS == REJECTED ]] && die "Beta App Review rejected build $BUILD"
    sleep 60
  done
  [[ $RS == APPROVED ]] || die "not approved in 2 hours; rerun with --skip-upload --build $BUILD"
fi

# An internal group set to "all builds" gets every valid build by itself.
if (( INTERNAL )); then
  rm -rf build/testflight
  say "done: build $BUILD is available to ${GROUP% *}"
  exit 0
fi
for i in {1..5}; do
  if asc POST "/v1/betaGroups/$GROUP_ID/relationships/builds" "{\"data\":[{\"type\":\"builds\",\"id\":\"$ID\"}]}" >/dev/null; then
    rm -rf build/testflight
    say "done: build $BUILD is in ${GROUP% *}"
    exit 0
  fi
  sleep 30
done
die "could not add build $BUILD to the group"
