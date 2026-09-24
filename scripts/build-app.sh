#!/usr/bin/env bash
# Builds build/Xnap.app and signs it with the sandbox entitlements.
#
#   CONFIG=debug ./scripts/build-app.sh                              # debug build
#   SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh      # stable signature
#
# By default the app is signed ad hoc. macOS ties the Screen Recording permission to the
# signature, so with ad-hoc signing you re-grant it after each rebuild. Signing with a
# real identity (SIGN_IDENTITY) keeps the permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Xnap.app"
IDENTITY="${SIGN_IDENTITY:--}"

swift build -c "$CONFIG" --product Xnap 2>&1 | grep -v "search path .* not found" || true
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
test -x "$BIN_DIR/Xnap" || { echo "Build failed" >&2; exit 1; }

if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Xnap" "$APP/Contents/MacOS/Xnap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --timestamp=none \
  --entitlements Resources/Xnap.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP ($CONFIG, signed with: $IDENTITY)"
