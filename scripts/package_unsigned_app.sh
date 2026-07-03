#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/BatteryMonitor.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$ROOT/.build/release/BatteryMonitorApp"
ICON_WORK_DIR="$ROOT/dist/AppIcon.iconset"

swift build -c release --product BatteryMonitorApp

rm -rf "$APP_DIR" "$ICON_WORK_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICON_WORK_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/BatteryMonitor"
chmod +x "$MACOS_DIR/BatteryMonitor"

python3 - <<'PY'
import plistlib
from pathlib import Path

root = Path.cwd()
info = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "Battery Monitor",
    "CFBundleExecutable": "BatteryMonitor",
    "CFBundleIconFile": "AppIcon",
    "CFBundleIdentifier": "com.lacdon.batterymonitor",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "Battery Monitor",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0",
    "LSUIElement": True,
    "NSBluetoothAlwaysUsageDescription": "Battery Monitor reads connected Bluetooth peripheral battery levels for low-battery alerts.",
    "NSSupportsAutomaticTermination": True,
    "NSSupportsSuddenTermination": True,
}
with open(root / "dist" / "BatteryMonitor.app" / "Contents" / "Info.plist", "wb") as file:
    plistlib.dump(info, file)
PY

cp "$ROOT"/Resources/App/Assets.xcassets/AppIcon.appiconset/*.png "$ICON_WORK_DIR/"
iconutil -c icns "$ICON_WORK_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICON_WORK_DIR"

codesign --force --deep --sign - "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$CONTENTS_DIR/Info.plist"
test -x "$MACOS_DIR/BatteryMonitor"
test -f "$RESOURCES_DIR/AppIcon.icns"

echo "Created unsigned local app bundle: $APP_DIR"
