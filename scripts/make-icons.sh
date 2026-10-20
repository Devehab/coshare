#!/bin/bash
# Renders every CoShare app icon from the mark in website/assets/logo.svg:
# vermilion square, two paper documents. Small sizes drop the fold and text lines so they stay crisp.
#   scripts/make-icons.sh            all platforms
#   scripts/make-icons.sh android    only the Android launcher, themed and notification icons
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

# Android: an adaptive icon (vermilion background colour + this foreground on the 108 dp canvas, whose
# middle 72 dp is what launchers show), a one-colour layer for Android 13 themed icons, and the white
# glyph for the status bar and the Quick Settings tile. Densities: mdpi 1×, hdpi 1.5×, xhdpi 2×, xxhdpi 3×, xxxhdpi 4×.
android_icons() {
  local res=android/app/src/main/res
  local docs_on_108="translate(18 18) scale(1.125)"
  # Foreground: the documents in the logo's position (the background is @color/ic_launcher_background).
  { echo "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 108 108' width='108' height='108'><g transform='$docs_on_108'>"
    docs full
    echo "</g></svg>"; } > "$TMP/android-fg.svg"
  # Monochrome: one colour, shape by alpha; the fold and text lines are cut out of both pages.
  mono() {
    echo "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 $1 $1' width='$1' height='$1'>"
    echo "<mask id='cut' maskUnits='userSpaceOnUse' x='0' y='0' width='64' height='64'><rect width='64' height='64' fill='#fff'/>"
    echo "<path d='M32 21v5.5a2.5 2.5 0 0 0 2.5 2.5H40' fill='none' stroke='#000' stroke-width='2.4' stroke-linejoin='round'/>"
    echo "<path d='M22 38.5h11M22 44h7' stroke='#000' stroke-width='2.6' stroke-linecap='round'/></mask>"
    echo "<g transform='$2'><g mask='url(#cut)'>"
    echo "<rect x='25' y='12' width='24' height='31' rx='5' fill='$3' opacity='.55'/>"
    echo "<path d='M19.5 21H32l8 8v19a4 4 0 0 1-4 4H19.5a4 4 0 0 1-4-4V25a4 4 0 0 1 4-4z' fill='$3'/>"
    echo "</g></g></svg>"
  }
  mono 108 "$docs_on_108" '#000' > "$TMP/android-mono.svg"
  # Status bar / tile: white, the documents filling the 24 dp square.
  mono 24 "translate(12 12) scale(.55) translate(-32.25 -32)" '#fff' > "$TMP/android-stat.svg"
  local density scale
  for density in mdpi:1 hdpi:1.5 xhdpi:2 xxhdpi:3 xxxhdpi:4; do
    scale=${density#*:}; density=${density%%:*}
    mkdir -p "$res/mipmap-$density" "$res/drawable-$density"
    local px; px=$(printf '%.0f' "$(echo "108 * $scale" | bc -l)")
    rsvg-convert -w "$px" -h "$px" "$TMP/android-fg.svg" -o "$res/mipmap-$density/ic_launcher_foreground.png"
    rsvg-convert -w "$px" -h "$px" "$TMP/android-mono.svg" -o "$res/mipmap-$density/ic_launcher_monochrome.png"
    px=$(printf '%.0f' "$(echo "24 * $scale" | bc -l)")
    rsvg-convert -w "$px" -h "$px" "$TMP/android-stat.svg" -o "$res/drawable-$density/ic_stat_coshare.png"
  done
  # Store / website listing image: the full-bleed square, like iOS (launchers apply their own mask).
  render ios full 512 android/app/src/main/ic_launcher-playstore.png
  echo "✓ Android icons written: $res/mipmap-*, $res/drawable-*/ic_stat_coshare.png"
}

if [ "${1:-all}" = android ]; then
  android_icons
  exit 0
fi

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

android_icons
echo "✓ Icons written: $MAC_SET, Config/AppIcon.icns, iOS AppIcon, desktop/build, desktop/src/assets, android"
