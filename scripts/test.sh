#!/bin/sh
set -eu

SNAPSHOT_JSON="${TMPDIR:-/tmp}/battery-monitor-snapshot.json"
PACKAGE_JSON="${TMPDIR:-/tmp}/battery-monitor-package.json"

swift build
swift build -c release
if rg -n '^import[[:space:]]+(BatteryMonitorCore|UserNotifications|CoreBluetooth|IOBluetooth|IOKit|ServiceManagement)\b' Sources/BatteryMonitorWidget; then
  echo "Widget target must not import monitoring, notification, Bluetooth, or login-item APIs" >&2
  exit 1
fi
swift package describe --type json > "$PACKAGE_JSON"
python3 - "$PACKAGE_JSON" <<'PY'
import json
import sys

with open(sys.argv[1]) as file:
    package = json.load(file)

targets = {target["name"]: target for target in package["targets"]}
dependencies = sorted(targets["BatteryMonitorWidget"].get("target_dependencies", []))
if dependencies != ["BatteryMonitorShared"]:
    raise SystemExit(f"Unexpected SwiftPM Widget dependencies: {dependencies}")

print("SwiftPM Widget dependency boundary OK")
PY
./scripts/package_unsigned_app.sh
dist/BatteryMonitor.app/Contents/MacOS/BatteryMonitor &
APP_PID=$!
sleep 3
if kill -0 "$APP_PID" >/dev/null 2>&1; then
  kill "$APP_PID"
  wait "$APP_PID" 2>/dev/null || true
  echo "Unsigned app executable smoke test OK"
else
  wait "$APP_PID"
  echo "Unsigned app executable exited during smoke test" >&2
  exit 1
fi
swift run BatteryMonitorTestHarness
swift run --quiet BatteryMonitorCLI --json > "$SNAPSHOT_JSON"
python3 -m json.tool "$SNAPSHOT_JSON" >/dev/null
WIDGET_REPORT_LOG="${TMPDIR:-/tmp}/battery-monitor-widget-report.log"
swift run --quiet BatteryMonitorCLI --widget-report "$SNAPSHOT_JSON" > "$WIDGET_REPORT_LOG"
grep -q "Widget display report" "$WIDGET_REPORT_LOG"
grep -q "Small:" "$WIDGET_REPORT_LOG"
grep -q "Medium:" "$WIDGET_REPORT_LOG"
grep -q "Large:" "$WIDGET_REPORT_LOG"
grep -q "Freshness:" "$WIDGET_REPORT_LOG"
NOTIFICATION_REPORT_LOG="${TMPDIR:-/tmp}/battery-monitor-notification-report.log"
swift run --quiet BatteryMonitorCLI --notification-report "$SNAPSHOT_JSON" --threshold 100 > "$NOTIFICATION_REPORT_LOG"
grep -q "Low battery notification report" "$NOTIFICATION_REPORT_LOG"
grep -q "Action identifiers:" "$NOTIFICATION_REPORT_LOG"
grep -q "Payload title:" "$NOTIFICATION_REPORT_LOG"
grep -q "Alert devices:" "$NOTIFICATION_REPORT_LOG"
SETTINGS_REPORT_JSON="${TMPDIR:-/tmp}/battery-monitor-settings-report-settings.json"
SETTINGS_REPORT_LOG="${TMPDIR:-/tmp}/battery-monitor-settings-report.log"
python3 - "$SNAPSHOT_JSON" "$SETTINGS_REPORT_JSON" <<'PY'
import json
import sys

with open(sys.argv[1]) as file:
    snapshot = json.load(file)

devices = snapshot.get("devices", [])
ignored_device = devices[0] if devices else None
ignored_ids = [ignored_device["id"]] if ignored_device else []
ignored_fingerprints = []
if ignored_device:
    ignored_fingerprints.append(
        f'{ignored_device.get("name", "").lower()}|{ignored_device.get("kind", "")}|{ignored_device.get("source", "").lower()}'
    )

settings = {
    "lowBatteryThreshold": 100,
    "recoveryMargin": 5,
    "pollingInterval": 180,
    "reminderCooldown": 7200,
    "launchAtLogin": True,
    "ignoredDeviceIDs": ignored_ids,
    "ignoredDeviceFingerprints": ignored_fingerprints,
}

with open(sys.argv[2], "w") as file:
    json.dump(settings, file, ensure_ascii=False, sort_keys=True)
PY
swift run --quiet BatteryMonitorCLI --settings-report "$SETTINGS_REPORT_JSON" --settings-report-snapshot "$SNAPSHOT_JSON" > "$SETTINGS_REPORT_LOG"
grep -q "Settings report" "$SETTINGS_REPORT_LOG"
grep -q "Launch at login preference: true" "$SETTINGS_REPORT_LOG"
grep -q "Ignored device IDs:" "$SETTINGS_REPORT_LOG"
grep -q "Device settings impact:" "$SETTINGS_REPORT_LOG"
BATTERY_SOURCE_DIAGNOSTICS_LOG="${TMPDIR:-/tmp}/battery-monitor-source-diagnostics.log"
swift run --quiet BatteryMonitorCLI --diagnose-battery-sources > "$BATTERY_SOURCE_DIAGNOSTICS_LOG"
grep -q "IORegistry battery diagnostics" "$BATTERY_SOURCE_DIAGNOSTICS_LOG"
grep -q "ChargingFields" "$BATTERY_SOURCE_DIAGNOSTICS_LOG"
grep -q "BatteryStatusFlags" "$BATTERY_SOURCE_DIAGNOSTICS_LOG"
grep -q "DecodedCharging" "$BATTERY_SOURCE_DIAGNOSTICS_LOG"
FIRST_VISIBLE_DEVICE="$(python3 - "$SNAPSHOT_JSON" <<'PY'
import json
import sys

