#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="${BATTERY_MONITOR_XCODE_PROJECT:-BatteryMonitor.xcodeproj}"
SCHEME="${BATTERY_MONITOR_XCODE_SCHEME:-BatteryMonitor}"
CONFIGURATION="${BATTERY_MONITOR_XCODE_CONFIGURATION:-Debug}"
DERIVED_DATA="${BATTERY_MONITOR_XCODE_DERIVED_DATA:-}"
REGENERATE="${BATTERY_MONITOR_XCODE_REGENERATE:-0}"
CLEAN="${BATTERY_MONITOR_XCODE_CLEAN:-0}"
KEEP_LOG="${BATTERY_MONITOR_XCODE_KEEP_LOG:-0}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Full Xcode is required for Xcode build diagnostics" >&2
  exit 1
fi

if [ "$REGENERATE" = "1" ]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "BATTERY_MONITOR_XCODE_REGENERATE=1 requires xcodegen" >&2
    exit 1
  fi
  xcodegen generate --spec project.yml
fi

if [ ! -d "$PROJECT" ]; then
  echo "Missing Xcode project: $PROJECT" >&2
  echo "Run ./scripts/bootstrap_xcode_project.sh first." >&2
  exit 1
fi

BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/battery-monitor-xcode-build.XXXXXX.log")"
SETTINGS_JSON="$(mktemp "${TMPDIR:-/tmp}/battery-monitor-xcode-settings.XXXXXX.json")"
PATHS_JSON="$(mktemp "${TMPDIR:-/tmp}/battery-monitor-xcode-paths.XXXXXX.json")"

cleanup() {
  if [ "$KEEP_LOG" != "1" ]; then
    rm -f "$BUILD_LOG" "$SETTINGS_JSON" "$PATHS_JSON"
  else
    echo "Kept diagnostic files:"
    echo "  build log: $BUILD_LOG"
    echo "  settings:  $SETTINGS_JSON"
    echo "  paths:     $PATHS_JSON"
  fi
}
trap cleanup EXIT

show_log_errors() {
  log_path="$1"
  pattern='(error:|BUILD FAILED|failed with exit code|Command .* failed|No signing certificate|requires a development team|Provisioning|CodeSign|codesign|Multiple commands produce|Undefined symbols|No such file|cannot find|Cycle inside)'
  if command -v rg >/dev/null 2>&1; then
    if ! rg -n "$pattern" -C 4 "$log_path"; then
      tail -n 120 "$log_path"
    fi
  else
    if ! grep -nE "$pattern" "$log_path"; then
      tail -n 120 "$log_path"
    fi
  fi
}

show_activity_errors() {
  derived_root="$1"
  log_dir="$derived_root/Logs/Build"
  [ -d "$log_dir" ] || return 0

  latest_log="$(find "$log_dir" -name '*.xcactivitylog' -type f -print 2>/dev/null | xargs ls -t 2>/dev/null | head -n 1 || true)"
  [ -n "$latest_log" ] || return 0

  echo
  echo "Recent Xcode activity log: $latest_log"
  if command -v gzip >/dev/null 2>&1 && command -v strings >/dev/null 2>&1; then
    gzip -dc "$latest_log" 2>/dev/null \
      | strings \
      | if command -v rg >/dev/null 2>&1; then
          rg -n '(error:|BUILD FAILED|failed with exit code|Command .* failed|No signing certificate|requires a development team|Provisioning|CodeSign|codesign|Multiple commands produce|Undefined symbols|No such file|cannot find|Cycle inside)' -C 4 || true
        else
          grep -nE '(error:|BUILD FAILED|failed with exit code|Command .* failed|No signing certificate|requires a development team|Provisioning|CodeSign|codesign|Multiple commands produce|Undefined symbols|No such file|cannot find|Cycle inside)' || true
        fi
  fi
}

run_xcodebuild_list() {
  xcodebuild -list -project "$PROJECT"
}

run_xcodebuild_show_settings() {
  if [ -n "$DERIVED_DATA" ]; then
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      -showBuildSettings \
      -json
  else
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -showBuildSettings \
      -json
  fi
}

run_xcodebuild_clean() {
  if [ -n "$DERIVED_DATA" ]; then
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      clean
  else
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      clean
  fi
}

