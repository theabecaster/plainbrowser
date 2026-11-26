#!/bin/zsh
# Screenshot every active display of the device (the Duo has two) into build/shots/.
# Files: build/shots/<name>-<display name>.png. Inactive (dark) displays are skipped.
# The device comes from PLAIN_DEVICE or scripts/local.env.
# Usage: scripts/shot.sh <name>
set -euo pipefail
source "${0:A:h}/lib/common.zsh"
require_device
NAME=${1:?usage: scripts/shot.sh <name>}

mkdir -p build/shots
displays=$(xcrun devicectl device info displays --device "$PLAIN_DEVICE" --timeout 30 -q -j - 2>/dev/null) || {
  print -u2 "error: the device is not reachable"; exit 2; }
count=0
while IFS=$'\t' read -r uid label active primary; do
  if [[ "$active" != true ]]; then
    echo "skipped $label (inactive)"
    continue
  fi
  out=build/shots/$NAME-$label.png
  xcrun devicectl device capture screenshot --device "$PLAIN_DEVICE" --timeout 30 -q \
    --display-unique-id "$uid" --destination "$out"
  echo "$out$([[ $primary == true ]] && echo " (primary)")"
  count=$((count + 1))
done < <(jq -r '.result.displays[] | [.uniqueId, .name, .active, .primary] | @tsv' <<<"$displays")
(( count > 0 )) || { print -u2 "error: no active display (is the device asleep?)"; exit 2; }
