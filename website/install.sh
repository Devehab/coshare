#!/usr/bin/env bash
# CoShare for Linux, in one line:
#
#   curl -fsSL https://devehab.github.io/coshare/install.sh | bash
#
# Picks the right build for this distribution and processor, installs it with its dependencies,
# checks that it works, and starts CoShare. Running it again updates CoShare.
#   Ubuntu, Debian, Mint, Pop!_OS…  → .deb through apt
#   Fedora, RHEL, Rocky, Alma…      → .rpm through dnf/yum
#   Arch, Manjaro, openSUSE, others → the app in ~/.local (no root, no FUSE needed)
#
# Uninstall:  curl -fsSL https://devehab.github.io/coshare/install.sh | bash -s -- --uninstall
#
# Options (environment): COSHARE_FORMAT=deb|rpm|local to force a format,
# COSHARE_NO_LAUNCH=1 to skip starting it, COSHARE_PACKAGE_DIR=<dir> to install files from a folder.
set -euo pipefail

RELEASE_URL="${COSHARE_RELEASE_URL:-https://github.com/Devehab/coshare/releases/latest/download}"
LOCAL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/coshare"
LOCAL_BIN="$HOME/.local/bin"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

main() {
  [ "$(uname -s)" = "Linux" ] || fail "This installer is for Linux. Other systems: https://devehab.github.io/coshare/#download"

  case "$(uname -m)" in
    x86_64 | amd64) DEB_ARCH=amd64; RPM_ARCH=x86_64; APPIMAGE_ARCH=x86_64 ;;
    aarch64 | arm64) DEB_ARCH=arm64; RPM_ARCH=aarch64; APPIMAGE_ARCH=arm64 ;;
    *) fail "CoShare runs on 64-bit Intel/AMD or ARM processors (this one is $(uname -m))." ;;
  esac

  if [ "$(id -u)" -eq 0 ]; then SUDO=""; elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO="none"; fi

  FORMAT="${COSHARE_FORMAT:-}"
  if [ -z "$FORMAT" ]; then
    if command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then FORMAT=deb
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then FORMAT=rpm
    else FORMAT=local
    fi
  fi
  # Installing a system package needs root; without sudo, install for this user instead.
  if [ "$FORMAT" != local ] && [ "$SUDO" = none ]; then FORMAT=local; fi
  [ "$SUDO" = none ] && SUDO=""

  if [ "${1:-}" = "--uninstall" ]; then uninstall; return; fi

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  chmod 755 "$TMP" # apt reads the package as its own user

  stop_running
  case "$FORMAT" in
    deb) install_deb ;;
    rpm) install_rpm ;;
    local) install_local ;;
    *) fail "Unknown COSHARE_FORMAT: $FORMAT (use deb, rpm or local)" ;;
  esac
  check
  launch
  echo
  say "CoShare is ready. Create a group, or join one, on every device you want to share with."
}

fetch() { # fetch <file name> → $TMP/<file name>
  local name="$1"
  if [ -n "${COSHARE_PACKAGE_DIR:-}" ]; then
    cp "$COSHARE_PACKAGE_DIR/$name" "$TMP/$name"
  elif command -v curl >/dev/null 2>&1; then
    say "Downloading $name…"
    curl -fL --progress-bar --retry 3 -o "$TMP/$name" "$RELEASE_URL/$name"
  elif command -v wget >/dev/null 2>&1; then
    say "Downloading $name…"
    wget -q --show-progress -O "$TMP/$name" "$RELEASE_URL/$name"
  else
    fail "Please install curl or wget first."
  fi
  chmod 644 "$TMP/$name"
}

install_deb() {
  fetch "CoShare-$DEB_ARCH.deb"
  say "Installing (apt may ask for your password)…"
  # A local file installs with its dependencies from the distribution; refresh the lists if needed.
  if ! $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$TMP/CoShare-$DEB_ARCH.deb"; then
    $SUDO apt-get update -q
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$TMP/CoShare-$DEB_ARCH.deb"
  fi
  EXE=/opt/CoShare/coshare
  ok "Installed with apt"
}

install_rpm() {
  fetch "CoShare-$RPM_ARCH.rpm"
  say "Installing (dnf may ask for your password)…"
  if command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y "$TMP/CoShare-$RPM_ARCH.rpm"
  else
    $SUDO yum install -y "$TMP/CoShare-$RPM_ARCH.rpm"
  fi
  EXE=/opt/CoShare/coshare
  ok "Installed with $(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum)"
}

