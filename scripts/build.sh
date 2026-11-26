#!/bin/zsh
# Generate the Xcode project and build the app for the simulator (Debug). No simulator needed.
# Usage: scripts/build.sh
# Output: build/sim (derived data), log in build/build.log.
set -euo pipefail
source "${0:A:h}/lib/common.zsh"

xcodegen generate --quiet
mkdir -p build
if ! xcodebuild -project Plain.xcodeproj -scheme Plain -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build/sim \
    build-for-testing > build/build.log 2>&1; then
  grep -E 'error:' build/build.log | sort -u | head -20
  print -u2 "build failed; full log: build/build.log"
  exit 1
fi
grep -E '^/.*warning:' build/build.log | grep -v '/SourcePackages/' | sort -u || true
echo "build ok"
