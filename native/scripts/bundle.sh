#!/usr/bin/env bash
# Builds a universal Cortex.app (and Cortex.dmg) from the Swift package.
# Usage: native/scripts/bundle.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.0.0-dev}"

swift --version
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Cortex"

echo "== cortexd (search engine)"
rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true
( cd ../cortexd
  cargo build --release --target aarch64-apple-darwin
  cargo build --release --target x86_64-apple-darwin )

OUT=build
APP="$OUT/Cortex.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cortex"
mkdir -p "$APP/Contents/Helpers"
lipo -create ../cortexd/target/aarch64-apple-darwin/release/cortexd ../cortexd/target/x86_64-apple-darwin/release/cortexd \
  -output "$APP/Contents/Helpers/cortexd"
codesign --force --sign - "$APP/Contents/Helpers/cortexd"
sed "s/__VERSION__/${VERSION}/g" Info.plist > "$APP/Contents/Info.plist"
cp -a Resources/mediaremote "$APP/Contents/Resources/mediaremote"
cp Resources/icon.icns "$APP/Contents/Resources/icon.icns"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Developer ID: hardened runtime is required for notarization. The Apple Events entitlement
  # keeps automation working under it.
  echo "Signing with: $SIGN_IDENTITY"
  find "$APP/Contents/Resources/mediaremote" -type f \( -perm -u+x -o -name "*.dylib" \) -print0 | while IFS= read -r -d '' f; do
    file "$f" | grep -q Mach-O && codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$f"
  done
  find "$APP/Contents/Resources/mediaremote" -name "*.framework" -maxdepth 2 -print0 | while IFS= read -r -d '' fw; do
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$fw"
  done
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/cortexd"
  codesign --force --timestamp --options runtime --entitlements Entitlements.plist --sign "$SIGN_IDENTITY" "$APP"
else
  # Ad-hoc signed, NOT hardened: a hardened runtime without entitlements makes
  # macOS silently refuse Apple Events.
  codesign --force --sign - --entitlements Entitlements.plist "$APP"
fi
codesign --verify --verbose=2 "$APP"
codesign -dv --entitlements - "$APP" 2>&1 | head -20 || true

hdiutil create -volname Cortex -srcfolder "$APP" -ov -format UDZO "$OUT/Cortex.dmg"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT/Cortex.dmg"
fi
if [ -n "${SIGN_IDENTITY:-}" ] && [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  echo "Notarizing…"
  xcrun notarytool submit "$OUT/Cortex.dmg" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  xcrun stapler staple "$OUT/Cortex.dmg"
fi
ls -la "$OUT"
