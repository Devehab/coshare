#!/bin/bash
# Runs a fake "phone" on this Mac to test sync without a real device.
#   scripts/test-peer.sh [name]
# Then append commands to the printed commands file, e.g.:
#   echo "copy hello" >> /tmp/coshare-test-commands.txt
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk | sort -rV | while read -r s; do
  echo 'import Foundation' | xcrun swiftc -sdk "$s" -typecheck - >/dev/null 2>&1 && { echo "$s"; break; }; done)
mkdir -p build/tools
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$SDK" Shared/*.swift Tools/TestPeer/main.swift -o build/tools/TestPeer
: > /tmp/coshare-test-commands.txt
COSHARE_PROFILE=testpeer COSHARE_NAME="${1:-TestPeer}" COSHARE_VERBOSE=1 \
  COSHARE_CMDS=/tmp/coshare-test-commands.txt exec build/tools/TestPeer
