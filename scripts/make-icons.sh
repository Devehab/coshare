#!/bin/bash
# Renders every CoShare app icon from the mark in website/assets/logo.svg:
# vermilion square, two paper documents. Small sizes drop the fold and text lines so they stay crisp.
#   scripts/make-icons.sh
# Needs rsvg-convert and ImageMagick (brew install librsvg imagemagick); iconutil ships with macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SIGNAL='#d24a22'
PAPER='#f5f0e8'

# The two documents on the mark's 64×64 grid. $1 = full (fold + text lines) or small.
docs() {
  echo "<rect x='25' y='12' width='24' height='31' rx='5' fill='$PAPER' opacity='.5'/>"
  echo "<path d='M19.5 21H32l8 8v19a4 4 0 0 1-4 4H19.5a4 4 0 0 1-4-4V25a4 4 0 0 1 4-4z' fill='$PAPER'/>"
  if [ "$1" = full ]; then
    echo "<path d='M32 21v5.5a2.5 2.5 0 0 0 2.5 2.5H40' fill='none' stroke='$SIGNAL' stroke-width='2.4' stroke-linejoin='round'/>"
    echo "<path d='M22 38.5h11M22 44h7' stroke='$SIGNAL' stroke-width='2.6' stroke-linecap='round'/>"
  fi
}

# $1 = style, $2 = full|small. All styles are drawn on a 1024 canvas.
#   ios     full-bleed square (iOS applies its own mask)
#   mac     macOS grid: 824 square, 100 margin, soft shadow
#   desktop Windows/Linux: 896 square with the website's 25% corners
#   tray    tray/panel glyph: nearly full square, readable on light and dark panels
svg() {
  local x=0 size=1024 radius=0 shadow=0
  case "$1" in
    ios) ;;
    mac) x=100; size=824; radius=185.4; shadow=1 ;;
    desktop) x=64; size=896; radius=224 ;;
    tray) x=32; size=960; radius=230 ;;
  esac
  echo "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1024 1024' width='1024' height='1024'>"
  if [ "$shadow" = 1 ]; then
    echo "<filter id='shadow' x='-10%' y='-10%' width='120%' height='130%'><feGaussianBlur stdDeviation='12'/></filter>"
    echo "<rect x='$x' y='$((x + 10))' width='$size' height='$size' rx='$radius' fill='#000' opacity='.3' filter='url(#shadow)'/>"
  fi
  echo "<rect x='$x' y='$x' width='$size' height='$size' rx='$radius' fill='$SIGNAL'/>"
  # Small sizes also enlarge the documents a little around the centre so they read at 16 px.
  local zoom=1; [ "$2" = small ] && zoom=1.12
  echo "<g transform='translate($x $x) scale($(echo "$size / 64" | bc -l)) translate(32 32) scale($zoom) translate(-32 -32)'>"
  docs "$2"
  echo "</g></svg>"
}

# render <style> <full|small> <pixels> <out.png>
render() {
  svg "$1" "$2" > "$TMP/$1-$2.svg"
  rsvg-convert -w "$3" -h "$3" "$TMP/$1-$2.svg" -o "$4"
}
detail() { [ "$1" -le 32 ] && echo small || echo full; }

# macOS: asset catalog (Xcode) + AppIcon.icns (scripts/build-mac.sh).
MAC_SET=macOS/Assets.xcassets/AppIcon.appiconset
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((pt * scale))
    if [ "$scale" = 1 ]; then name="icon_${pt}"; else name="icon_${pt}@2x"; fi
    render mac "$(detail "$px")" "$px" "$MAC_SET/$name.png"
    if [ "$scale" = 1 ]; then cp "$MAC_SET/$name.png" "$ICONSET/icon_${pt}x${pt}.png"
    else cp "$MAC_SET/$name.png" "$ICONSET/icon_${pt}x${pt}@2x.png"; fi
  done
done
iconutil -c icns "$ICONSET" -o Config/AppIcon.icns

# iOS: one 1024 image, no alpha channel (App Store requirement).
render ios full 1024 "$TMP/ios.png"
magick "$TMP/ios.png" -background "$SIGNAL" -alpha remove -alpha off iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png

# Windows + Linux (Electron): packaging icon, a hand-sized .ico, the window icon and the tray glyph.
render desktop full 1024 desktop/build/icon.png
for px in 16 24 32 48 64 128 256; do render desktop "$(detail "$px")" "$px" "$TMP/ico-$px.png"; done
magick "$TMP"/ico-{16,24,32,48,64,128,256}.png desktop/build/icon.ico
render desktop full 512 desktop/src/assets/icon.png
render tray small 64 desktop/src/assets/tray.png

echo "✓ Icons written: $MAC_SET, Config/AppIcon.icns, iOS AppIcon, desktop/build, desktop/src/assets"
