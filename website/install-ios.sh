#!/usr/bin/env bash
# CoShare for iPhone and iPad, built from source on your Mac, in one line:
#
#   curl -fsSL https://devehab.github.io/coshare/install-ios.sh | bash
#
# Plug the iPhone or iPad into the Mac first. The script:
#   1. checks this Mac and sets up what's missing: Xcode (from the App Store), its license and
#      first-run components;
#   2. downloads the CoShare source code into ~/CoShare-iOS (or updates it);
#   3. finds your Apple ID in Xcode (a free Apple ID is enough);
#   4. waits for the device: connected, trusted, unlocked, Developer Mode on;
#   5. builds CoShare, installs it and opens it.
# When a step fails it says why, fixes what it can and tries again. Every wait continues by itself
# as soon as the thing it waits for is done. Run the same line again to update CoShare, or to renew
# it before a free Apple ID's 7 days run out (your groups and history stay).
#
# Options (environment): COSHARE_DIR=<folder> for the source code, COSHARE_TEAM=<team ID>,
# COSHARE_DEVICE=<name or UDID>, COSHARE_REPO=<git URL>, COSHARE_BRANCH=<branch>.
set -uo pipefail

REPO="${COSHARE_REPO:-https://github.com/Devehab/coshare.git}"
BRANCH="${COSHARE_BRANCH:-main}"
DIR="${COSHARE_DIR:-$HOME/CoShare-iOS}"
GUIDE="https://devehab.github.io/coshare/ios.html"
XCODE_STORE="macappstore://apps.apple.com/app/xcode/id497799835"
# The project's own team keeps the project's bundle ID; anyone else gets one of their own.
OWNER_TEAM="NH9U4SFY7C"
OWNER_BUNDLE="com.ehabk.CoShare"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
fail() { printf '\n\033[31m✗ %s\033[0m\n  Step-by-step guide: %s\n' "$*" "$GUIDE" >&2; exit 1; }

# Waits until `check` succeeds, telling the person once what to do and reminding them every minute.
# Gives up after `minutes`.
wait_for() {
  local minutes="$1" check="$2" message="$3" i=0
  eval "$check" && return 0
  printf '\033[33m…\033[0m %b\n' "$message"
  note "(It continues by itself as soon as that's done. Ctrl+C to stop; running the line again picks up here.)"
  while ! eval "$check"; do
    sleep 5
    i=$((i + 1))
    [ $((i % 12)) -eq 0 ] && note "still waiting ($((i / 12)) min)…"
    [ "$i" -ge $((minutes * 12)) ] && return 1
  done
  return 0
}

# Reads a JSON file with macOS's built-in JavaScript (no Python needed): js <file> <function body using j>.
js() {
  osascript -l JavaScript -e 'ObjC.import("Foundation"); function run(a) {
    var s = $.NSString.stringWithContentsOfFileEncodingError(a[0], $.NSUTF8StringEncoding, null).js;
    return new Function("j", a[1])(JSON.parse(s)); }' "$1" "$2" 2>/dev/null
}

main() {
  [ "${1:-}" = "--help" ] && { sed -n '2,21p' "$0" 2>/dev/null || echo "See $GUIDE"; return; }
  [ "$(uname -s)" = "Darwin" ] || fail "This installs CoShare on an iPhone or iPad from a Mac. On this system: https://devehab.github.io/coshare/#download"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  printf '\033[1mCoShare for iPhone and iPad\033[0m: built from its open source code, with your own Apple ID.\n'
  check_mac
  setup_xcode
  get_code
  find_team
  find_device
  build
  install_and_open
  finish
}

# ------------------------------------------------------------------ the Mac

check_mac() {
  say "1/6 · This Mac"
  MACOS="$(sw_vers -productVersion)"
  ok "macOS $MACOS on $(uname -m | sed 's/arm64/Apple Silicon/;s/x86_64/Intel/')"
  local free_gb
  free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
  if [ "${free_gb:-0}" -lt 15 ]; then
    warn "Only ${free_gb} GB free. Xcode and the first build on a device need about 15 GB (40 GB if Xcode isn't installed yet)."
  else
    ok "${free_gb} GB free"
  fi
}

find_xcode() {
  local dev app
  dev="$(xcode-select -p 2>/dev/null || true)"
  case "$dev" in
    *.app/Contents/Developer) app="${dev%/Contents/Developer}" ;;
    *) app="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | grep '^/Applications/' | sort | tail -1)"
       [ -z "$app" ] && [ -d /Applications/Xcode.app ] && app=/Applications/Xcode.app ;;
  esac
  [ -n "$app" ] && [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ] || return 1
  XCODE_APP="$app"
  # Use this Xcode for everything below, even if the command-line tools point elsewhere (no sudo).
  export DEVELOPER_DIR="$app/Contents/Developer"
}

