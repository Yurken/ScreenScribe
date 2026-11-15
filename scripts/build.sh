#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
    echo "Usage: scripts/build.sh [release|debug]" >&2
    exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ScreenScribe requires macOS and the Xcode command line tools." >&2
    exit 1
fi

cd "$ROOT"
mkdir -p "$ROOT/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
BUILD_OPTIONS=(--cache-path "$ROOT/.build/cache")
# Nested process sandboxes are unavailable in some managed build environments.
if [[ "${SCREENSCRIBE_MANAGED_BUILD:-0}" == "1" ]]; then
    BUILD_OPTIONS+=(--disable-sandbox -debug-info-format none)
fi
swift build "${BUILD_OPTIONS[@]}" --configuration "$CONFIGURATION" --product ScreenScribe
BIN_DIRECTORY="$(swift build "${BUILD_OPTIONS[@]}" --configuration "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/dist/ScreenScribe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIRECTORY/ScreenScribe" "$APP/Contents/MacOS/ScreenScribe"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -n "${SCREENSCRIBE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SCREENSCRIBE_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${SCREENSCRIBE_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SCREENSCRIBE_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

ICONSET="$ROOT/.build/ScreenScribe.iconset"
mkdir -p "$ICONSET"
swift -module-cache-path "$ROOT/.build/module-cache" "$ROOT/scripts/generate-icon.swift" "$ICONSET"
cp "$ROOT/.build/ScreenScribe.icns" "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist"
# Finder metadata inherited from copied files is not part of the app signature.
xattr -cr "$APP"

# A Developer ID identity can be supplied for distribution. The default is a
# reproducible local ad-hoc signature; this does not claim Apple notarization.
SIGNING_IDENTITY="${SCREENSCRIBE_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --entitlements "$ROOT/Resources/ScreenScribe.entitlements" --sign - "$APP"
else
    codesign --force --options runtime --entitlements "$ROOT/Resources/ScreenScribe.entitlements" --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "$APP"
