#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAKE_DMG=false
if [[ "${1:-}" == "--dmg" ]]; then
    MAKE_DMG=true
elif [[ $# -gt 0 ]]; then
    echo "Usage: scripts/package.sh [--dmg]" >&2
    exit 2
fi

"$ROOT/scripts/build.sh" release
APP="$ROOT/dist/ScreenScribe.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
BASENAME="ScreenScribe-$VERSION-macos-$ARCH"
ARCHIVE="$ROOT/dist/$BASENAME.zip"
rm -f "$ARCHIVE"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ARCHIVE"
echo "$ARCHIVE"

if [[ "$MAKE_DMG" == true ]]; then
    STAGING="$(mktemp -d "${TMPDIR:-/tmp}/screenscribe-package.XXXXXX")"
    trap 'rm -rf "$STAGING"' EXIT
    ditto --norsrc --noextattr "$APP" "$STAGING/ScreenScribe.app"
    xattr -cr "$STAGING/ScreenScribe.app"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "ScreenScribe" -srcfolder "$STAGING" -ov -format UDZO "$ROOT/dist/$BASENAME.dmg"
    echo "$ROOT/dist/$BASENAME.dmg"
fi