with open(sys.argv[1]) as file:
    snapshot = json.load(file)

devices = snapshot.get("devices", [])
if not devices:
    raise SystemExit("BatteryMonitorCLI JSON does not contain any visible devices")
print(devices[0]["name"])
PY
)"
./scripts/verify_device_visible.sh --name "$FIRST_VISIBLE_DEVICE" --json-file "$SNAPSHOT_JSON" >/dev/null
DEVICE_VISIBLE_LOG="${TMPDIR:-/tmp}/battery-monitor-device-visible.log"
DEVICE_VISIBLE_ARGUMENT_LOG="${TMPDIR:-/tmp}/battery-monitor-device-visible-arguments.log"
DEVICE_VISIBLE_ADDRESS_JSON="${TMPDIR:-/tmp}/battery-monitor-device-visible-address.json"
DEVICE_VISIBLE_BLUETOOTH_JSON="${TMPDIR:-/tmp}/battery-monitor-device-visible-bluetooth.json"
BLUETOOTH_CANDIDATE_JSON="${TMPDIR:-/tmp}/battery-monitor-bluetooth-candidates.json"
BLUETOOTH_CANDIDATE_LOG="${TMPDIR:-/tmp}/battery-monitor-bluetooth-candidates.log"
python3 - "$DEVICE_VISIBLE_ADDRESS_JSON" <<'PY'
import json
import sys

payload = {
    "devices": [
        {
            "id": "ioregistry:aa-bb-cc-dd-ee-ff",
            "name": "QA Magic Trackpad",
            "kind": "peripheral",
            "percentage": 55,
            "isCharging": None,
            "isConnected": True,
            "source": "IORegistry",
            "updatedAt": "2026-06-30T00:00:00Z",
        }
    ],
    "updatedAt": "2026-06-30T00:00:00Z",
}

with open(sys.argv[1], "w") as file:
    json.dump(payload, file, sort_keys=True)
PY
./scripts/verify_device_visible.sh \
  --address "AA:BB:CC:DD:EE:FF" \
  --kind peripheral \
  --json-file "$DEVICE_VISIBLE_ADDRESS_JSON" >/dev/null
if ./scripts/verify_device_visible.sh --json-file "$SNAPSHOT_JSON" > "$DEVICE_VISIBLE_ARGUMENT_LOG" 2>&1; then
  echo "Device visibility script must require a name or address filter" >&2
  exit 1
fi
grep -q "Missing required --name or --address argument" "$DEVICE_VISIBLE_ARGUMENT_LOG"
python3 - "$DEVICE_VISIBLE_BLUETOOTH_JSON" <<'PY'
import json
import sys

payload = {
    "SPBluetoothDataType": [
        {
            "device_not_connected": [
                {
                    "__BatteryMonitorMissingDevice__ Trackpad": {
                        "device_address": "AA:BB:CC:DD:EE:FF",
                        "device_minorType": "Magic Trackpad",
                    }
                }
            ]
        }
    ]
}

with open(sys.argv[1], "w") as file:
    json.dump(payload, file, sort_keys=True)
PY
if ./scripts/verify_device_visible.sh \
  --name "__BatteryMonitorMissingDevice__" \
  --json-file "$SNAPSHOT_JSON" \
  --bluetooth-json-file "$DEVICE_VISIBLE_BLUETOOTH_JSON" > "$DEVICE_VISIBLE_LOG" 2>&1; then
  echo "Device visibility script must reject a missing device" >&2
  exit 1
fi
grep -q "Device not visible" "$DEVICE_VISIBLE_LOG"
grep -q "Paired Bluetooth candidates matching filter:" "$DEVICE_VISIBLE_LOG"
grep -q "__BatteryMonitorMissingDevice__ Trackpad" "$DEVICE_VISIBLE_LOG"
grep -q "connect or wake the device" "$DEVICE_VISIBLE_LOG"
if ./scripts/verify_device_visible.sh \
  --address "AA:BB:CC:DD:EE:FF" \
  --json-file "$SNAPSHOT_JSON" \
  --bluetooth-json-file "$DEVICE_VISIBLE_BLUETOOTH_JSON" > "$DEVICE_VISIBLE_LOG" 2>&1; then
  echo "Device visibility script must reject a missing address" >&2
  exit 1
fi
grep -q "address='AA:BB:CC:DD:EE:FF'" "$DEVICE_VISIBLE_LOG"
grep -q "__BatteryMonitorMissingDevice__ Trackpad" "$DEVICE_VISIBLE_LOG"
python3 - "$BLUETOOTH_CANDIDATE_JSON" <<'PY'
import json
import sys

payload = {
    "SPBluetoothDataType": [
        {
            "device_connected": [
                {
                    "QA Magic Trackpad": {
                        "device_address": "AA:BB:CC:DD:EE:FF",
                        "device_minorType": "Magic Trackpad",
                    }
                },
                {
                    "QA MX Master": {
                        "device_address": "D1:F6:C0:1B:2D:FE",
                        "device_minorType": "Mouse",
                    }
                },
            ],
            "device_not_connected": [
                {
                    "QA AirPods Max": {
                        "device_address": "70:F9:4A:9F:1E:76",
                        "device_minorType": "Headphones",
                    }
                },
                {
                    "QA iPhone": {
                        "device_address": "34:10:BE:75:0A:1B",
                    }
                },
            ],
        }
    ]
}

with open(sys.argv[1], "w") as file:
    json.dump(payload, file, sort_keys=True)