setup_xcode() {
  say "2/6 · Xcode"
  if ! find_xcode; then
    note "CoShare is built with Xcode, Apple's free developer app (about 3 GB to download)."
    note "Opening it in the App Store: click «Get», then «Install»."
    local major="${MACOS%%.*}"
    if [ "$major" -lt 15 ]; then
      note "On macOS $MACOS the App Store may only offer an Xcode for newer macOS. Then get the newest Xcode"
      note "that runs on this Mac from https://developer.apple.com/download/all (free Apple ID) and put it in Applications."
    fi
    open "$XCODE_STORE" 2>/dev/null || open "https://apps.apple.com/app/xcode/id497799835"
    wait_for 240 find_xcode "Waiting for Xcode to finish installing (often 20–60 minutes)…" \
      || fail "Xcode isn't installed yet. Run the same line again once it is."
  fi
  ok "$(DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -version 2>/dev/null | head -1) at $XCODE_APP"

  if ! xcodebuild -license check >/dev/null 2>&1; then
    note "Accepting Xcode's license once (macOS asks for your Mac password)."
    sudo xcodebuild -license accept || fail "Xcode's license wasn't accepted. Open Xcode once, accept it, and run the line again."
  fi
  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    note "Installing Xcode's first-run components (your Mac password)…"
    sudo xcodebuild -runFirstLaunch >/dev/null 2>&1 || fail "Xcode's components didn't install. Open Xcode once, let it finish, and run the line again."
  fi
  ok "Xcode is ready"
}

# ------------------------------------------------------------------ the code

get_code() {
  say "3/6 · CoShare's source code"
  if [ -d "$DIR/.git" ]; then
    if [ -n "$(git -C "$DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      warn "You've changed files in $DIR, so it's built as it is (not updated)."
    elif git -C "$DIR" fetch -q origin "$BRANCH" 2>/dev/null; then
      # Nothing of the person's own here, so simply move to the latest version.
      git -C "$DIR" reset -q --hard FETCH_HEAD
      ok "Up to date ($(git -C "$DIR" log -1 --format='%h, %cd' --date=short))"
    else
      warn "Couldn't check for updates (offline?), building the copy you have."
    fi
  elif [ -e "$DIR" ]; then
    fail "$DIR already exists and isn't CoShare's code. Run with COSHARE_DIR=<another folder>."
  else
    git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$DIR" || fail "Couldn't download the code from $REPO. Check the internet connection and try again."
    ok "Downloaded to $DIR"
  fi
  [ -f "$DIR/CoShare.xcodeproj/xcshareddata/xcschemes/CoShare iOS.xcscheme" ] || fail "This copy of the code is too old for this installer. Delete $DIR and run the line again."
}

# ------------------------------------------------------------------ your Apple ID

# One line per team Xcode knows: "TEAMID|name|free".
teams() {
  defaults export com.apple.dt.Xcode - 2>/dev/null \
    | plutil -extract IDEProvisioningTeamByIdentifier json -o "$TMP/teams.json" - 2>/dev/null || return 1
  js "$TMP/teams.json" 'var out = []; Object.keys(j).forEach(function (k) { j[k].forEach(function (t) {
      out.push(t.teamID + "|" + t.teamName + "|" + (t.isFreeProvisioningTeam ? "free" : "paid")); }); }); return out.join("\n")'
}

has_team() { [ -n "$(teams)" ]; }

find_team() {
  say "4/6 · Your Apple ID"
  if [ -n "${COSHARE_TEAM:-}" ]; then
    TEAM="$COSHARE_TEAM"; TEAM_FREE=""
  else
    if ! has_team; then
      open -a "$XCODE_APP"
      wait_for 30 has_team "Sign in to Xcode with your Apple ID (a free one works):\n    Xcode → Settings… (⌘,) → Accounts → «+» → Apple ID → sign in. Then close the Settings window." \
        || fail "No Apple ID in Xcode yet. Add it (Xcode → Settings → Accounts) and run the line again."
    fi
    # A paid team signs for a year; a free (personal) team for 7 days.
    local line
    line="$(teams | sort -t'|' -k3,3r | head -1)"
    [ "$(teams | wc -l | tr -d ' ')" -gt 1 ] && note "More than one team; using the first paid one, or the personal one. To choose: COSHARE_TEAM=<ID>. Teams: $(teams | cut -d'|' -f1,2 | tr '\n' ' ')"
    TEAM="${line%%|*}"
    TEAM_FREE="$(echo "$line" | cut -d'|' -f3)"
  fi
  CONF="$DIR/.coshare-ios"
  BUNDLE_ID=""
  [ -f "$CONF" ] && BUNDLE_ID="$(sed -n "s/^$TEAM=//p" "$CONF")"
  if [ -z "$BUNDLE_ID" ]; then
    if [ "$TEAM" = "$OWNER_TEAM" ]; then BUNDLE_ID="$OWNER_BUNDLE"
    else BUNDLE_ID="com.coshare.app.$(echo "$TEAM" | tr '[:upper:]' '[:lower:]')"; fi
    echo "$TEAM=$BUNDLE_ID" >> "$CONF"
  fi
  ok "Team $TEAM${TEAM_FREE:+ ($TEAM_FREE)} · app ID $BUNDLE_ID"
}

