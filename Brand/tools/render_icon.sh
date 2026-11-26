#!/bin/zsh
# Render an Icon Composer document for review with Icon Composer's ictool:
# every iOS rendition at 1024, the Default rendition at home-screen, Spotlight,
# Settings and notification sizes, the mark's 60 px silhouette, home-screen
# mockups on a light and a dark wallpaper, and one comparison sheet.
# Usage: render_icon.sh <out-dir> [icon] [silhouette.svg]
#   icon defaults to Brand/AppIcon.icon. Brand/preview.png is the Default 1024.
set -euo pipefail
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
FONT=/System/Library/Fonts/Helvetica.ttc
BRAND="${0:A:h:h}"
OUT="${1:?out dir}"; ICON="${2:-$BRAND/AppIcon.icon}"; SIL="${3:-}"
mkdir -p "$OUT"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ic() { "$ICTOOL" "$ICON" --export-image --output-file "$1" --platform iOS --rendition "$2" \
       --width "$3" --height "$3" --scale 1 >/dev/null && magick "$1" -depth 8 "$1"; }

RENDS=(Default Dark TintedLight TintedDark ClearLight ClearDark)
for r in $RENDS; do ic "$OUT/$r-1024.png" $r 1024; done
SIZES=(180 120 80 60 58 40 29 20)
for s in $SIZES; do ic "$OUT/Default-$s.png" Default $s; ic "$OUT/TintedDark-$s.png" TintedDark $s; done
[[ -n "$SIL" ]] && magick "$SIL" -resize 60x60 -depth 8 "$OUT/silhouette-60.png"

# Home-screen mockups at device pixels (@3x, 60 pt icons), light and dark wallpaper.
mock() {   # $1 name, $2 wallpaper gradient, $3 glow, $4 rendition
  W=1179; H=1180
  magick -size ${W}x${H} gradient:"$2" \( -size ${W}x${H} radial-gradient:"$3"-none \) -compose over -composite "$tmp/wall.png"
  ic "$tmp/icon.png" "$4" 180
  magick "$tmp/icon.png" -alpha extract -strip "$tmp/a.miff"
  cols=('#C9CDD4' '#A9B4C2' '#D8CFC4' '#B7C4B5' '#C4B8CF' '#BFC9D1' '#D4C6BA' '#AEB8AC' '#C2C2CC' '#CFC0B4' '#B4BECB')
  [[ "$4" == Dark ]] && cols=('#3A3D46' '#2F3644' '#45403A' '#36403A' '#3E3846' '#36404A' '#4A4038' '#343C34' '#3C3C46' '#463C34' '#343C48')
  names=(Mail Notes Maps Photos Music Files Clock Weather Camera Wallet Books)
  args=(); i=1
  for row in 0 1 2; do
    for col in 0 1 2 3; do
      x=$((84 + col*279)); y=$((120 + row*330))
      if (( row == 1 && col == 1 )); then
        icon="$tmp/icon.png"; label=Plain
      else
        magick -size 180x180 xc:"${cols[$i]}" \
          \( -size 180x180 gradient:'#FFFFFF33'-'#00000022' \) -compose over -composite \
          -fill '#FFFFFF66' -draw "roundrectangle 58,58 122,122 18,18" \
          "$tmp/a.miff" -alpha off -compose copy-opacity -composite "$tmp/p$i.png"
        icon="$tmp/p$i.png"; label=${names[$i]}; i=$((i+1))
      fi
      args+=( -gravity northwest "$icon" -geometry +$x+$y -compose over -composite )
      dx=$((x + 90 - W/2)); sx=+; (( dx < 0 )) && sx=-
      args+=( -font $FONT -pointsize 36 -fill white -gravity north -annotate ${sx}${dx#-}+$((y + 196)) "$label" )
    done
  done
  magick "$tmp/wall.png" $args -depth 8 "$OUT/home-$1.png"
}
mock light '#B9C7E6-#7B86B8' '#FFE7D6C0' Default
mock dark '#2B2F45-#0C0E18' '#4A3A5A90' Dark

# Comparison sheet: renditions, then sizes (actual pixels), then silhouette.
big=(); for r in $RENDS; do big+=(-label $r "$OUT/$r-1024.png"); done
magick montage -font $FONT -pointsize 22 -fill '#E8E8EE' -background '#1C1D24' \
  $big -tile 6x1 -geometry '300x300>+12+10' "$tmp/r1.png"
small=(); for s in $SIZES; do small+=(-label "$s" "$OUT/Default-$s.png"); done
for s in 60 40 29 20; do small+=(-label "tinted $s" "$OUT/TintedDark-$s.png"); done
[[ -f "$OUT/silhouette-60.png" ]] && small+=(-label silhouette "$OUT/silhouette-60.png")
magick montage -font $FONT -pointsize 20 -fill '#E8E8EE' -background '#1C1D24' $small \
  -tile $(( ${#small} / 3 ))x1 -geometry '+18+14' "$tmp/r2.png"
magick montage -background '#1C1D24' "$OUT/home-light.png" "$OUT/home-dark.png" -tile 2x1 -geometry '900x900>+12+12' "$tmp/r3.png"
magick "$tmp/r1.png" "$tmp/r2.png" "$tmp/r3.png" -background '#1C1D24' -gravity center -append -depth 8 "$OUT/comparison.png"
echo "rendered to $OUT"
