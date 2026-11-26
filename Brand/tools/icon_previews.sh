#!/bin/zsh
# Render each icon colorway's Default rendition for the app's icon picker (first-run intro and
# Settings > App Icon) with Icon Composer's ictool. Rerun after gen_icon.py changes a colorway.
# Output: Packages/PlainKit/Sources/FeatureUI/Resources/AppIcons/<Name>.png, 180 px (60 pt @3x).
# Usage: icon_previews.sh
set -euo pipefail
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
BRAND="${0:A:h:h}"
OUT="$BRAND/../Packages/PlainKit/Sources/FeatureUI/Resources/AppIcons"
mkdir -p "$OUT"
for name in Dawn Night Coral Paper; do
  icon="$BRAND/AppIcon-$name.icon"; [[ $name == Dawn ]] && icon="$BRAND/AppIcon.icon"
  "$ICTOOL" "$icon" --export-image --output-file "$OUT/$name.png" --platform iOS --rendition Default \
    --width 180 --height 180 --scale 1 >/dev/null
  # 8-bit, no metadata: small and byte-stable for the same input.
  magick "$OUT/$name.png" -depth 8 -strip "$OUT/$name.png"
done
echo "rendered to ${OUT:A}"
