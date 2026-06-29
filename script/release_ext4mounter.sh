#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT_DIR/src"
APP_TEMPLATE="$ROOT_DIR/app/Ext4Mounter.app"
DIST_DIR="$ROOT_DIR/dist"
STAGE_APP="$DIST_DIR/Ext4Mounter.app"
ZIP_PATH="$DIST_DIR/Ext4Mounter.zip"
APP_ENTITLEMENTS="$ROOT_DIR/app/Ext4Mounter.entitlements"

IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
TEAM_ID="${TEAM_ID:-}"

if [[ ! -d "$APP_TEMPLATE" ]]; then
  echo "Missing app template: $APP_TEMPLATE" >&2
  exit 1
fi

if [[ -z "$IDENTITY" ]]; then
  echo "DEVELOPER_ID_APPLICATION is required." >&2
  echo 'Example: export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"' >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$STAGE_APP" "$ZIP_PATH"
cp -R "$APP_TEMPLATE" "$STAGE_APP"

echo "==> Building release products"
swift build -c release --product Ext4Mounter --product com.ext4mounter.helper --package-path "$SRC_DIR"

APP_BIN="$SRC_DIR/.build/arm64-apple-macosx/release/Ext4Mounter"
HELPER_BIN="$SRC_DIR/.build/arm64-apple-macosx/release/com.ext4mounter.helper"

cp "$APP_BIN" "$STAGE_APP/Contents/MacOS/Ext4Mounter"
cp "$HELPER_BIN" "$STAGE_APP/Contents/MacOS/com.ext4mounter.helper"

if [[ ! -f "$STAGE_APP/Contents/Library/LaunchDaemons/com.ext4mounter.helper.plist" ]]; then
  echo "Missing LaunchDaemon plist in staged app bundle." >&2
  exit 1
fi

rm -rf "$STAGE_APP/Contents/_CodeSignature"
find "$STAGE_APP" -name "*.dSYM" -prune -o -name "_CodeSignature" -prune

echo "==> Signing helper"
codesign \
  --force \
  --sign "$IDENTITY" \
  --timestamp \
  --options runtime \
  --identifier "com.ext4mounter.helper" \
  "$STAGE_APP/Contents/MacOS/com.ext4mounter.helper"

echo "==> Signing app"
codesign \
  --force \
  --sign "$IDENTITY" \
  --timestamp \
  --options runtime \
  --entitlements "$APP_ENTITLEMENTS" \
  --identifier "com.ext4mounter.app" \
  "$STAGE_APP"

echo "==> Verifying signatures"
codesign --verify --verbose=2 "$STAGE_APP"
spctl -a -vv "$STAGE_APP" || true

echo "==> Creating zip archive"
ditto -c -k --keepParent "$STAGE_APP" "$ZIP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "==> Submitting to notarization"
  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "==> Stapling ticket"
  xcrun stapler staple "$STAGE_APP"
  xcrun stapler validate "$STAGE_APP"
fi

echo "==> Done"
echo "App: $STAGE_APP"
echo "Zip: $ZIP_PATH"
if [[ -n "$TEAM_ID" ]]; then
  echo "Team ID hint: $TEAM_ID"
fi