# ------------------------------------------------------------------ the device

# One line per iPhone/iPad this Mac knows: "udid|name|iOS|developer mode|pairing|connection".
devices() {
  xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null 2>&1 || return 1
  js "$TMP/devices.json" 'return j.result.devices.filter(function (d) {
      var h = d.hardwareProperties || {}; return h.reality === "physical" && /^(iOS|iPadOS)$/.test(h.platform); })
    .map(function (d) { var h = d.hardwareProperties || {}, p = d.deviceProperties || {}, c = d.connectionProperties || {};
      return [h.udid, p.name, p.osVersionNumber, p.developerModeStatus || "", c.pairingState || "", c.transportType || ""].join("|"); })
    .join("\n")'
}

# The chosen device's line, if it is connected right now.
device_line() {
  devices | awk -F'|' -v want="${COSHARE_DEVICE:-}" '
    $6 != "" && (want == "" || $1 == want || $2 == want) { if ($6 == "wired") { print; found = 1; exit } else if (!any) any = $0 }
    END { if (!found && any) print any }'
}
field() { device_line | cut -d'|' -f"$1"; }
connected() { [ -n "$(device_line)" ]; }
paired() { [ "$(field 5)" = "paired" ]; }
dev_mode() { local m; m="$(field 4)"; [ "$m" = "enabled" ] || [ -z "$m" ]; }

find_device() {
  say "5/6 · Your iPhone or iPad"
  wait_for 30 connected "Connect the iPhone or iPad to this Mac with a cable, and unlock it." \
    || fail "No iPhone or iPad showed up. Use a data cable (not charge-only), unlock the device and run the line again."
  wait_for 15 paired "On the device: tap «Trust» (Trust This Computer?) and enter its passcode." \
    || fail "The device didn't trust this Mac. Unplug it, plug it in again, tap «Trust», and run the line again."
  local os
  os="$(field 3)"
  [ "${os%%.*}" -ge 15 ] 2>/dev/null || fail "CoShare needs iOS or iPadOS 15 or later (this device has $os)."
  if ! dev_mode; then
    wait_for 30 dev_mode "Turn on Developer Mode on the device:\n    Settings → Privacy & Security → Developer Mode (at the bottom) → On → Restart.\n    After it restarts, tap «Turn On» and enter the passcode, then unlock it." \
      || fail "Developer Mode is still off. Turn it on (Settings → Privacy & Security) and run the line again."
  fi
  UDID="$(field 1)"
  ok "$(field 2) · iOS $os · $(field 6 | sed 's/wired/cable/;s/localNetwork/Wi-Fi/') · Developer Mode on"
}

# ------------------------------------------------------------------ build, install, open

build() {
  say "6/6 · Building CoShare"
  APP="$DIR/build/DerivedData/Build/Products/Release-iphoneos/CoShare.app"
  local attempt
  for attempt in 1 2 3; do
    note "Building for $(field 2) (2–5 minutes the first time; Xcode may first prepare the device for development)…"
    LOG="$DIR/build/install-ios.log"
    mkdir -p "$DIR/build"
    ( cd "$DIR" && xcodebuild -project CoShare.xcodeproj -scheme "CoShare iOS" -configuration Release \
        -destination "id=$UDID" -derivedDataPath "$DIR/build/DerivedData" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic \
        build ) > "$LOG" 2>&1 &
    local pid=$! seconds=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 5; seconds=$((seconds + 5))
      [ $((seconds % 30)) -eq 0 ] && note "  … $((seconds / 60)) min $((seconds % 60)) s"
    done
    if wait "$pid" && [ -d "$APP" ]; then ok "Built and signed"; return 0; fi
    diagnose "$attempt" || break
  done
  printf '\n'; grep -E "error:|failed" "$LOG" | sort -u | tail -8 | sed 's/^/  /'
  fail "The build didn't succeed. The full log is in $LOG."
}

