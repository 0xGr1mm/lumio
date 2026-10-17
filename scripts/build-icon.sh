#!/bin/sh
# Rebuilds Resources/Lumio.icns and the in-app brand images from the approved masters.
# Skipped when the icon is already newer than the master it came from.
set -eu
cd "$(dirname "$0")/.."
MASTER=Design/logo-concepts/lumio-blue-concept-v1.png
if [ ! -f "$MASTER" ]; then
  echo "no brand master; keeping the icon that is already in Resources"
  exit 0
fi
if [ -f Resources/Lumio.icns ] && [ Resources/Lumio.icns -nt "$MASTER" ] && [ Resources/Brand/mark.png -nt "$MASTER" ]; then
  exit 0
fi
swift scripts/make-brand.swift .
iconutil -c icns .build/Lumio.iconset -o Resources/Lumio.icns
echo "icon and brand images rebuilt"
