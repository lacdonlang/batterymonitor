#!/bin/zsh
# Builds a notarized, distributable DMG of BatteryMonitor.
#
# One-time setup (interactive, stores credentials in the keychain):
#   xcrun notarytool store-credentials battery-monitor-notary \
#     --apple-id <your Apple ID email> --team-id N4828PE57J
#   (use an app-specific password from https://account.apple.com → Sign-In and
#    Security → App-Specific Passwords)
#
# Usage:
#   Scripts/release_dmg.sh              # build + notarize + staple
#   SKIP_NOTARIZE=1 Scripts/release_dmg.sh   # local signing check only
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="N4828PE57J"
NOTARY_PROFILE="${NOTARY_PROFILE:-battery-monitor-notary}"
BUILD_DIR="DerivedData/Release-DMG"
ARCHIVE_PATH="$BUILD_DIR/BatteryMonitor.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DIST_DIR="dist"

echo "==> Regenerating Xcode project"
xcodegen generate --spec project.yml >/dev/null

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | /usr/bin/sed 's/.*"\(.*\)"/\1/')
DMG_PATH="$DIST_DIR/BatteryMonitor-$VERSION.dmg"
echo "==> Version $VERSION"

echo "==> Archiving (Release, hardened runtime)"
xcodebuild archive \
  -project BatteryMonitor.xcodeproj \
  -scheme BatteryMonitor \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_IDENTITY="Apple Development" \
  | grep -E "error|warning: .*sign|ARCHIVE" || true
[ -d "$ARCHIVE_PATH" ] || { echo "archive failed"; exit 1; }

echo "==> Exporting with Developer ID signing"
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist Scripts/ExportOptions-developer-id.plist \
  -exportPath "$EXPORT_PATH" \
  -allowProvisioningUpdates

APP_PATH="$EXPORT_PATH/BatteryMonitor.app"
[ -d "$APP_PATH" ] || { echo "export failed"; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=1 "$APP_PATH"
codesign -dvv "$APP_PATH" 2>&1 | grep "Authority=Developer ID Application" \
  || { echo "app is not Developer ID signed"; exit 1; }

build_dmg() {
  mkdir -p "$DIST_DIR"
  rm -f "$DMG_PATH"
  local staging
  staging=$(mktemp -d)
  cp -R "$APP_PATH" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "BatteryMonitor" -srcfolder "$staging" -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$staging"
  echo "    $DMG_PATH"
}

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "==> Building DMG"
  build_dmg
  echo "==> SKIP_NOTARIZE=1, done (unnotarized)"
  exit 0
fi

# Notarize and staple the app itself first, so launches validate offline;
# then notarize the DMG that carries the stapled app.
echo "==> Notarizing app (profile: $NOTARY_PROFILE)"
APP_ZIP="$BUILD_DIR/BatteryMonitor.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"

echo "==> Building DMG"
build_dmg

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> Gatekeeper assessment of the shipped app"
MOUNT_POINT=$(mktemp -d)
hdiutil attach "$DMG_PATH" -nobrowse -quiet -mountpoint "$MOUNT_POINT"
spctl -a -vv -t exec "$MOUNT_POINT/BatteryMonitor.app"
xcrun stapler validate "$MOUNT_POINT/BatteryMonitor.app"
hdiutil detach "$MOUNT_POINT" -quiet

echo ""
echo "Release ready: $DMG_PATH"
