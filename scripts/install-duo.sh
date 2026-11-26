#!/bin/zsh
# Build a Release copy of the current tree, install it on the device and launch it.
# The device comes from PLAIN_DEVICE or scripts/local.env.
# Usage: scripts/install-duo.sh [--no-launch] [build-number]   (default build: yyMMddHHmm)
#   --no-launch   install only; never touches the running apps (works on a locked phone).
# Best effort: a failed install (phone unreachable, or one that refuses while locked) prints a
# note and exits 0, so a pipeline that ends with an install never fails or hangs on a sleeping
# phone. A failed build still exits 1. Launching needs an unlocked phone; when it is locked the
# launch is skipped with a note.
set -euo pipefail
source "${0:A:h}/lib/common.zsh"
require_device
LAUNCH=1
if [[ "${1:-}" == --no-launch ]]; then LAUNCH=0; shift; fi
BUILD=${1:-$(date +%y%m%d%H%M)}

xcodegen generate --quiet
mkdir -p build
if ! xcodebuild -project Plain.xcodeproj -scheme Plain -configuration Release -destination "id=$PLAIN_DEVICE" \
    -derivedDataPath build/device -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CURRENT_PROJECT_VERSION=$BUILD build > build/install-duo.log 2>&1; then
  grep -E 'error:' build/install-duo.log | sort -u | head -20
  print -u2 "build failed; full log: build/install-duo.log"
  exit 1
fi
if ! xcrun devicectl device install app --device "$PLAIN_DEVICE" --timeout 120 \
    build/device/Build/Products/Release-iphoneos/Plain.app > build/install-duo-device.log 2>&1; then
  grep -iE 'error|locked|unavailable|timed out' build/install-duo-device.log | head -5
  echo "note: build $BUILD built but not installed (device locked or unreachable); log: build/install-duo-device.log"
  exit 0
fi
echo "installed build $BUILD"
(( LAUNCH )) || exit 0
if ! check_device_unlocked; then
  echo "note: launch skipped"
  exit 0
fi
xcrun devicectl device process launch --device "$PLAIN_DEVICE" --timeout 60 --terminate-existing \
  dev.abrahamgonzalez.plainbrowser > /dev/null || echo "note: installed, but the launch failed"
echo "launched build $BUILD"
