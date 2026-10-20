#!/bin/bash
# Installs a CoShare package on a clean distribution (run inside its Docker image) and runs the
# app's self-test: crypto against the Swift vectors, clipboard text/image/change detection, TCP.
#   docker run --rm -v "$PWD/dist:/dist" -v "$PWD/scripts:/s" debian:12 /s/install-test.sh /dist/CoShare-amd64.deb
set -euo pipefail
pkg="$1"
# Debian 11 left LTS in 2026: its security pool moved to the archive, so a fresh container's index
# points at files that are gone. The test only needs the release's own packages.
if grep -q 'VERSION_CODENAME=bullseye' /etc/os-release 2>/dev/null; then
  sed -i '/security/d' /etc/apt/sources.list 2>/dev/null || true
fi
exe=/opt/CoShare/coshare
case "$pkg" in
  *.deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "$pkg" xvfb xauth >/dev/null
    ;;
  *.rpm)
    dnf install -y -q "$pkg" xorg-x11-server-Xvfb xorg-x11-xauth >/dev/null
    ;;
  *.AppImage)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq xvfb xauth libgtk-3-0 libnss3 libasound2 libgbm1 libxss1 libxtst6 >/dev/null
    cp "$pkg" /tmp/CoShare.AppImage && chmod +x /tmp/CoShare.AppImage
    exe=/tmp/CoShare.AppImage
    export APPIMAGE_EXTRACT_AND_RUN=1 # no FUSE inside containers
    ;;
esac
case "$pkg" in *.deb|*.rpm) command -v coshare >/dev/null || { echo "coshare is not on PATH"; exit 1; } ;; esac
export COSHARE_SELF_TEST_OUT=/tmp/self-test.json
xvfb-run -a "$exe" --self-test --no-sandbox --disable-gpu >/tmp/run.log 2>&1 || true
cat /tmp/self-test.json 2>/dev/null || { echo "no self-test report"; tail -30 /tmp/run.log; exit 1; }
echo
grep -q '"ok":true' /tmp/self-test.json
