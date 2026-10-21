#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CODE_SIGN_IDENTITY:=Developer ID Application: Maksim Kozhukh (J284DTX4L9)}"
: "${NOTARY_PROFILE:=clawd-notary}"
export CODE_SIGN_IDENTITY
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
ZIP="dist/Clawd-$VERSION.zip"
# --publish tags and uploads what is committed: check before spending time on build and notarization.
if [ "${1:-}" = "--publish" ]; then
    if [ -n "$(git status --porcelain)" ]; then
        echo "release: working tree is not clean (commit, stash or remove the changes first)" >&2
        exit 1
    fi
    if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
        echo "release: tag v$VERSION already exists locally; bump CFBundleShortVersionString in Info.plist" >&2
        exit 1
    fi
    if ! REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/v$VERSION")"; then
        echo "release: cannot query origin; not publishing" >&2
        exit 1
    fi
    if [ -n "$REMOTE_TAG" ]; then
        echo "release: tag v$VERSION already exists on origin; bump CFBundleShortVersionString in Info.plist" >&2
        exit 1
    fi
fi
scripts/build-app.sh
rm -f "$ZIP"
ditto -c -k --keepParent dist/Clawd.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/Clawd.app
rm -f "$ZIP"
ditto -c -k --keepParent dist/Clawd.app "$ZIP"
spctl -a -vv dist/Clawd.app
printf 'Release %s\nZip: %s\nsha256: %s\n' "$VERSION" "$ZIP" "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
if [ "${1:-}" = "--publish" ]; then
    git tag "v$VERSION"
    git push origin "v$VERSION"
    gh release create "v$VERSION" "$ZIP" --title "Clawd $VERSION" --generate-notes
fi
