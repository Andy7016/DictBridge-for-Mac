#!/bin/bash
# Builds dist/DictBridge.app (universal arm64 + x86_64), plus a .zip and a .dmg.
#
#   scripts/build-app.sh              # version from Sources/DictBridgeCore/DictBridge.swift
#   VERSION=1.2.3 scripts/build-app.sh
#   ARCHS="--arch arm64" scripts/build-app.sh   # faster, Apple silicon only
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/DictBridgeCore/DictBridge.swift | head -1)}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:---arch arm64 --arch x86_64}"

echo "==> Building DictBridge $VERSION ($BUILD)"
# shellcheck disable=SC2086
swift build -c release $ARCHS --product DictBridgeApp
# shellcheck disable=SC2086
swift build -c release $ARCHS --product dictbridge
# shellcheck disable=SC2086
BIN="$(swift build -c release $ARCHS --show-bin-path)"

APP="dist/DictBridge.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DictBridgeApp" "$APP/Contents/MacOS/DictBridge"
cp "$BIN/dictbridge" "$APP/Contents/Resources/dictbridge"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Sparkle (in-app updates)"
# SwiftPM puts the binary framework next to the products; the app loads it from Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
[[ -d "$BIN/Sparkle.framework" ]] || { echo "Sparkle.framework not found in $BIN" >&2; exit 1; }
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/DictBridge" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/DictBridge"
fi
KEY_FILE="Resources/sparkle-public-key.txt"
PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$( [[ -f "$KEY_FILE" ]] && tr -d '[:space:]' < "$KEY_FILE" || true)}"
if [[ -n "$PUBLIC_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$APP/Contents/Info.plist"
else
  # Without the key Sparkle cannot verify anything: build without in-app updates.
  if [[ "${REQUIRE_UPDATE_KEY:-0}" == 1 ]]; then echo "error: $KEY_FILE is missing" >&2; exit 1; fi
  echo "warning: $KEY_FILE is missing; this build has in-app updates turned off"
  for k in SUPublicEDKey SUFeedURL; do /usr/libexec/PlistBuddy -c "Delete :$k" "$APP/Contents/Info.plist"; done
fi

echo "==> Icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
# Inside out: Sparkle's helpers, the framework, the CLI, then the app.
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign - "$SPK/XPCServices/Installer.xpc"
codesign --force --sign - --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
codesign --force --sign - "$SPK/Autoupdate"
codesign --force --sign - "$SPK/Updater.app"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP/Contents/Resources/dictbridge"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/DictBridge"

echo "==> Packaging"
ditto -c -k --keepParent "$APP" "dist/DictBridge-$VERSION.zip"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DictBridge $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/DictBridge-$VERSION.dmg" >/dev/null
ls -lh dist
