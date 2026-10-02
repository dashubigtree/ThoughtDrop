#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox -debug-info-format none
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"
APP="$PWD/dist/ThoughtDrop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ThoughtDrop" "$APP/Contents/MacOS/ThoughtDrop"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/ThoughtDrop.icns "$APP/Contents/Resources/ThoughtDrop.icns"
# Ad-hoc signing normally pins identity to the binary hash, so every rebuild looks like a new app to
# macOS privacy (TCC) and re-asks for microphone/speech permission. Pin it to the bundle identifier instead.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --deep --strict "$APP"
echo "已建立：$APP"
