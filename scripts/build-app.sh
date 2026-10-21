#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
APP="$PWD/dist/Clawd.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClawdUsage" "$APP/Contents/MacOS/ClawdUsage"
cp Info.plist "$APP/Contents/Info.plist"
cp THIRD_PARTY_NOTICES "$APP/Contents/Resources/THIRD_PARTY_NOTICES"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
printf 'Built %s\n' "$APP"
printf 'Run: open "%s"\nDemo: open "%s" --args --demo\n' "$APP" "$APP"
if [ "${1:-}" = "--snapshot" ]; then
    "$APP/Contents/MacOS/ClawdUsage" --demo --snapshot "$PWD/dist/demo.png"
    "$APP/Contents/MacOS/ClawdUsage" --demo --minimal --snapshot "$PWD/dist/demo-minimal.png"
fi
