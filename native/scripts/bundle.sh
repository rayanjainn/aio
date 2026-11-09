#!/usr/bin/env bash
# Builds a universal AIO.app (and AIO.dmg) from the Swift package.
# Usage: native/scripts/bundle.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.0.0-dev}"

swift --version
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Cortex"

echo "== cortexd (search engine, installed as Helpers/aiod)"
rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true
( cd ../cortexd
  cargo build --release --target aarch64-apple-darwin
  cargo build --release --target x86_64-apple-darwin )

OUT=build
APP="$OUT/AIO.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AIO"
mkdir -p "$APP/Contents/Helpers"
lipo -create ../cortexd/target/aarch64-apple-darwin/release/cortexd ../cortexd/target/x86_64-apple-darwin/release/cortexd \
  -output "$APP/Contents/Helpers/aiod"
codesign --force --sign - "$APP/Contents/Helpers/aiod"
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
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/aiod"
  codesign --force --timestamp --options runtime --entitlements Entitlements.plist --sign "$SIGN_IDENTITY" "$APP"
elif [ -n "${SELF_SIGN_IDENTITY:-}" ]; then
  # Self-signed, not hardened (Apple Events keep working). The signature's identity is the same for every
  # release, so privacy grants survive updates — unlike ad-hoc, whose identity is a hash of each build.
  echo "Self-signing with: $SELF_SIGN_IDENTITY"
  codesign --force --sign "$SELF_SIGN_IDENTITY" "$APP/Contents/Helpers/aiod"
  codesign --force --sign "$SELF_SIGN_IDENTITY" --entitlements Entitlements.plist "$APP"
else
  # Ad-hoc signed, NOT hardened: a hardened runtime without entitlements makes
  # macOS silently refuse Apple Events.
  codesign --force --sign - --entitlements Entitlements.plist "$APP"
fi
codesign --verify --verbose=2 "$APP"
codesign -dv --entitlements - "$APP" 2>&1 | head -20 || true

# The disk image: AIO.app and a link to Applications. It also carries a hidden copy named Cortex.app,
# because the updater in versions up to v0.5.0 (when the app was called Cortex) only installs "Cortex.app";
# the new version then renames itself to AIO.app on first launch (AppRename in Updates.swift).
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/AIO.app"
ditto "$APP" "$STAGE/Cortex.app"
chflags hidden "$STAGE/Cortex.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname AIO -srcfolder "$STAGE" -ov -format UDZO "$OUT/AIO.dmg"
rm -rf "$STAGE"
# Check the layout both updaters rely on.
MNT=$(mktemp -d /tmp/aio-check.XXXXXX)
hdiutil attach -nobrowse -quiet -mountpoint "$MNT" "$OUT/AIO.dmg"
[ -d "$MNT/AIO.app" ] && [ -d "$MNT/Cortex.app" ] && [ -x "$MNT/AIO.app/Contents/MacOS/AIO" ] || { ls -la "$MNT"; hdiutil detach "$MNT" -quiet; echo "dmg layout is wrong"; exit 1; }
codesign --verify "$MNT/Cortex.app"
hdiutil detach "$MNT" -quiet

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT/AIO.dmg"
fi
if [ -n "${SIGN_IDENTITY:-}" ] && [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  echo "Notarizing…"
  xcrun notarytool submit "$OUT/AIO.dmg" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  xcrun stapler staple "$OUT/AIO.dmg"
fi
ls -la "$OUT"
