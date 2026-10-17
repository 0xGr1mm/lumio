#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# macOS 27's SwiftUI needs a macro plugin that ships with Xcode, not with the Command Line Tools.
# Without it every @State fails to compile, so the build falls back to the previous SDK, which still has plain property wrappers.
if [ -z "${SDKROOT:-}" ] && [ -z "$(ls /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/ 2>/dev/null | grep -i swiftui)" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox -c release
python3 scripts/generate-audio.py
mkdir -p "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"/Contents/MacOS "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"/Contents/Resources
if [ -z "${LUMIO_TEST_BUILD:-}" ]; then
  ./scripts/build-icon.sh
  cp Resources/Lumio.icns "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"/Contents/Resources/Lumio.icns
fi
# LUMIO_TEST_BUILD=1 leaves the heavy artwork out: it is only for running the verification suite locally,
# and copying it stalls while the files are still coming back from iCloud.
if [ -d Resources/Wallpapers ] && [ -z "${LUMIO_TEST_BUILD:-}" ]; then ditto Resources/Wallpapers "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"/Contents/Resources/Wallpapers; fi
if [ -d Resources/Cursors ] && [ -z "${LUMIO_TEST_BUILD:-}" ]; then ditto Resources/Cursors "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"/Contents/Resources/Cursors; fi
if [ -d Resources/Brand ]; then ditto Resources/Brand "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"/Contents/Resources/Brand; fi
if [ -d Resources/Audio ]; then ditto Resources/Audio "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"/Contents/Resources/Audio; fi
cp .build/release/Lumio "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"/Contents/MacOS/Lumio
cat > "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Lumio</string>
<key>CFBundleIdentifier</key><string>studio.lumio.local</string>
<key>CFBundleIconFile</key><string>Lumio</string>
<key>CFBundleName</key><string>Lumio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.14.2</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>Lumio uses the microphone to add your voice to screen recordings.</string>
<key>NSCameraUsageDescription</key><string>Lumio records your camera next to the screen so it can be placed and styled in the editor.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Lumio uses on-device speech recognition to create editable captions from your recordings.</string>
<key>CFBundleDocumentTypes</key><array>
<dict><key>CFBundleTypeName</key><string>Recording</string><key>CFBundleTypeRole</key><string>Editor</string><key>LSItemContentTypes</key><array><string>public.movie</string><string>public.image</string></array></dict>
<dict><key>CFBundleTypeName</key><string>Lumio Project</string><key>CFBundleTypeRole</key><string>Editor</string><key>LSItemContentTypes</key><array><string>studio.lumio.project</string></array></dict>
</array>
<key>UTExportedTypeDeclarations</key><array>
<dict><key>UTTypeIdentifier</key><string>studio.lumio.project</string><key>UTTypeDescription</key><string>Lumio Project</string><key>UTTypeConformsTo</key><array><string>public.json</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>lumio</string></array></dict></dict>
</array>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -d com.apple.FinderInfo "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app" 2>/dev/null || true
python3 scripts/sign.py "$HOME/Library/Caches/Lumio/Build.noindex/Lumio.app"
