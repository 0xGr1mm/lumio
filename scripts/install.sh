#!/bin/sh
# Puts the freshly built app in /Applications, keeping the same bundle identifier
# and signature so the permissions the user already granted still apply.
set -eu
cd "$(dirname "$0")/.."
./scripts/build.sh
BUILT="$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"
pkill -x Lumio 2>/dev/null || true
ditto "$BUILT" /Applications/Lumio.app
echo "installed /Applications/Lumio.app"