# Any other distribution: unpack the AppImage into ~/.local, so it runs without FUSE or root.
install_local() {
  fetch "CoShare-$APPIMAGE_ARCH.AppImage"
  say "Installing for $(id -un) in $LOCAL_DIR…"
  chmod +x "$TMP/CoShare-$APPIMAGE_ARCH.AppImage"
  (cd "$TMP" && "./CoShare-$APPIMAGE_ARCH.AppImage" --appimage-extract >/dev/null)
  rm -rf "$LOCAL_DIR/app"
  mkdir -p "$LOCAL_DIR" "$LOCAL_BIN" "$APPS_DIR"
  mv "$TMP/squashfs-root" "$LOCAL_DIR/app"
  # The unpacked app has no setuid sandbox helper; its window only ever shows CoShare's own files.
  cat >"$LOCAL_BIN/coshare" <<EOF
#!/bin/sh
COSHARE_LAUNCHER="$LOCAL_BIN/coshare" exec "$LOCAL_DIR/app/coshare" --no-sandbox "\$@"
EOF
  chmod +x "$LOCAL_BIN/coshare"
  local icon="$LOCAL_DIR/app/coshare.png"
  [ -f "$icon" ] || icon="$(find "$LOCAL_DIR/app/usr/share/icons" -name 'coshare.png' 2>/dev/null | sort -V | tail -1)"
  cat >"$APPS_DIR/coshare.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CoShare
Comment=One clipboard for all your devices
Exec=$LOCAL_BIN/coshare %U
Icon=$icon
Terminal=false
Categories=Utility;
Keywords=clipboard;copy;paste;sync;
StartupWMClass=CoShare
EOF
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  EXE="$LOCAL_BIN/coshare"
  ok "Installed in $LOCAL_DIR (menu entry: CoShare)"
  case ":$PATH:" in *":$LOCAL_BIN:"*) ;; *) echo "  (add $LOCAL_BIN to your PATH to run 'coshare' from a terminal)" ;; esac
}

# An update replaces files under a running copy: close it first, start the new one at the end.
stop_running() {
  if command -v pgrep >/dev/null 2>&1 && pgrep -x coshare >/dev/null 2>&1; then
    say "Closing the running CoShare to update it…"
    pkill -x coshare 2>/dev/null || true
    sleep 1
  fi
}

# Quick check of the installed app (encryption, network, clipboard access) without touching the clipboard.
has_display() { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }

check() {
  local display=""
  if has_display; then display=1; fi
  if [ -z "$display" ] && [ -z "${COSHARE_CHECK_XVFB:-}" ]; then
    echo "  (no desktop session here, so the startup check is skipped)"
    return
  fi
  local args=(--check)
  [ "$(id -u)" -eq 0 ] && args+=(--no-sandbox)
  local report="$TMP/check.json" run=()
  command -v timeout >/dev/null 2>&1 && run=(timeout 90)
  [ -z "$display" ] && run+=(xvfb-run -a)
  local status=0
  COSHARE_SELF_TEST_OUT="$report" ${run[@]+"${run[@]}"} "$EXE" "${args[@]}" >"$TMP/check.log" 2>&1 || status=$?
  if [ "$status" -eq 124 ] && [ ! -s "$report" ]; then
    echo "  (the startup check took too long, skipping it)"
    return
  fi
  if grep -q '"ok":true' "$report" 2>/dev/null; then
    ok "Checked: encryption, network and clipboard all work"
  else
    echo "Startup check failed. Details:" >&2
    cat "$report" 2>/dev/null >&2 || tail -20 "$TMP/check.log" >&2
    fail "CoShare is installed but didn't pass its check. Please report it: https://github.com/Devehab/coshare/issues"
  fi
}

launch() {
  [ -n "${COSHARE_NO_LAUNCH:-}" ] && return
  [ "$(id -u)" -eq 0 ] && return # never start the desktop app as root
  if has_display; then
    nohup "$EXE" >/dev/null 2>&1 &
    ok "CoShare started (it also starts by itself when you log in)"
  fi
}

uninstall() {
  stop_running
  if command -v dpkg >/dev/null 2>&1 && dpkg -s coshare >/dev/null 2>&1; then
    $SUDO apt-get remove -y -q coshare
  elif command -v rpm >/dev/null 2>&1 && rpm -q coshare >/dev/null 2>&1; then
    # Only CoShare itself, like apt-get remove: RHEL's dnf would also take the libraries that came
    # with it, and refuses outright when one of them is protected (systemd-udev on a minimal system).
    if command -v dnf >/dev/null 2>&1; then $SUDO dnf remove -y --setopt=clean_requirements_on_remove=False coshare
    else $SUDO yum remove -y --setopt=clean_requirements_on_remove=0 coshare; fi
  fi
  rm -rf "$LOCAL_DIR/app" "$LOCAL_BIN/coshare" "$APPS_DIR/coshare.desktop" "$HOME/.config/autostart/coshare.desktop"
  ok "CoShare removed (your groups and history stay in ~/.config/CoShare; delete that folder to remove them too)"
}

main "$@"