PY
./scripts/report_bluetooth_candidate_visibility.sh \
  --json-file "$DEVICE_VISIBLE_ADDRESS_JSON" \
  --bluetooth-json-file "$BLUETOOTH_CANDIDATE_JSON" > "$BLUETOOTH_CANDIDATE_LOG"
grep -q "Bluetooth battery candidate visibility report" "$BLUETOOTH_CANDIDATE_LOG"
grep -q "Summary: paired battery candidates=3, visible=1, not visible=2" "$BLUETOOTH_CANDIDATE_LOG"
grep -q "QA Magic Trackpad" "$BLUETOOTH_CANDIDATE_LOG"
grep -q "visible as QA Magic Trackpad (55%, IORegistry)" "$BLUETOOTH_CANDIDATE_LOG"
grep -q "QA MX Master | bluetooth=connected" "$BLUETOOTH_CANDIDATE_LOG"
grep -q "connected but not present in BatteryMonitorCLI snapshot" "$BLUETOOTH_CANDIDATE_LOG"
grep -q "QA AirPods Max | bluetooth=not connected" "$BLUETOOTH_CANDIDATE_LOG"
grep -q "verify_device_visible.sh --address \"D1:F6:C0:1B:2D:FE\" --kind peripheral" "$BLUETOOTH_CANDIDATE_LOG"
echo "Device visibility verification script OK"
COMPAT_REPORT="${TMPDIR:-/tmp}/battery-monitor-device-compatibility-report.md"
swift run BatteryMonitorCLI --report "$COMPAT_REPORT"
grep -q "## 蓝牙候选设备诊断" "$COMPAT_REPORT"
grep -q "flags 解码充电状态" "$COMPAT_REPORT"
for script in scripts/*.sh; do
  sh -n "$script"
done
echo "Shell script syntax OK"

plutil -lint \
  Resources/App/Info.plist \
  Resources/Widget/Info.plist \
  dist/BatteryMonitor.app/Contents/Info.plist \
  Config/BatteryMonitor.entitlements \
  Config/BatteryMonitorWidget.entitlements

python3 - <<'PY'
import plistlib

with open("Resources/App/Info.plist", "rb") as file:
    app_info = plistlib.load(file)
with open("Resources/Widget/Info.plist", "rb") as file:
    widget_info = plistlib.load(file)
with open("dist/BatteryMonitor.app/Contents/Info.plist", "rb") as file:
    dist_app_info = plistlib.load(file)

if (
    app_info.get("CFBundlePackageType") != "APPL"
    or app_info.get("LSUIElement") is not True
    or not app_info.get("NSBluetoothAlwaysUsageDescription")
):
    raise SystemExit("App Info.plist must describe a menu bar LSUIElement application with Bluetooth usage text")

if (
    dist_app_info.get("CFBundlePackageType") != "APPL"
    or dist_app_info.get("LSUIElement") is not True
    or not dist_app_info.get("NSBluetoothAlwaysUsageDescription")
):
    raise SystemExit("dist App Info.plist must preserve menu bar LSUIElement and Bluetooth usage text")

extension = widget_info.get("NSExtension", {})
if (
    widget_info.get("CFBundlePackageType") != "XPC!"
    or extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension"
):
    raise SystemExit("Widget Info.plist must describe a WidgetKit extension")

print("Source Info.plist content OK")
PY

python3 - <<'PY'
import plistlib

expected_group = "N4828PE57J.com.lacdon.batterymonitor"
entitlement_paths = [
    "Config/BatteryMonitor.entitlements",
    "Config/BatteryMonitorWidget.entitlements",
]

for path in entitlement_paths:
    with open(path, "rb") as file:
        entitlements = plistlib.load(file)
    groups = entitlements.get("com.apple.security.application-groups")
    if groups != [expected_group]:
        raise SystemExit(f"Unexpected App Group entitlement in {path}: {groups!r}")

print("App Group entitlements OK")
PY


python3 - <<'PY'
from pathlib import Path

source = Path("Sources/BatteryMonitorApp/BatteryMonitorApp.swift").read_text()
# UI strings live in the shared localization table since the zh/en refactor.
source += Path("Sources/BatteryMonitorShared/Localization.swift").read_text()
settings_source = Path("Sources/BatteryMonitorShared/MonitorSettings.swift").read_text()
login_source = Path("Sources/BatteryMonitorCore/LoginItemService.swift").read_text()
ignored_list_source = Path("Sources/BatteryMonitorCore/IgnoredDeviceListModel.swift").read_text()
notification_source = Path("Sources/BatteryMonitorCore/NotificationService.swift").read_text()
bluetooth_source = Path("Sources/BatteryMonitorCore/BluetoothPermissionService.swift").read_text()
required_snippets = [
    ("menu bar refresh action", 'Image(systemName: "arrow.clockwise")'),
    ("settings window presenter", "SettingsWindowPresenter"),
    ("settings keyable window", "SettingsPanel: NSWindow"),
    ("settings key window support", "canBecomeKey"),
    ("settings main window support", "canBecomeMain"),
    ("settings process activation", "activate(ignoringOtherApps: true)"),
    ("settings entry", "openSettingsWindow"),
    ("settings QA open marker", "BATTERY_MONITOR_QA_OPEN_SETTINGS"),
    ("manual refresh QA marker", "BATTERY_MONITOR_QA_TRIGGER_REFRESH"),
    ("notification status QA marker", "BATTERY_MONITOR_QA_NOTIFICATION_STATUS"),
    ("notification status QA marker file", "qa-notification-status.txt"),
    ("menu state QA marker", "BATTERY_MONITOR_QA_WRITE_MENU_STATE"),
    ("menu state QA marker file", "qa-menu-state.json"),
    ("low battery threshold setting", "低电量阈值"),
    ("recovery margin setting", "恢复缓冲"),
    ("polling interval setting", "轮询间隔"),
    ("reminder cooldown setting", "重复提醒"),
    ("ignored devices setting", "忽略提醒"),
    ("unavailable ignored devices setting", "当前不可见的已忽略设备"),
    ("remove ignored device action", "移除"),
    ("login item setting", "登录时启动"),
    ("notification permission setting", "通知权限"),
    ("Bluetooth permission setting", "蓝牙权限"),
    ("permission settings URL open", "settingsURL"),
    ("required App Group QA mode", "BATTERY_MONITOR_REQUIRE_APP_GROUP"),
    ("strict App Group store", "SharedBatteryStore.appGroup()"),
]

missing = [description for description, snippet in required_snippets if snippet not in source]
if "launchAtLogin" not in settings_source:
    missing.append("persisted login item preference")
if "SettingsBackedLoginItemService" not in login_source:
    missing.append("settings-backed login item service")
if "IgnoredDeviceListModel" not in ignored_list_source:
    missing.append("unavailable ignored device list model")
if "SystemSettingsDestination.notifications" not in notification_source:
    missing.append("notification settings destination")
if "SystemSettingsDestination.bluetooth" not in bluetooth_source:
    missing.append("Bluetooth settings destination")
if "SettingsLink" in source:
    missing.append("settings entry must use the AppKit presenter instead of SettingsLink")
if missing:
    raise SystemExit(f"Missing menu bar/settings source coverage: {', '.join(missing)}")

print("Menu bar and settings source coverage OK")
PY

python3 - <<'PY'
from pathlib import Path

source = Path("Sources/BatteryMonitorCore/NotificationService.swift").read_text()
# Action titles live in the shared localization table since the zh/en refactor.
source += Path("Sources/BatteryMonitorShared/Localization.swift").read_text()
required_snippets = [
    ("low battery notification category", "categoryIdentifier"),
    ("snooze notification action", "稍后提醒"),
    ("ignore notification action", "忽略此设备"),
    ("notification payload userInfo", "deviceIDsUserInfoKey"),
    ("ignore-device action handler", "LowBatteryNotificationActionHandler"),
]

missing = [description for description, snippet in required_snippets if snippet not in source]
if missing:
    raise SystemExit(f"Missing notification action source coverage: {', '.join(missing)}")

print("Notification action source coverage OK")
PY

python3 - <<'PY'
from pathlib import Path

source = Path("Sources/BatteryMonitorWidget/BatteryMonitorWidget.swift").read_text()
display_model_source = Path("Sources/BatteryMonitorShared/WidgetBatteryDisplayModel.swift").read_text()
l10n_source = Path("Sources/BatteryMonitorShared/Localization.swift").read_text()
required_snippets = [
    ("App Group snapshot read", "WidgetSnapshotReader.readDetailed(from: store)"),
    ("small widget view", "SmallBatteryWidgetView"),
    ("medium widget view", "MediumBatteryWidgetView"),
    ("large widget view", "LargeBatteryWidgetView"),
    ("Small/Medium/Large families", ".supportedFamilies([.systemSmall, .systemMedium, .systemLarge])"),
    ("last updated freshness display", "freshnessText"),
    ("empty data state", "WidgetEmptyState"),
    ("low-battery highlight", "BatteryLevelStyle.accent"),
    ("widget background", "WidgetGlassBackground"),
]

missing = [description for description, snippet in required_snippets if snippet not in source]
if "缓存 " not in l10n_source or ".formatted(date: .omitted, time: .shortened)" not in display_model_source:
    missing.append("cached snapshot freshness text")
if missing:
    raise SystemExit(f"Missing widget source coverage: {', '.join(missing)}")
if ".accessory" in source:
    raise SystemExit("Widget target must stay scoped to system Small, Medium, and Large families")

print("Widget source coverage OK")
PY

ruby <<'RUBY'
require "yaml"

project = YAML.load_file("project.yml")
dependencies = project.fetch("targets").fetch("BatteryMonitorWidget").fetch("dependencies")
target_dependencies = dependencies.map { |dependency| dependency["target"] }.compact
sdk_dependencies = dependencies.map { |dependency| dependency["sdk"] }.compact

unless target_dependencies == ["BatteryMonitorShared"]
  warn "Unexpected XcodeGen Widget target dependencies: #{target_dependencies.inspect}"
  exit 1
end

allowed_sdks = ["SwiftUI.framework", "WidgetKit.framework"]
unexpected_sdks = sdk_dependencies - allowed_sdks
missing_sdks = allowed_sdks - sdk_dependencies
unless unexpected_sdks.empty? && missing_sdks.empty?
  warn "Unexpected XcodeGen Widget SDK dependencies: #{sdk_dependencies.inspect}"
  exit 1
end

puts "XcodeGen Widget dependency boundary OK"
RUBY

python3 - <<'PY'
import json
import os
import subprocess

root = os.getcwd()
icon_dir = os.path.join(root, "Resources", "App", "Assets.xcassets", "AppIcon.appiconset")
contents_path = os.path.join(icon_dir, "Contents.json")
with open(os.path.join(root, "Resources", "App", "Assets.xcassets", "Contents.json")) as file:
    json.load(file)
with open(contents_path) as file:
    contents = json.load(file)

for image in contents["images"]:
    filename = image.get("filename")
    if not filename:
        raise SystemExit("AppIcon image entry is missing filename")
    path = os.path.join(icon_dir, filename)
    if not os.path.exists(path):
        raise SystemExit(f"Missing app icon file: {filename}")
    expected = int(float(image["size"].split("x")[0]) * int(image["scale"].replace("x", "")))
    output = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path], text=True)
    if f"pixelWidth: {expected}" not in output or f"pixelHeight: {expected}" not in output:
        raise SystemExit(f"Unexpected icon dimensions for {filename}: expected {expected}x{expected}")

print("Asset catalog JSON and app icon dimensions OK")
PY

  if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec project.yml
  python3 - <<'PY'
import plistlib

expected_group = "N4828PE57J.com.lacdon.batterymonitor"
entitlement_paths = [
    "Config/BatteryMonitor.entitlements",
    "Config/BatteryMonitorWidget.entitlements",
]

for path in entitlement_paths:
    with open(path, "rb") as file:
        entitlements = plistlib.load(file)
    groups = entitlements.get("com.apple.security.application-groups")
    if groups != [expected_group]:
        raise SystemExit(f"Unexpected App Group entitlement after XcodeGen in {path}: {groups!r}")

print("XcodeGen App Group entitlements OK")
PY
  plutil -lint BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "BatteryMonitorWidget.appex in Embed Foundation Extensions" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "BatteryMonitorShared.framework in Embed Frameworks" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "BatteryMonitorCore.framework in Embed Frameworks" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "CoreBluetooth.framework" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "IOBluetooth.framework" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "Assets.xcassets in Resources" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "PRODUCT_BUNDLE_IDENTIFIER = com.lacdon.batterymonitor;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "PRODUCT_BUNDLE_IDENTIFIER = com.lacdon.batterymonitor.widget;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "PRODUCT_BUNDLE_IDENTIFIER = com.lacdon.batterymonitor.shared;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "CODE_SIGN_ENTITLEMENTS = Config/BatteryMonitor.entitlements;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "CODE_SIGN_ENTITLEMENTS = Config/BatteryMonitorWidget.entitlements;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING = NO;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "ENABLE_APPINTENTS_DEPLOYMENT_AWARE_PROCESSING = NO;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "ENABLE_ASSISTANT_INTENTS_PROVIDER_VALIDATION = NO;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "LM_COMPILE_TIME_EXTRACTION = NO;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "LM_ENABLE_LINK_GENERATION = NO;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "LM_NO_APP_SHORTCUT_LOCALIZATION = YES;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "SWIFT_ENABLE_EMIT_CONST_VALUES = NO;" BatteryMonitor.xcodeproj/project.pbxproj
  grep -q "CODE_SIGNING_ALLOWED = NO;" BatteryMonitor.xcodeproj/project.pbxproj
  echo "Xcode project generated"

  if xcodebuild -version >/dev/null 2>&1; then
    XCODE_DERIVED_DATA="DerivedData/Local"
    DEBUG_APP="$XCODE_DERIVED_DATA/Build/Products/Debug/BatteryMonitor.app"
    RELEASE_APP="$XCODE_DERIVED_DATA/Build/Products/Release/BatteryMonitor.app"
    DEBUG_SETTINGS_JSON="${TMPDIR:-/tmp}/battery-monitor-xcode-debug-settings.json"
    RELEASE_SETTINGS_JSON="${TMPDIR:-/tmp}/battery-monitor-xcode-release-settings.json"
    xcodebuild \
      -project BatteryMonitor.xcodeproj \
      -scheme BatteryMonitor \
      -configuration Debug \
      -showBuildSettings \
      -json > "$DEBUG_SETTINGS_JSON"
    xcodebuild \
      -project BatteryMonitor.xcodeproj \
      -scheme BatteryMonitor \
      -configuration Release \
      -showBuildSettings \
      -json > "$RELEASE_SETTINGS_JSON"
    python3 - "$DEBUG_SETTINGS_JSON" "$RELEASE_SETTINGS_JSON" <<'PY'
import json
import sys

expected_targets = {
    "BatteryMonitor": ("com.lacdon.batterymonitor", "Config/BatteryMonitor.entitlements"),
    "BatteryMonitorWidget": ("com.lacdon.batterymonitor.widget", "Config/BatteryMonitorWidget.entitlements"),
    "BatteryMonitorCLI": ("com.lacdon.batterymonitor.cli", None),
    "BatteryMonitorCore": ("com.lacdon.batterymonitor.core", None),
    "BatteryMonitorShared": ("com.lacdon.batterymonitor.shared", None),
    "BatteryMonitorTestHarness": ("com.lacdon.batterymonitor.tests", None),
}

for configuration, path in [("Debug", sys.argv[1]), ("Release", sys.argv[2])]:
    with open(path) as file:
        settings = json.load(file)

    targets = {entry["target"]: entry["buildSettings"] for entry in settings}
    missing_targets = sorted(set(expected_targets) - set(targets))
    if missing_targets:
        raise SystemExit(f"Missing {configuration} build settings for targets: {missing_targets}")

    for target, (bundle_identifier, entitlements) in expected_targets.items():
        build_settings = targets[target]
        if build_settings.get("CODE_SIGNING_ALLOWED") != "NO":
            raise SystemExit(f"{configuration} {target} must default to CODE_SIGNING_ALLOWED=NO")
        if build_settings.get("CODE_SIGNING_REQUIRED") != "NO":
            raise SystemExit(f"{configuration} {target} must default to CODE_SIGNING_REQUIRED=NO")
        if build_settings.get("DEVELOPMENT_TEAM", "") != "":
            raise SystemExit(f"{configuration} {target} must not require a DEVELOPMENT_TEAM by default")
        if build_settings.get("PRODUCT_BUNDLE_IDENTIFIER") != bundle_identifier:
            raise SystemExit(f"{configuration} {target} has unexpected bundle identifier")
        actual_entitlements = build_settings.get("CODE_SIGN_ENTITLEMENTS")
        if actual_entitlements != entitlements:
            raise SystemExit(
                f"{configuration} {target} has unexpected entitlements: {actual_entitlements!r}"
            )

print("Xcode Debug/Release unsigned signing settings OK")
PY
    xcodebuild \
      -project BatteryMonitor.xcodeproj \
      -scheme BatteryMonitor \
      -configuration Debug \
      -derivedDataPath "$XCODE_DERIVED_DATA" \
      build >/tmp/battery-monitor-xcode-debug.log
    xcodebuild \
      -project BatteryMonitor.xcodeproj \
      -scheme BatteryMonitor \
      -configuration Release \
      -derivedDataPath "$XCODE_DERIVED_DATA" \
      build >/tmp/battery-monitor-xcode-release.log

    XCODE_DIAGNOSTIC_LOG="${TMPDIR:-/tmp}/battery-monitor-xcode-diagnostic.log"
    BATTERY_MONITOR_XCODE_DERIVED_DATA="$XCODE_DERIVED_DATA" \
      ./scripts/diagnose_xcode_build.sh > "$XCODE_DIAGNOSTIC_LOG"
    grep -q "Xcode build diagnostic OK" "$XCODE_DIAGNOSTIC_LOG"
    grep -q "CODE_SIGNING_ALLOWED: NO" "$XCODE_DIAGNOSTIC_LOG"
    grep -q "App:" "$XCODE_DIAGNOSTIC_LOG"

    XCODE_CLI_JSON="${TMPDIR:-/tmp}/battery-monitor-xcode-cli.json"
    XCODE_SETTINGS_REPORT_JSON="${TMPDIR:-/tmp}/battery-monitor-xcode-settings-report-settings.json"
    XCODE_SETTINGS_REPORT_LOG="${TMPDIR:-/tmp}/battery-monitor-xcode-settings-report.log"
    "$XCODE_DERIVED_DATA/Build/Products/Debug/BatteryMonitorTestHarness"
    "$XCODE_DERIVED_DATA/Build/Products/Debug/BatteryMonitorCLI" --json > "$XCODE_CLI_JSON"
    python3 -m json.tool "$XCODE_CLI_JSON" >/dev/null
    python3 - "$XCODE_CLI_JSON" "$XCODE_SETTINGS_REPORT_JSON" <<'PY'
import json
import sys

with open(sys.argv[1]) as file:
    snapshot = json.load(file)

devices = snapshot.get("devices", [])
ignored_device = devices[0] if devices else None
ignored_ids = [ignored_device["id"]] if ignored_device else []
ignored_fingerprints = []
if ignored_device:
    ignored_fingerprints.append(
        f'{ignored_device.get("name", "").lower()}|{ignored_device.get("kind", "")}|{ignored_device.get("source", "").lower()}'
    )

settings = {
    "lowBatteryThreshold": 100,
    "recoveryMargin": 5,
    "pollingInterval": 180,
    "reminderCooldown": 7200,
    "launchAtLogin": True,
    "ignoredDeviceIDs": ignored_ids,
    "ignoredDeviceFingerprints": ignored_fingerprints,
}

with open(sys.argv[2], "w") as file:
    json.dump(settings, file, ensure_ascii=False, sort_keys=True)
PY
    "$XCODE_DERIVED_DATA/Build/Products/Debug/BatteryMonitorCLI" \
      --settings-report "$XCODE_SETTINGS_REPORT_JSON" \
      --settings-report-snapshot "$XCODE_CLI_JSON" > "$XCODE_SETTINGS_REPORT_LOG"
    grep -q "Settings report" "$XCODE_SETTINGS_REPORT_LOG"
    grep -q "Launch at login preference: true" "$XCODE_SETTINGS_REPORT_LOG"
    grep -q "Device settings impact:" "$XCODE_SETTINGS_REPORT_LOG"

    test -d "$DEBUG_APP/Contents/PlugIns/BatteryMonitorWidget.appex"
    test -d "$DEBUG_APP/Contents/Frameworks/BatteryMonitorShared.framework"
    test -d "$DEBUG_APP/Contents/Frameworks/BatteryMonitorCore.framework"
    test -d "$RELEASE_APP/Contents/PlugIns/BatteryMonitorWidget.appex"
    test -d "$RELEASE_APP/Contents/Frameworks/BatteryMonitorShared.framework"
    test -d "$RELEASE_APP/Contents/Frameworks/BatteryMonitorCore.framework"
    plutil -lint \
      "$DEBUG_APP/Contents/Info.plist" \
      "$DEBUG_APP/Contents/PlugIns/BatteryMonitorWidget.appex/Contents/Info.plist" \
      "$RELEASE_APP/Contents/Info.plist" \
      "$RELEASE_APP/Contents/PlugIns/BatteryMonitorWidget.appex/Contents/Info.plist"

    python3 - "$DEBUG_APP" "$RELEASE_APP" <<'PY'
import os
import plistlib
import sys

for app_path in sys.argv[1:]:
    app_info_path = os.path.join(app_path, "Contents", "Info.plist")
    widget_info_path = os.path.join(
        app_path,
        "Contents",
        "PlugIns",
        "BatteryMonitorWidget.appex",
        "Contents",
        "Info.plist",
    )

    with open(app_info_path, "rb") as file:
        app_info = plistlib.load(file)
    with open(widget_info_path, "rb") as file:
        widget_info = plistlib.load(file)

    app_executable = os.path.join(
        app_path,
        "Contents",
        "MacOS",
        app_info.get("CFBundleExecutable", ""),
    )
    widget_executable = os.path.join(
        app_path,
        "Contents",
        "PlugIns",
        "BatteryMonitorWidget.appex",
        "Contents",
        "MacOS",
        widget_info.get("CFBundleExecutable", ""),
    )
    app_icon = os.path.join(app_path, "Contents", "Resources", "AppIcon.icns")
    compiled_assets = os.path.join(app_path, "Contents", "Resources", "Assets.car")

    if app_info.get("CFBundleIdentifier") != "com.lacdon.batterymonitor":
        raise SystemExit(f"Unexpected app bundle identifier in {app_info_path}")
    if app_info.get("LSUIElement") is not True:
        raise SystemExit(f"Missing LSUIElement in {app_info_path}")
    if not app_info.get("NSBluetoothAlwaysUsageDescription"):
        raise SystemExit(f"Missing NSBluetoothAlwaysUsageDescription in {app_info_path}")
    if app_info.get("CFBundleIconFile") != "AppIcon" or app_info.get("CFBundleIconName") != "AppIcon":
        raise SystemExit(f"Missing AppIcon bundle metadata in {app_info_path}")
    if not os.path.isfile(app_executable) or not os.access(app_executable, os.X_OK):
        raise SystemExit(f"Missing executable app binary: {app_executable}")
    if not os.path.isfile(app_icon) or os.path.getsize(app_icon) == 0:
        raise SystemExit(f"Missing built app icon: {app_icon}")
    if not os.path.isfile(compiled_assets) or os.path.getsize(compiled_assets) == 0:
        raise SystemExit(f"Missing compiled asset catalog: {compiled_assets}")

    extension = widget_info.get("NSExtension", {})
    if widget_info.get("CFBundleIdentifier") != "com.lacdon.batterymonitor.widget":
        raise SystemExit(f"Unexpected widget bundle identifier in {widget_info_path}")
    if extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        raise SystemExit(f"Missing WidgetKit extension point in {widget_info_path}")
    if not os.path.isfile(widget_executable) or not os.access(widget_executable, os.X_OK):
        raise SystemExit(f"Missing executable widget binary: {widget_executable}")

print("Xcode-built Info.plist, executable, and resource bundle content OK")
PY

    ./scripts/system_qa_preflight.sh "$RELEASE_APP"
    ADHOC_PREFLIGHT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/battery-monitor-adhoc-preflight.XXXXXX")"
    cp -R "$RELEASE_APP" "$ADHOC_PREFLIGHT_DIR/"
    ADHOC_APP="$ADHOC_PREFLIGHT_DIR/BatteryMonitor.app"
    for framework in "$ADHOC_APP"/Contents/Frameworks/*.framework; do
      [ -d "$framework" ] || continue
      codesign --force --sign - "$framework" >/dev/null
    done
    codesign --force --sign - \
      --entitlements Config/BatteryMonitorWidget.entitlements \
      "$ADHOC_APP/Contents/PlugIns/BatteryMonitorWidget.appex" >/dev/null
    codesign --force --sign - \
      --entitlements Config/BatteryMonitor.entitlements \
      "$ADHOC_APP" >/dev/null
    ADHOC_DEFAULT_LOG="${TMPDIR:-/tmp}/battery-monitor-adhoc-preflight-default.log"
    ./scripts/system_qa_preflight.sh "$ADHOC_APP" > "$ADHOC_DEFAULT_LOG" 2>&1
    grep -q "not developer-signed" "$ADHOC_DEFAULT_LOG"
    ADHOC_REQUIRED_LOG="${TMPDIR:-/tmp}/battery-monitor-adhoc-preflight-required.log"
    if BATTERY_MONITOR_REQUIRE_SIGNED_APP=1 ./scripts/system_qa_preflight.sh "$ADHOC_APP" > "$ADHOC_REQUIRED_LOG" 2>&1; then
      cat "$ADHOC_REQUIRED_LOG" >&2
      echo "Ad-hoc signed app unexpectedly passed developer-signed preflight" >&2
      exit 1
    fi
    grep -q "must be developer-signed" "$ADHOC_REQUIRED_LOG"
    rm -rf "$ADHOC_PREFLIGHT_DIR"
    SIGNED_DRY_RUN_LOG="${TMPDIR:-/tmp}/battery-monitor-signed-release-dry-run.log"
    BATTERY_MONITOR_SIGNED_BUILD_DRY_RUN=1 \
      BATTERY_MONITOR_DEVELOPMENT_TEAM=ABCDE12345 \
      ./scripts/build_signed_release.sh > "$SIGNED_DRY_RUN_LOG"
    grep -q "CODE_SIGNING_ALLOWED=YES" "$SIGNED_DRY_RUN_LOG"
    grep -q "BATTERY_MONITOR_REQUIRE_SIGNED_APP=1" "$SIGNED_DRY_RUN_LOG"
    grep -q "Signed Release build dry run OK" "$SIGNED_DRY_RUN_LOG"
    QA_SESSION_DRY_RUN_LOG="${TMPDIR:-/tmp}/battery-monitor-system-qa-session-dry-run.log"
    BATTERY_MONITOR_QA_DRY_RUN=1 \
      BATTERY_MONITOR_QA_OPEN_SETTINGS=1 \
      BATTERY_MONITOR_QA_TRIGGER_REFRESH=1 \
      BATTERY_MONITOR_QA_NOTIFICATION_STATUS=denied \
      ./scripts/run_system_qa_session.sh "$RELEASE_APP" > "$QA_SESSION_DRY_RUN_LOG"
    grep -q "System QA session dry run OK" "$QA_SESSION_DRY_RUN_LOG"
    grep -q "Seeded lowBatteryThreshold: 100" "$QA_SESSION_DRY_RUN_LOG"
    grep -q "Open settings window: 1" "$QA_SESSION_DRY_RUN_LOG"
    grep -q "Trigger manual refresh: 1" "$QA_SESSION_DRY_RUN_LOG"
    grep -q "Notification status override: denied" "$QA_SESSION_DRY_RUN_LOG"
    grep -q "Write menu state marker: 1" "$QA_SESSION_DRY_RUN_LOG"
    QA_SESSION_SETTINGS_LOG="${TMPDIR:-/tmp}/battery-monitor-system-qa-session-settings.log"
    BATTERY_MONITOR_QA_DURATION=3 \
      BATTERY_MONITOR_QA_DISABLE_NOTIFICATIONS=1 \
      BATTERY_MONITOR_QA_OPEN_SETTINGS=1 \
      BATTERY_MONITOR_QA_TRIGGER_REFRESH=1 \
      BATTERY_MONITOR_QA_NOTIFICATION_STATUS=denied \
      ./scripts/run_system_qa_session.sh "$RELEASE_APP" > "$QA_SESSION_SETTINGS_LOG"
    grep -q "QA session settings window marker:" "$QA_SESSION_SETTINGS_LOG"
    grep -q "QA session manual refresh marker:" "$QA_SESSION_SETTINGS_LOG"
    grep -q "QA session notification status marker:" "$QA_SESSION_SETTINGS_LOG"
    grep -q "QA session menu state marker:" "$QA_SESSION_SETTINGS_LOG"
    grep -q "QA session menu state rows:" "$QA_SESSION_SETTINGS_LOG"
    grep -q "System QA session complete" "$QA_SESSION_SETTINGS_LOG"
    QA_SESSION_APP_GROUP_DRY_RUN_LOG="${TMPDIR:-/tmp}/battery-monitor-system-qa-session-app-group-dry-run.log"
    BATTERY_MONITOR_QA_DRY_RUN=1 \
      BATTERY_MONITOR_QA_USE_APP_GROUP=1 \
      ./scripts/run_system_qa_session.sh "$RELEASE_APP" > "$QA_SESSION_APP_GROUP_DRY_RUN_LOG"
    grep -q "Use App Group: 1" "$QA_SESSION_APP_GROUP_DRY_RUN_LOG"
    grep -q "Require App Group: 1" "$QA_SESSION_APP_GROUP_DRY_RUN_LOG"
    grep -q "Validate App Group: 1" "$QA_SESSION_APP_GROUP_DRY_RUN_LOG"
    grep -q "System QA session dry run OK" "$QA_SESSION_APP_GROUP_DRY_RUN_LOG"
    QA_SESSION_APP_GROUP_LOG="${TMPDIR:-/tmp}/battery-monitor-system-qa-session-app-group.log"
    BATTERY_MONITOR_QA_DURATION=3 \
      BATTERY_MONITOR_QA_USE_APP_GROUP=1 \
      BATTERY_MONITOR_QA_DISABLE_NOTIFICATIONS=1 \
      ./scripts/run_system_qa_session.sh "$RELEASE_APP" > "$QA_SESSION_APP_GROUP_LOG"
    grep -q "Require App Group: 1" "$QA_SESSION_APP_GROUP_LOG"
    grep -q "Validate App Group: 1" "$QA_SESSION_APP_GROUP_LOG"
    grep -q "QA session App Group snapshot devices:" "$QA_SESSION_APP_GROUP_LOG"
    grep -q "QA session menu state marker:" "$QA_SESSION_APP_GROUP_LOG"
    grep -q "QA session menu state rows:" "$QA_SESSION_APP_GROUP_LOG"
    grep -q "System QA session complete" "$QA_SESSION_APP_GROUP_LOG"

    "$DEBUG_APP/Contents/MacOS/BatteryMonitor" >/tmp/battery-monitor-xcode-app.log 2>&1 &
    XCODE_APP_PID=$!
    sleep 3
    if kill -0 "$XCODE_APP_PID" >/dev/null 2>&1; then
      kill "$XCODE_APP_PID"
      wait "$XCODE_APP_PID" 2>/dev/null || true
      echo "Xcode-built app executable smoke test OK"
    else
      wait "$XCODE_APP_PID"
      cat /tmp/battery-monitor-xcode-app.log >&2
      exit 1
    fi

    "$RELEASE_APP/Contents/MacOS/BatteryMonitor" >/tmp/battery-monitor-xcode-release-app.log 2>&1 &
    XCODE_RELEASE_APP_PID=$!
    sleep 3
    if kill -0 "$XCODE_RELEASE_APP_PID" >/dev/null 2>&1; then
      kill "$XCODE_RELEASE_APP_PID"
      wait "$XCODE_RELEASE_APP_PID" 2>/dev/null || true
      echo "Xcode-built Release app executable smoke test OK"
    else
      wait "$XCODE_RELEASE_APP_PID"
      cat /tmp/battery-monitor-xcode-release-app.log >&2
      exit 1
    fi

    ./scripts/runtime_smoke.sh "$DEBUG_APP/Contents/MacOS/BatteryMonitor" "$XCODE_CLI_JSON"
  else
    echo "xcodebuild unavailable; skipped Xcode build verification"
  fi
else
  echo "xcodegen not installed; skipped Xcode project generation"
fi