run_xcodebuild_build() {
  if [ -n "$DERIVED_DATA" ]; then
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      build
  else
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      build
  fi
}

echo "Xcode build diagnostic"
echo "Project: $PROJECT"
echo "Scheme: $SCHEME"
echo "Configuration: $CONFIGURATION"
if [ -n "$DERIVED_DATA" ]; then
  echo "DerivedData: $DERIVED_DATA"
else
  echo "DerivedData: Xcode default"
fi
echo

run_xcodebuild_list

run_xcodebuild_show_settings > "$SETTINGS_JSON"

python3 - "$SETTINGS_JSON" "$PATHS_JSON" <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
paths_path = Path(sys.argv[2])

settings = json.loads(settings_path.read_text())
targets = {entry["target"]: entry["buildSettings"] for entry in settings}
required = ["BatteryMonitor", "BatteryMonitorWidget"]
missing = [target for target in required if target not in targets]
if missing:
    raise SystemExit(f"Missing build settings for targets: {', '.join(missing)}")

app_settings = targets["BatteryMonitor"]
widget_settings = targets["BatteryMonitorWidget"]
app_path = Path(app_settings["TARGET_BUILD_DIR"]) / app_settings["FULL_PRODUCT_NAME"]
build_dir = Path(app_settings["BUILD_DIR"])
derived_root = build_dir.parent.parent

print()
print("Signing settings:")
for target, build_settings in [
    ("BatteryMonitor", app_settings),
    ("BatteryMonitorWidget", widget_settings),
]:
    print(f"  {target}:")
    print(f"    PRODUCT_BUNDLE_IDENTIFIER: {build_settings.get('PRODUCT_BUNDLE_IDENTIFIER', '')}")
    print(f"    CODE_SIGNING_ALLOWED: {build_settings.get('CODE_SIGNING_ALLOWED', '')}")
    print(f"    CODE_SIGNING_REQUIRED: {build_settings.get('CODE_SIGNING_REQUIRED', '')}")
    print(f"    CODE_SIGN_STYLE: {build_settings.get('CODE_SIGN_STYLE', '')}")
    print(f"    DEVELOPMENT_TEAM: {build_settings.get('DEVELOPMENT_TEAM', '')}")
    print(f"    CODE_SIGN_ENTITLEMENTS: {build_settings.get('CODE_SIGN_ENTITLEMENTS', '')}")

paths_path.write_text(
    json.dumps(
        {
            "appPath": str(app_path),
            "derivedRoot": str(derived_root),
        }
    )
)
PY

if [ "$CLEAN" = "1" ]; then
  echo
  echo "Cleaning scheme before build..."
  run_xcodebuild_clean > "$BUILD_LOG" 2>&1 || {
    echo "xcodebuild clean failed" >&2
    show_log_errors "$BUILD_LOG"
    exit 1
  }
fi

echo
echo "Running xcodebuild build..."
if ! run_xcodebuild_build > "$BUILD_LOG" 2>&1; then
  echo "Xcode build failed" >&2
  show_log_errors "$BUILD_LOG"
  DERIVED_ROOT="$(python3 - "$PATHS_JSON" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["derivedRoot"])
PY
)"
  show_activity_errors "$DERIVED_ROOT"
  exit 1
fi

APP_PATH="$(python3 - "$PATHS_JSON" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["appPath"])
PY
)"

echo "Xcode build succeeded"
echo "App: $APP_PATH"

if [ -d "$APP_PATH" ]; then
  echo
  echo "Code signing metadata:"
  CODESIGN_OUTPUT="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
  echo "$CODESIGN_OUTPUT" | sed -n '/^Executable=/p;/^Identifier=/p;/^TeamIdentifier=/p;/^Signature=/p;/^Authority=/p;/^CodeDirectory /p'

  if echo "$CODESIGN_OUTPUT" | grep -q 'Signature=adhoc'; then
    echo "Note: app is ad-hoc signed. Widget/App Group installation QA needs a developer-signed build."
  elif echo "$CODESIGN_OUTPUT" | grep -q 'TeamIdentifier=not set'; then
    echo "Note: app has no TeamIdentifier. Widget/App Group installation QA needs a developer-signed build."
  fi
else
  echo "Expected app bundle was not found after build: $APP_PATH" >&2
  exit 1
fi

echo
echo "Xcode build diagnostic OK"