# Reads why the build failed, fixes what it can, and says whether to try again.
diagnose() {
  local log="$LOG"
  if grep -qiE "No Accounts|No account for team|requires a development team|doesn.t have an account|not logged in|No signing certificate" "$log"; then
    warn "Xcode couldn't sign with team $TEAM."
    open -a "$XCODE_APP"
    note "Check Xcode → Settings → Accounts: your Apple ID is there and signed in (sign in again if it asks)."
    sleep 20; find_team; return 0
  fi
  if grep -qiE "cannot be registered|is not available\. Please enter a different string|failed to register bundle identifier" "$log"; then
    BUNDLE_ID="${BUNDLE_ID%.*}.$(echo "${BUNDLE_ID##*.}" | cut -c1-12)$(date +%s | tail -c 5)"
    sed -i '' "/^$TEAM=/d" "$CONF" 2>/dev/null; echo "$TEAM=$BUNDLE_ID" >> "$CONF"
    warn "That app ID is taken; using $BUNDLE_ID instead."
    return 0
  fi
  if grep -qiE "maximum App ID limit|maximum number of apps|reached the limit" "$log"; then
    fail "A free Apple ID can only sign 3 apps at a time (and 10 new app IDs a week). Delete another app you installed from Xcode, or use a paid developer account, and run the line again."
  fi
  if grep -qiE "is not installed\. To use with Xcode|download.*platform|Components" "$log"; then
    note "Downloading Xcode's iOS components (a few GB, once)…"
    xcodebuild -downloadPlatform iOS >/dev/null 2>&1 || warn "Couldn't download them here; Xcode → Settings → Components can."
    return 0
  fi
  if grep -qiE "Developer Mode" "$log"; then
    wait_for 15 dev_mode "Turn on Developer Mode: Settings → Privacy & Security → Developer Mode → On → Restart." && return 0
    return 1
  fi
  if grep -qiE "is locked|passcode|unlock" "$log"; then
    note "Unlock the device and keep it unlocked for a minute."; sleep 15; return 0
  fi
  if grep -qiE "Unable to find a destination|not available|isn.t connected|Preparing|busy|Timed out" "$log"; then
    note "The device isn't ready yet (Xcode may still be preparing it). Keep it connected and unlocked."
    wait_for 15 connected "Waiting for the device…" || return 1
    sleep 20; return 0
  fi
  [ "$1" -lt 2 ] && { note "Checking everything again and retrying once…"; find_device; return 0; }
  return 1
}

launch() { xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" > "$TMP/launch.log" 2>&1; }

install_and_open() {
  local i
  for i in 1 2 3; do
    if xcrun devicectl device install app --device "$UDID" "$APP" > "$TMP/install.log" 2>&1; then break; fi
    [ "$i" -eq 3 ] && { tail -5 "$TMP/install.log" | sed 's/^/  /'; fail "Couldn't install on the device."; }
    note "Install didn't go through (is it locked?). Unlock it; trying again…"; sleep 10
  done
  ok "Installed on $(field 2)"
  launch && { ok "CoShare is open on $(field 2)"; return; }
  if grep -qiE "Locked|could not be, unlocked" "$TMP/launch.log"; then
    wait_for 3 launch "Unlock the device to open CoShare." && { ok "CoShare is open on $(field 2)"; return; }
  fi
  if grep -qiE "trust|profile has not been|Untrusted|invalid code signature|not been explicitly" "$TMP/launch.log"; then
    wait_for 15 launch "One time only: let the device run apps you signed. On the device:\n    Settings → General → VPN & Device Management → «Apple Development: …» → Trust → Trust." \
      && { ok "CoShare is open on $(field 2)"; return; }
    fail "CoShare is installed but not trusted yet. Trust it (Settings → General → VPN & Device Management) and open it."
  fi
  note "Open CoShare on the device (its icon is on the home screen)."
}

finish() {
  printf '\n\033[1m🎉 CoShare is on your %s.\033[0m\n' "$(field 2)"
  note "On the device, allow «Local Network» and notifications, then:"
  note "  Settings → CoShare → Paste from Other Apps → Allow (so copies are sent from the background)."
  note "Create a group or join one with the QR code from your other devices."
  if [ "$TEAM_FREE" = "free" ]; then
    note ""
    note "With a free Apple ID the app is signed for 7 days, until $(date -v+7d '+%A %e %B')."
    note "Run the same line again before then to renew it; your groups and history stay."
  fi
  note ""
  note "Like it? A ⭐ on https://github.com/Devehab/coshare helps others find it."
}

main "$@"
