#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXPECTED_APP_ID="com.lacdon.batterymonitor"
EXPECTED_WIDGET_ID="com.lacdon.batterymonitor.widget"
EXPECTED_GROUP_ID="N4828PE57J.com.lacdon.batterymonitor"
REQUIRE_SIGNED_APP="${BATTERY_MONITOR_REQUIRE_SIGNED_APP:-0}"
APP_PATH="${1:-}"

if [ -z "$APP_PATH" ]; then
  if [ -d "DerivedData/Local/Build/Products/Release/BatteryMonitor.app" ]; then
    APP_PATH="DerivedData/Local/Build/Products/Release/BatteryMonitor.app"
  elif [ -d "DerivedData/Local/Build/Products/Debug/BatteryMonitor.app" ]; then
    APP_PATH="DerivedData/Local/Build/Products/Debug/BatteryMonitor.app"
  fi
fi

fail() {
  echo "System QA preflight failed: $*" >&2
  exit 1
}

warn() {
  echo "System QA preflight warning: $*" >&2
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

require_tool python3
require_tool plutil

plutil -lint \
  Resources/App/Info.plist \
  Resources/Widget/Info.plist \
  Config/BatteryMonitor.entitlements \
  Config/BatteryMonitorWidget.entitlements >/dev/null

python3 - "$EXPECTED_APP_ID" "$EXPECTED_WIDGET_ID" "$EXPECTED_GROUP_ID" <<'PY'
import plistlib
import sys

app_id, widget_id, group_id = sys.argv[1:4]

with open("Resources/App/Info.plist", "rb") as file:
    app_info = plistlib.load(file)
with open("Resources/Widget/Info.plist", "rb") as file:
    widget_info = plistlib.load(file)
with open("Config/BatteryMonitor.entitlements", "rb") as file:
    app_entitlements = plistlib.load(file)
with open("Config/BatteryMonitorWidget.entitlements", "rb") as file:
    widget_entitlements = plistlib.load(file)

allowed_source_bundle_ids = {app_id, "$(PRODUCT_BUNDLE_IDENTIFIER)"}
if app_info.get("CFBundleIdentifier") not in allowed_source_bundle_ids:
    raise SystemExit(f"App Info.plist bundle id mismatch: {app_info.get('CFBundleIdentifier')!r}")
if app_info.get("LSUIElement") is not True:
    raise SystemExit("App Info.plist must keep LSUIElement=true for menu bar operation")
if not app_info.get("NSBluetoothAlwaysUsageDescription"):
    raise SystemExit("App Info.plist must keep NSBluetoothAlwaysUsageDescription")

extension = widget_info.get("NSExtension", {})
allowed_source_widget_ids = {widget_id, "$(PRODUCT_BUNDLE_IDENTIFIER)"}
if widget_info.get("CFBundleIdentifier") not in allowed_source_widget_ids:
    raise SystemExit(f"Widget Info.plist bundle id mismatch: {widget_info.get('CFBundleIdentifier')!r}")
if extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
    raise SystemExit("Widget Info.plist must keep the WidgetKit extension point")

for label, entitlements in [
    ("app", app_entitlements),
    ("widget", widget_entitlements),
]:
    groups = entitlements.get("com.apple.security.application-groups")
    if groups != [group_id]:
        raise SystemExit(f"{label} entitlements must contain exactly {group_id}: {groups!r}")

print("Source plist and entitlements preflight OK")
PY

if command -v ruby >/dev/null 2>&1; then
  ruby - "$EXPECTED_APP_ID" "$EXPECTED_WIDGET_ID" <<'RUBY'
require "yaml"

app_id, widget_id = ARGV
project = YAML.load_file("project.yml")
targets = project.fetch("targets")
app = targets.fetch("BatteryMonitor")
widget = targets.fetch("BatteryMonitorWidget")

unless app.fetch("settings").fetch("base").fetch("PRODUCT_BUNDLE_IDENTIFIER") == app_id
  warn "BatteryMonitor target bundle id mismatch"
  exit 1
end

unless widget.fetch("settings").fetch("base").fetch("PRODUCT_BUNDLE_IDENTIFIER") == widget_id
  warn "BatteryMonitorWidget target bundle id mismatch"
  exit 1
end

unless app.fetch("entitlements").fetch("path") == "Config/BatteryMonitor.entitlements"
  warn "BatteryMonitor target entitlements path mismatch"
  exit 1
end

unless widget.fetch("entitlements").fetch("path") == "Config/BatteryMonitorWidget.entitlements"
  warn "BatteryMonitorWidget target entitlements path mismatch"
  exit 1
end

dependencies = app.fetch("dependencies")
unless dependencies.any? { |dependency| dependency["target"] == "BatteryMonitorWidget" && dependency["embed"] == true }
  warn "BatteryMonitor target must embed BatteryMonitorWidget"
  exit 1
end

puts "XcodeGen signing and widget preflight OK"
RUBY
else
  warn "ruby unavailable; skipped project.yml structured preflight"
fi

check_entitlements() {
  bundle_path="$1"
  label="$2"
  expected_group="$3"
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/battery-monitor-entitlements.XXXXXX")"

  if codesign -d --entitlements :- "$bundle_path" >"$tmp_file" 2>/dev/null && [ -s "$tmp_file" ]; then
    python3 - "$tmp_file" "$expected_group" "$label" <<'PY'
import plistlib
import sys

path, expected_group, label = sys.argv[1:4]
with open(path, "rb") as file:
    entitlements = plistlib.load(file)
groups = entitlements.get("com.apple.security.application-groups")
if groups != [expected_group]:
    raise SystemExit(f"{label} signed entitlements must contain exactly {expected_group}: {groups!r}")
PY
  else
    rm -f "$tmp_file"
    if [ "$REQUIRE_SIGNED_APP" = "1" ]; then
      fail "$label is signed without readable App Group entitlements"
    fi
    warn "$label has no readable signed entitlements; signed Widget/App Group QA still needs a developer-signed build"
    return 0
  fi

  rm -f "$tmp_file"
}

check_developer_signature() {
  bundle_path="$1"
  label="$2"
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/battery-monitor-signature.XXXXXX")"

  if ! codesign -dv "$bundle_path" >"$tmp_file" 2>&1; then
    rm -f "$tmp_file"
    if [ "$REQUIRE_SIGNED_APP" = "1" ]; then
      fail "$label does not have readable code signing metadata"
    fi
    warn "$label does not have readable code signing metadata"
    return 1
  fi

  if grep -q '^Signature=adhoc$' "$tmp_file" \
    || grep -q '^TeamIdentifier=not set$' "$tmp_file" \
    || ! grep -q '^TeamIdentifier=' "$tmp_file"; then
    rm -f "$tmp_file"
    if [ "$REQUIRE_SIGNED_APP" = "1" ]; then
      fail "$label must be developer-signed, not ad-hoc signed"
    fi
    warn "$label is not developer-signed; system Widget, notification, and login-item QA still require a developer-signed build"
    return 1
  fi

  rm -f "$tmp_file"
  return 0
}

if [ -n "$APP_PATH" ]; then
  [ -d "$APP_PATH" ] || fail "app bundle does not exist: $APP_PATH"

  python3 - "$APP_PATH" "$EXPECTED_APP_ID" "$EXPECTED_WIDGET_ID" <<'PY'
import os
import plistlib
import sys

app_path, expected_app_id, expected_widget_id = sys.argv[1:4]
app_info_path = os.path.join(app_path, "Contents", "Info.plist")
widget_path = os.path.join(app_path, "Contents", "PlugIns", "BatteryMonitorWidget.appex")
widget_info_path = os.path.join(widget_path, "Contents", "Info.plist")

with open(app_info_path, "rb") as file:
    app_info = plistlib.load(file)
with open(widget_info_path, "rb") as file:
    widget_info = plistlib.load(file)

app_executable = os.path.join(app_path, "Contents", "MacOS", app_info.get("CFBundleExecutable", ""))
widget_executable = os.path.join(widget_path, "Contents", "MacOS", widget_info.get("CFBundleExecutable", ""))
app_icon = os.path.join(app_path, "Contents", "Resources", "AppIcon.icns")
compiled_assets = os.path.join(app_path, "Contents", "Resources", "Assets.car")

if app_info.get("CFBundleIdentifier") != expected_app_id:
    raise SystemExit(f"Built app bundle id mismatch: {app_info.get('CFBundleIdentifier')!r}")
if app_info.get("LSUIElement") is not True:
    raise SystemExit("Built app must keep LSUIElement=true")
if not app_info.get("NSBluetoothAlwaysUsageDescription"):
    raise SystemExit("Built app must keep NSBluetoothAlwaysUsageDescription")
if not os.path.isfile(app_executable) or not os.access(app_executable, os.X_OK):
    raise SystemExit(f"Built app executable is missing or not executable: {app_executable}")
if not os.path.isfile(app_icon) or os.path.getsize(app_icon) == 0:
    raise SystemExit(f"Built app icon is missing: {app_icon}")
if not os.path.isfile(compiled_assets) or os.path.getsize(compiled_assets) == 0:
    raise SystemExit(f"Built app asset catalog is missing: {compiled_assets}")

extension = widget_info.get("NSExtension", {})
if widget_info.get("CFBundleIdentifier") != expected_widget_id:
    raise SystemExit(f"Built widget bundle id mismatch: {widget_info.get('CFBundleIdentifier')!r}")
if extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
    raise SystemExit("Built widget must keep the WidgetKit extension point")
if not os.path.isfile(widget_executable) or not os.access(widget_executable, os.X_OK):
    raise SystemExit(f"Built widget executable is missing or not executable: {widget_executable}")

print("Built app/widget bundle preflight OK")
PY

  if command -v codesign >/dev/null 2>&1 \
    && codesign -dv "$APP_PATH" >/dev/null 2>&1 \
    && codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    check_entitlements "$APP_PATH" "BatteryMonitor.app" "$EXPECTED_GROUP_ID"
    check_entitlements "$APP_PATH/Contents/PlugIns/BatteryMonitorWidget.appex" "BatteryMonitorWidget.appex" "$EXPECTED_GROUP_ID"
    developer_signed=1
    check_developer_signature "$APP_PATH" "BatteryMonitor.app" || developer_signed=0
    check_developer_signature "$APP_PATH/Contents/PlugIns/BatteryMonitorWidget.appex" "BatteryMonitorWidget.appex" || developer_signed=0
    if [ "$developer_signed" = "1" ]; then
      echo "Developer-signed app bundle preflight OK"
    fi
  else
    if [ "$REQUIRE_SIGNED_APP" = "1" ]; then
      fail "app bundle is not signed: $APP_PATH"
    fi
    warn "app bundle is not signed; system Widget, notification, and login-item QA still require a developer-signed app"
  fi
else
  if [ "$REQUIRE_SIGNED_APP" = "1" ]; then
    fail "no signed app path was provided"
  fi
  warn "no built app bundle found; skipped app bundle preflight"
fi

echo "System QA preflight OK"
