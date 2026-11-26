#!/bin/zsh
# Build a Release copy of the current tree, install it on the device and launch it.
# The device comes from PLAIN_DEVICE or scripts/local.env.
# Best effort: when the device is locked or unreachable it prints a note and exits 0 without
# building, so a pipeline that ends with an install never fails or hangs on a sleeping phone.
# Usage: scripts/install-duo.sh [build-number]   (default: yyMMddHHmm)
set -euo pipefail
source "${0:A:h}/lib/common.zsh"
require_device
BUILD=${1:-$(date +%y%m%d%H%M)}
if ! check_device_unlocked; then
  echo "note: skipped the device install"
  exit 0
fi

xcodegen generate --quiet
mkdir -p build
if ! xcodebuild -project Plain.xcodeproj -scheme Plain -configuration Release -destination "id=$PLAIN_DEVICE" \
    -derivedDataPath build/device -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CURRENT_PROJECT_VERSION=$BUILD build > build/install-duo.log 2>&1; then
  grep -E 'error:' build/install-duo.log | sort -u | head -20
  print -u2 "build failed; full log: build/install-duo.log"
  exit 1
fi
xcrun devicectl device install app --device "$PLAIN_DEVICE" --timeout 120 \
  build/device/Build/Products/Release-iphoneos/Plain.app | grep -E 'App installed' || {
  print -u2 "install failed (is the device awake and reachable?)"; exit 1; }
xcrun devicectl device process launch --device "$PLAIN_DEVICE" --timeout 60 --terminate-existing \
  dev.abrahamgonzalez.plainbrowser > /dev/null || {
  print -u2 "installed, but launch failed (a locked device refuses launches)"; exit 1; }
echo "installed and launched build $BUILD"
