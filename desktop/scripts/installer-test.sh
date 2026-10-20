#!/bin/bash
# Runs the one-line installer (website/install.sh) on a clean distribution inside Docker, the way a
# person would: as a normal user with sudo, piped into bash. Then checks that CoShare is installed,
# is in the menu, passes its full self-test (sandbox on), updates in place, and uninstalls cleanly.
#   docker run --rm --cap-add SYS_ADMIN --security-opt seccomp=unconfined \
#     -v "$PWD/dist:/dist:ro" -v "$PWD/../website:/site:ro" -v "$PWD/scripts:/s:ro" \
#     ubuntu:24.04 bash /s/installer-test.sh [deb|rpm|local]
# (SYS_ADMIN lets Chromium's setuid sandbox work inside a container, as it does on a desktop.)
set -euo pipefail
format="${1:-}"
. /etc/os-release
# Debian 11 left LTS in 2026: its security pool moved to the archive, so a fresh container's index
# points at files that are gone. The test only needs the release's own packages.
if grep -q 'VERSION_CODENAME=bullseye' /etc/os-release 2>/dev/null; then
  sed -i '/security/d' /etc/apt/sources.list 2>/dev/null || true
fi
step() { printf '\n== %s\n' "$*"; }

step "prepare $PRETTY_NAME"
case "$ID" in
  ubuntu | debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq sudo xvfb xauth procps >/dev/null ;;
  fedora | rhel | rocky | almalinux)
    dnf install -y -q sudo xorg-x11-server-Xvfb xorg-x11-xauth procps-ng findutils >/dev/null ;;
  *) echo "unsupported test image: $ID"; exit 1 ;;
esac
# What an AppImage-style ("local") install needs from the system, as on any desktop.
if [ "$format" = local ]; then
  case "$ID" in
    ubuntu | debian) apt-get install -y -qq libgtk-3-0 libnss3 libgbm1 libxss1 libxtst6 libasound2 >/dev/null 2>&1 \
      || apt-get install -y -qq libgtk-3-0t64 libnss3 libgbm1 libxss1 libxtst6 libasound2t64 >/dev/null ;;
    *) dnf install -y -q gtk3 nss mesa-libgbm libXScrnSaver libXtst alsa-lib >/dev/null ;;
  esac
fi
useradd -m tester
echo 'tester ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/tester
as_tester() { su - tester -c "$1"; }
env_line="COSHARE_PACKAGE_DIR=/dist COSHARE_CHECK_XVFB=1 COSHARE_FORMAT=$format"

step "the one line: cat install.sh | bash"
as_tester "cat /site/install.sh | $env_line bash"

step "installed and in the menu"
if [ "$format" = local ]; then
  exe=/home/tester/.local/bin/coshare
  test -x "$exe"
  test -f /home/tester/.local/share/applications/coshare.desktop
else
  exe=coshare
  as_tester "command -v coshare"
  test -f /usr/share/applications/coshare.desktop
fi
echo "ok"

step "full self-test as the user (clipboard text + image, encryption with the Apple apps, network)"
as_tester "COSHARE_SELF_TEST_OUT=/tmp/st.json xvfb-run -a $exe --self-test >/tmp/st.log 2>&1 || true; cat /tmp/st.json || tail -20 /tmp/st.log"
echo
grep -q '"ok":true' /tmp/st.json

step "running it again updates in place"
as_tester "cat /site/install.sh | $env_line bash" >/tmp/again.log 2>&1 || { cat /tmp/again.log; exit 1; }
grep -q "Checked" /tmp/again.log && echo "ok"

step "uninstall"
as_tester "cat /site/install.sh | $env_line bash -s -- --uninstall"
if [ "$format" = local ]; then test ! -e /home/tester/.local/bin/coshare; else ! as_tester "command -v coshare"; fi
echo "ok"

printf '\nINSTALLER TEST PASSED on %s (%s)\n' "$PRETTY_NAME" "${format:-auto}"
