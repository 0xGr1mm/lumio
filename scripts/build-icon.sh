#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
rm -rf .build/Lumio.iconset
mkdir -p .build/Lumio.iconset
python3 scripts/round-icon.py
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" .build/Lumio-rounded.png --out ".build/Lumio.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" .build/Lumio-rounded.png --out ".build/Lumio.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .build/Lumio.iconset -o Resources/Lumio.icns
