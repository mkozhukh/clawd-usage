#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/Clawd.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClawdMac" "$APP/Contents/MacOS/ClawdMac"
cp Info.plist "$APP/Contents/Info.plist"
cp THIRD_PARTY_NOTICES "$APP/Contents/Resources/THIRD_PARTY_NOTICES"
cp LICENSE "$APP/Contents/Resources/LICENSE"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$APP"
printf 'Built %s\n' "$APP"
printf 'Run: open "%s"\nDemo: open "%s" --args --demo\n' "$APP" "$APP"
if [ "${1:-}" = "--snapshot" ]; then
    "$APP/Contents/MacOS/ClawdMac" --demo --snapshot "$PWD/dist/demo.png"
    "$APP/Contents/MacOS/ClawdMac" --demo --expanded --snapshot "$PWD/dist/demo-expanded.png"
fi
