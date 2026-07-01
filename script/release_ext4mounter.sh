#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT_DIR/src"
APP_TEMPLATE="$ROOT_DIR/app/Ext4Mounter.app"
DIST_DIR="$ROOT_DIR/dist"
STAGE_APP="$DIST_DIR/Ext4Mounter.app"
APP_ENTITLEMENTS="$ROOT_DIR/app/Ext4Mounter.entitlements"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_TEMPLATE/Contents/Info.plist")"

IDENTITY="${DEVELOPER_ID_APPLICATION:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
TEAM_ID="${TEAM_ID:-}"
AD_HOC_SIGNING=false

if [[ "$IDENTITY" == "-" ]]; then
  AD_HOC_SIGNING=true
  ZIP_PATH="$DIST_DIR/Ext4Mounter-v$APP_VERSION-local-ad-hoc.zip"
else
  ZIP_PATH="$DIST_DIR/Ext4Mounter-v$APP_VERSION.zip"
fi

if [[ ! -d "$APP_TEMPLATE" ]]; then
  echo "Missing app template: $APP_TEMPLATE" >&2
  exit 1
fi

if [[ "$AD_HOC_SIGNING" == true ]]; then
  echo "==> DEVELOPER_ID_APPLICATION is not set; creating a local ad-hoc signed build"
  echo "==> This artifact is for local validation only and cannot be notarized."
  NOTARY_PROFILE=""
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -R "$APP_TEMPLATE" "$STAGE_APP"

echo "==> Building release products"
swift build -c release --product Ext4Mounter --package-path "$SRC_DIR"
swift build -c release --product com.ext4mounter.helper --package-path "$SRC_DIR"

BUILD_BIN_DIR="$(swift build -c release --package-path "$SRC_DIR" --show-bin-path)"
APP_BIN="$BUILD_BIN_DIR/Ext4Mounter"
HELPER_BIN="$BUILD_BIN_DIR/com.ext4mounter.helper"

if [[ ! -x "$APP_BIN" || ! -x "$HELPER_BIN" ]]; then
  echo "Missing release binaries in: $BUILD_BIN_DIR" >&2
  exit 1
fi

cp "$APP_BIN" "$STAGE_APP/Contents/MacOS/Ext4Mounter"
cp "$HELPER_BIN" "$STAGE_APP/Contents/MacOS/com.ext4mounter.helper"

if [[ ! -f "$STAGE_APP/Contents/Library/LaunchDaemons/com.ext4mounter.helper.plist" ]]; then
  echo "Missing LaunchDaemon plist in staged app bundle." >&2
  exit 1
fi

rm -rf "$STAGE_APP/Contents/_CodeSignature"
find "$STAGE_APP" -name "*.dSYM" -type d -prune -exec rm -rf {} +
find "$STAGE_APP" -name "_CodeSignature" -type d -prune -exec rm -rf {} +

echo "==> Signing helper"
HELPER_SIGN_ARGS=(--force --sign "$IDENTITY" --identifier "com.ext4mounter.helper")
APP_SIGN_ARGS=(--force --sign "$IDENTITY" --identifier "com.ext4mounter.app" --entitlements "$APP_ENTITLEMENTS")
if [[ "$AD_HOC_SIGNING" != true ]]; then
  HELPER_SIGN_ARGS+=(--timestamp --options runtime)
  APP_SIGN_ARGS+=(--timestamp --options runtime)
fi

codesign "${HELPER_SIGN_ARGS[@]}" "$STAGE_APP/Contents/MacOS/com.ext4mounter.helper"

echo "==> Signing app"
codesign "${APP_SIGN_ARGS[@]}" "$STAGE_APP"

echo "==> Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"
if spctl -a -vv "$STAGE_APP"; then
  echo "==> Gatekeeper assessment accepted"
elif [[ "$AD_HOC_SIGNING" == true ]]; then
  echo "==> Gatekeeper assessment rejected as expected for local ad-hoc signing"
else
  echo "==> Gatekeeper assessment rejected; check Developer ID signing and notarization" >&2
fi

echo "==> Creating zip archive"
ditto -c -k --keepParent "$STAGE_APP" "$ZIP_PATH"

if [[ "$AD_HOC_SIGNING" == true ]]; then
  cat > "$DIST_DIR/README.txt" <<EOF
Ext4Mounter local validation artifact

This dist directory was generated without DEVELOPER_ID_APPLICATION.
The app is ad-hoc signed for local validation only.
Gatekeeper rejection is expected, and this artifact cannot be notarized.

For distribution, set DEVELOPER_ID_APPLICATION and NOTARY_PROFILE, then rerun:

script/release_ext4mounter.sh
EOF
else
  cat > "$DIST_DIR/README.txt" <<EOF
Ext4Mounter distribution artifact

This dist directory was generated with:

DEVELOPER_ID_APPLICATION=$IDENTITY
NOTARY_PROFILE=${NOTARY_PROFILE:-<not set>}

App: $STAGE_APP
Zip: $ZIP_PATH
EOF
fi

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
