#!/bin/bash
# Builds CoShare.app for macOS without Xcode (Command Line Tools are enough).
# Universal binary (Apple Silicon + Intel), macOS 12 Monterey or newer.
#
#   scripts/build-mac.sh            → build/CoShare.app and build/CoShare-mac.zip
#   scripts/build-mac.sh --install  → also copies it to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/CoShare.app"
VERSION="1.0"
BUNDLE_ID="com.ehabk.CoShare.mac"

# Pick a macOS SDK the installed Swift compiler can read (a newer SDK than the compiler fails).
pick_sdk() {
  local sdk
  for sdk in "$(xcrun --show-sdk-path --sdk macosx 2>/dev/null)" $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
    [ -d "$sdk" ] || continue
    if echo 'import AppKit' | xcrun swiftc -sdk "$sdk" -typecheck - >/dev/null 2>&1; then
      echo "$sdk"; return
    fi
  done
  echo "No usable macOS SDK found" >&2; exit 1
}
SDK="$(pick_sdk)"
echo "• SDK: $SDK"

rm -rf build/obj "$APP"
mkdir -p build/obj "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  echo "• Compiling ${arch}…"
  xcrun swiftc -O -parse-as-library -swift-version 5 \
    -sdk "$SDK" -target "$arch-apple-macos12.0" \
    Shared/*.swift macOS/*.swift \
    -o "build/obj/CoShare-$arch"
done
lipo -create build/obj/CoShare-arm64 build/obj/CoShare-x86_64 -output "$APP/Contents/MacOS/CoShare"
cp Config/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>CoShare</string>
	<key>CFBundleExecutable</key><string>CoShare</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>CoShare</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSLocalNetworkUsageDescription</key><string>CoShare يتصل بأجهزتك على نفس شبكة الواي فاي لمشاركة النسخ واللصق.</string>
	<key>NSCameraUsageDescription</key><string>CoShare يستخدم الكاميرا فقط لمسح رمز QR للانضمام لمجموعة.</string>
	<key>NSBonjourServices</key><array><string>_coshare._tcp</string></array>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run on your own Macs.
codesign --force --sign - --timestamp=none --entitlements Config/macOS.entitlements "$APP"
ditto -c -k --keepParent "$APP" build/CoShare-mac.zip
echo "✓ Built $APP ($(lipo -archs "$APP/Contents/MacOS/CoShare"))"
echo "✓ Zip for other Macs: build/CoShare-mac.zip"

if [[ "${1:-}" == "--install" ]]; then
  pkill -f "CoShare.app/Contents/MacOS/CoShare" 2>/dev/null && sleep 1 || true
  rm -rf /Applications/CoShare.app
  ditto "$APP" /Applications/CoShare.app
  open /Applications/CoShare.app
  echo "✓ Installed to /Applications and launched (look for the clipboard icon in the menu bar)"
fi
