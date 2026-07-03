#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_GROUP_ID="N4828PE57J.com.lacdon.batterymonitor"
APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
  if [ -d "DerivedData/SignedRelease/Build/Products/Release/BatteryMonitor.app" ]; then
    APP_PATH="DerivedData/SignedRelease/Build/Products/Release/BatteryMonitor.app"
  elif [ -d "DerivedData/Local/Build/Products/Release/BatteryMonitor.app" ]; then
    APP_PATH="DerivedData/Local/Build/Products/Release/BatteryMonitor.app"
  elif [ -d "DerivedData/Local/Build/Products/Debug/BatteryMonitor.app" ]; then
    APP_PATH="DerivedData/Local/Build/Products/Debug/BatteryMonitor.app"
  fi
fi

DURATION="${BATTERY_MONITOR_QA_DURATION:-45}"
THRESHOLD="${BATTERY_MONITOR_QA_THRESHOLD:-100}"
USE_APP_GROUP="${BATTERY_MONITOR_QA_USE_APP_GROUP:-0}"
REQUIRE_APP_GROUP="${BATTERY_MONITOR_QA_REQUIRE_APP_GROUP:-$USE_APP_GROUP}"
VALIDATE_APP_GROUP="${BATTERY_MONITOR_QA_VALIDATE_APP_GROUP:-$USE_APP_GROUP}"
REQUIRE_SIGNED="${BATTERY_MONITOR_QA_REQUIRE_SIGNED:-0}"
DISABLE_NOTIFICATIONS="${BATTERY_MONITOR_QA_DISABLE_NOTIFICATIONS:-0}"
REQUIRE_NOTIFICATION_STATE="${BATTERY_MONITOR_QA_REQUIRE_NOTIFICATION_STATE:-1}"
OPEN_SETTINGS="${BATTERY_MONITOR_QA_OPEN_SETTINGS:-0}"
TRIGGER_REFRESH="${BATTERY_MONITOR_QA_TRIGGER_REFRESH:-0}"
NOTIFICATION_STATUS="${BATTERY_MONITOR_QA_NOTIFICATION_STATUS:-}"
WRITE_MENU_STATE="${BATTERY_MONITOR_QA_WRITE_MENU_STATE:-1}"
LEAVE_RUNNING="${BATTERY_MONITOR_QA_LEAVE_RUNNING:-0}"
DRY_RUN="${BATTERY_MONITOR_QA_DRY_RUN:-0}"
STORE_DIR="${BATTERY_MONITOR_QA_STORE_DIR:-}"

fail() {
  echo "System QA session failed: $*" >&2
  exit 1
}

[ -n "$APP_PATH" ] || fail "no BatteryMonitor.app path was provided or found"
[ -d "$APP_PATH" ] || fail "app bundle does not exist: $APP_PATH"

APP_EXECUTABLE="$(python3 - "$APP_PATH" <<'PY'
import os
import plistlib
import sys

app_path = sys.argv[1]
info_path = os.path.join(app_path, "Contents", "Info.plist")
with open(info_path, "rb") as file:
    info = plistlib.load(file)
executable = os.path.join(app_path, "Contents", "MacOS", info.get("CFBundleExecutable", ""))
print(executable)
PY
)"

[ -x "$APP_EXECUTABLE" ] || fail "app executable is missing or not executable: $APP_EXECUTABLE"

if [ "$USE_APP_GROUP" != "1" ] && [ -z "$STORE_DIR" ]; then
  STORE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/battery-monitor-system-qa-session.XXXXXX")"
fi

if [ "$USE_APP_GROUP" != "1" ]; then
  mkdir -p "$STORE_DIR"
  python3 - "$STORE_DIR" "$THRESHOLD" <<'PY'
import json
import os
import sys

store_dir = sys.argv[1]
threshold = int(sys.argv[2])
settings_path = os.path.join(store_dir, "settings.json")
with open(settings_path, "w") as file:
    json.dump(
        {
            "lowBatteryThreshold": threshold,
            "recoveryMargin": 1,
            "pollingInterval": 180,
            "reminderCooldown": 7200,
            "launchAtLogin": False,
            "ignoredDeviceIDs": [],
            "ignoredDeviceFingerprints": [],
        },
        file,
        indent=2,
        sort_keys=True,
    )
PY
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "System QA session dry run"
  echo "App: $APP_PATH"
  echo "Executable: $APP_EXECUTABLE"
  echo "Duration: $DURATION second(s)"
  echo "Use App Group: $USE_APP_GROUP"
  echo "Require App Group: $REQUIRE_APP_GROUP"
  echo "Validate App Group: $VALIDATE_APP_GROUP"
  echo "Require signed app: $REQUIRE_SIGNED"
  echo "Disable notifications: $DISABLE_NOTIFICATIONS"
  echo "Open settings window: $OPEN_SETTINGS"
  echo "Trigger manual refresh: $TRIGGER_REFRESH"
  echo "Notification status override: ${NOTIFICATION_STATUS:-none}"
  echo "Write menu state marker: $WRITE_MENU_STATE"
  if [ "$USE_APP_GROUP" != "1" ]; then
    echo "Store directory: $STORE_DIR"
    echo "Seeded lowBatteryThreshold: $THRESHOLD"
  fi
  echo "System QA session dry run OK"
  exit 0
fi

if [ "$REQUIRE_SIGNED" = "1" ]; then
  BATTERY_MONITOR_REQUIRE_SIGNED_APP=1 ./scripts/system_qa_preflight.sh "$APP_PATH"
else
  ./scripts/system_qa_preflight.sh "$APP_PATH"
fi

LOG_FILE="${STORE_DIR:-${TMPDIR:-/tmp}}/battery-monitor-system-qa-session.log"

echo "Starting Battery Monitor system QA session"
echo "App: $APP_PATH"
echo "Executable: $APP_EXECUTABLE"
echo "Duration: $DURATION second(s)"
if [ "$USE_APP_GROUP" = "1" ]; then
  echo "Store: App Group/default app storage"
  echo "Require App Group: $REQUIRE_APP_GROUP"
  echo "Validate App Group: $VALIDATE_APP_GROUP"
else
  echo "Store: $STORE_DIR"
  echo "Seeded lowBatteryThreshold: $THRESHOLD"
fi
echo "Observe the menu bar app and any notification permission or low-battery notification prompts during this window."

SESSION_START_EPOCH="$(date -u +%s)"

if [ "$USE_APP_GROUP" = "1" ]; then
  if [ "$DISABLE_NOTIFICATIONS" = "1" ]; then
    BATTERY_MONITOR_REQUIRE_APP_GROUP="$REQUIRE_APP_GROUP" \
    BATTERY_MONITOR_DISABLE_NOTIFICATIONS=1 \
    BATTERY_MONITOR_QA_OPEN_SETTINGS="$OPEN_SETTINGS" \
    BATTERY_MONITOR_QA_TRIGGER_REFRESH="$TRIGGER_REFRESH" \
    BATTERY_MONITOR_QA_NOTIFICATION_STATUS="$NOTIFICATION_STATUS" \
    BATTERY_MONITOR_QA_WRITE_MENU_STATE="$WRITE_MENU_STATE" \
      "$APP_EXECUTABLE" >"$LOG_FILE" 2>&1 &
  else
    BATTERY_MONITOR_REQUIRE_APP_GROUP="$REQUIRE_APP_GROUP" \
    BATTERY_MONITOR_QA_OPEN_SETTINGS="$OPEN_SETTINGS" \
    BATTERY_MONITOR_QA_TRIGGER_REFRESH="$TRIGGER_REFRESH" \
    BATTERY_MONITOR_QA_NOTIFICATION_STATUS="$NOTIFICATION_STATUS" \
    BATTERY_MONITOR_QA_WRITE_MENU_STATE="$WRITE_MENU_STATE" \
      "$APP_EXECUTABLE" >"$LOG_FILE" 2>&1 &
  fi
else
  if [ "$DISABLE_NOTIFICATIONS" = "1" ]; then
    BATTERY_MONITOR_STORE_DIR="$STORE_DIR" \
    BATTERY_MONITOR_DISABLE_NOTIFICATIONS=1 \
    BATTERY_MONITOR_QA_OPEN_SETTINGS="$OPEN_SETTINGS" \
    BATTERY_MONITOR_QA_TRIGGER_REFRESH="$TRIGGER_REFRESH" \
    BATTERY_MONITOR_QA_NOTIFICATION_STATUS="$NOTIFICATION_STATUS" \
    BATTERY_MONITOR_QA_WRITE_MENU_STATE="$WRITE_MENU_STATE" \
      "$APP_EXECUTABLE" >"$LOG_FILE" 2>&1 &
  else
    BATTERY_MONITOR_STORE_DIR="$STORE_DIR" \
    BATTERY_MONITOR_QA_OPEN_SETTINGS="$OPEN_SETTINGS" \
    BATTERY_MONITOR_QA_TRIGGER_REFRESH="$TRIGGER_REFRESH" \
    BATTERY_MONITOR_QA_NOTIFICATION_STATUS="$NOTIFICATION_STATUS" \
    BATTERY_MONITOR_QA_WRITE_MENU_STATE="$WRITE_MENU_STATE" \
      "$APP_EXECUTABLE" >"$LOG_FILE" 2>&1 &
  fi
fi
APP_PID=$!

sleep "$DURATION"

if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
  wait "$APP_PID" || true
  cat "$LOG_FILE" >&2
  fail "app exited before the QA session duration elapsed"
fi

if [ "$LEAVE_RUNNING" = "1" ]; then
  echo "App left running with PID $APP_PID"
else
  kill "$APP_PID"
  wait "$APP_PID" 2>/dev/null || true
fi

if [ "$USE_APP_GROUP" != "1" ]; then
  python3 - "$STORE_DIR" "$REQUIRE_NOTIFICATION_STATE" <<'PY'
import json
import os
import sys

store_dir = sys.argv[1]
require_notification_state = sys.argv[2] == "1"
snapshot_path = os.path.join(store_dir, "battery-snapshot.json")
state_path = os.path.join(store_dir, "notification-state.json")

if not os.path.exists(snapshot_path):
    raise SystemExit(f"Missing snapshot after QA session: {snapshot_path}")

with open(snapshot_path) as file:
    snapshot = json.load(file)

devices = snapshot.get("devices", [])
if not devices:
    raise SystemExit("QA session snapshot did not contain any devices")

low_state_count = 0
if os.path.exists(state_path):
    with open(state_path) as file:
        states = json.load(file)
    low_state_count = sum(
        1
        for state in states.values()
        if state.get("wasLowBattery") is True and state.get("lastNotifiedAt")
    )
elif require_notification_state:
    raise SystemExit(f"Missing notification state after QA session: {state_path}")

if require_notification_state and low_state_count == 0:
    raise SystemExit("QA session did not persist any low-battery notification state")

print(f"QA session snapshot devices: {len(devices)}")
print(f"QA session low-battery notification states: {low_state_count}")
print(f"QA session store: {store_dir}")
PY
elif [ "$VALIDATE_APP_GROUP" = "1" ]; then
  python3 - "$APP_GROUP_ID" "$SESSION_START_EPOCH" <<'PY'
import json
import os
import sys
from datetime import datetime

app_group_id = sys.argv[1]
session_start_epoch = int(sys.argv[2])
app_group_dir = os.path.expanduser(os.path.join("~/Library/Group Containers", app_group_id))
snapshot_path = os.path.join(app_group_dir, "battery-snapshot.json")

if not os.path.exists(snapshot_path):
    raise SystemExit(f"Missing App Group snapshot after QA session: {snapshot_path}")

with open(snapshot_path) as file:
    snapshot = json.load(file)

devices = snapshot.get("devices", [])
if not devices:
    raise SystemExit("App Group QA session snapshot did not contain any devices")

updated_at = str(snapshot.get("updatedAt", ""))
try:
    updated_timestamp = datetime.fromisoformat(updated_at.replace("Z", "+00:00")).timestamp()
except ValueError as error:
    raise SystemExit(f"App Group snapshot updatedAt is not ISO8601: {updated_at!r}") from error

if updated_timestamp < session_start_epoch - 2:
    raise SystemExit(
        f"App Group snapshot was not refreshed during QA session: {updated_at}"
    )

print(f"QA session App Group snapshot devices: {len(devices)}")
print(f"QA session App Group snapshot updatedAt: {updated_at}")
print(f"QA session App Group store: {app_group_dir}")
PY
fi

if [ "$OPEN_SETTINGS" = "1" ]; then
  if [ "$USE_APP_GROUP" = "1" ]; then
    python3 - "$APP_GROUP_ID" "$SESSION_START_EPOCH" <<'PY'
import os
import sys

app_group_id = sys.argv[1]
session_start_epoch = int(sys.argv[2])
marker_path = os.path.expanduser(
    os.path.join("~/Library/Group Containers", app_group_id, "qa-settings-window-opened.txt")
)
if not os.path.exists(marker_path):
    raise SystemExit(f"Missing settings window QA marker: {marker_path}")
if os.path.getmtime(marker_path) < session_start_epoch - 2:
    raise SystemExit(f"Settings window QA marker was not refreshed during this session: {marker_path}")
print(f"QA session settings window marker: {marker_path}")
PY
  else
    python3 - "$STORE_DIR" "$SESSION_START_EPOCH" <<'PY'
import os
import sys

store_dir = sys.argv[1]
session_start_epoch = int(sys.argv[2])
marker_path = os.path.join(store_dir, "qa-settings-window-opened.txt")
if not os.path.exists(marker_path):
    raise SystemExit(f"Missing settings window QA marker: {marker_path}")
if os.path.getmtime(marker_path) < session_start_epoch - 2:
    raise SystemExit(f"Settings window QA marker was not refreshed during this session: {marker_path}")
print(f"QA session settings window marker: {marker_path}")
PY
  fi
fi

if [ "$TRIGGER_REFRESH" = "1" ]; then
  if [ "$USE_APP_GROUP" = "1" ]; then
    python3 - "$APP_GROUP_ID" "$SESSION_START_EPOCH" <<'PY'
import os
import sys

app_group_id = sys.argv[1]
session_start_epoch = int(sys.argv[2])
marker_path = os.path.expanduser(
    os.path.join("~/Library/Group Containers", app_group_id, "qa-manual-refresh.txt")
)
if not os.path.exists(marker_path):
    raise SystemExit(f"Missing manual refresh QA marker: {marker_path}")
if os.path.getmtime(marker_path) < session_start_epoch - 2:
    raise SystemExit(f"Manual refresh QA marker was not refreshed during this session: {marker_path}")
print(f"QA session manual refresh marker: {marker_path}")
PY
  else
    python3 - "$STORE_DIR" "$SESSION_START_EPOCH" <<'PY'
import os
import sys

store_dir = sys.argv[1]
session_start_epoch = int(sys.argv[2])
marker_path = os.path.join(store_dir, "qa-manual-refresh.txt")
if not os.path.exists(marker_path):
    raise SystemExit(f"Missing manual refresh QA marker: {marker_path}")
if os.path.getmtime(marker_path) < session_start_epoch - 2:
    raise SystemExit(f"Manual refresh QA marker was not refreshed during this session: {marker_path}")
print(f"QA session manual refresh marker: {marker_path}")
PY
  fi
fi

if [ -n "$NOTIFICATION_STATUS" ]; then
  if [ "$USE_APP_GROUP" = "1" ]; then
    python3 - "$APP_GROUP_ID" "$SESSION_START_EPOCH" "$NOTIFICATION_STATUS" <<'PY'
import os
import sys

app_group_id = sys.argv[1]
session_start_epoch = int(sys.argv[2])
expected_status = sys.argv[3]
marker_path = os.path.expanduser(
    os.path.join("~/Library/Group Containers", app_group_id, "qa-notification-status.txt")
)
if not os.path.exists(marker_path):
    raise SystemExit(f"Missing notification status QA marker: {marker_path}")
if os.path.getmtime(marker_path) < session_start_epoch - 2:
    raise SystemExit(f"Notification status QA marker was not refreshed during this session: {marker_path}")
text = open(marker_path).read()
if f"notificationStatus={expected_status}" not in text:
    raise SystemExit(f"Notification status QA marker does not contain expected status {expected_status!r}: {marker_path}")
if expected_status == "denied" and "alertingDisabled=true" not in text:
    raise SystemExit(f"Notification denied QA marker does not prove alerting is disabled: {marker_path}")
print(f"QA session notification status marker: {marker_path}")
PY
  else
    python3 - "$STORE_DIR" "$SESSION_START_EPOCH" "$NOTIFICATION_STATUS" <<'PY'
import os
import sys

store_dir = sys.argv[1]
session_start_epoch = int(sys.argv[2])
expected_status = sys.argv[3]
marker_path = os.path.join(store_dir, "qa-notification-status.txt")
if not os.path.exists(marker_path):
    raise SystemExit(f"Missing notification status QA marker: {marker_path}")
if os.path.getmtime(marker_path) < session_start_epoch - 2:
    raise SystemExit(f"Notification status QA marker was not refreshed during this session: {marker_path}")
text = open(marker_path).read()
if f"notificationStatus={expected_status}" not in text:
    raise SystemExit(f"Notification status QA marker does not contain expected status {expected_status!r}: {marker_path}")
if expected_status == "denied" and "alertingDisabled=true" not in text:
    raise SystemExit(f"Notification denied QA marker does not prove alerting is disabled: {marker_path}")
print(f"QA session notification status marker: {marker_path}")
PY
  fi
fi

if [ "$WRITE_MENU_STATE" = "1" ]; then
  if [ "$USE_APP_GROUP" = "1" ]; then
    python3 - "$APP_GROUP_ID" "$SESSION_START_EPOCH" "$NOTIFICATION_STATUS" <<'PY'
import json
import os
import sys

app_group_id = sys.argv[1]
session_start_epoch = int(sys.argv[2])
expected_notification_status = sys.argv[3]
marker_path = os.path.expanduser(
    os.path.join("~/Library/Group Containers", app_group_id, "qa-menu-state.json")
)
if not os.path.exists(marker_path):
    raise SystemExit(f"Missing menu state QA marker: {marker_path}")
if os.path.getmtime(marker_path) < session_start_epoch - 2:
    raise SystemExit(f"Menu state QA marker was not refreshed during this session: {marker_path}")
with open(marker_path) as file:
    marker = json.load(file)
rows = marker.get("rows", [])
if not isinstance(rows, list) or not rows:
    raise SystemExit("Menu state QA marker does not contain device rows")
required_top_level = ["lastUpdatedText", "deviceCount"]
missing_top_level = [key for key in required_top_level if key not in marker or marker.get(key) in ("", None)]
if missing_top_level:
    raise SystemExit(f"Menu state QA marker is missing fields: {', '.join(missing_top_level)}")
required_row_fields = ["name", "percentageText", "statusText", "symbolName"]
missing_row_fields = [
    key
    for key in required_row_fields
    if key not in rows[0] or rows[0].get(key) in ("", None)
]
if missing_row_fields:
    raise SystemExit(f"Menu state QA marker first row is missing fields: {', '.join(missing_row_fields)}")
if expected_notification_status == "denied" and marker.get("notificationStatus") != "denied":
    raise SystemExit("Menu state QA marker does not record the denied notification status")
if marker.get("deviceCount") != len(rows):
    raise SystemExit("Menu state QA marker deviceCount does not match row count")
print(f"QA session menu state marker: {marker_path}")
print(f"QA session menu state rows: {len(rows)}")
PY
  else
    python3 - "$STORE_DIR" "$SESSION_START_EPOCH" "$NOTIFICATION_STATUS" <<'PY'
import json
import os
import sys

store_dir = sys.argv[1]
session_start_epoch = int(sys.argv[2])
expected_notification_status = sys.argv[3]
marker_path = os.path.join(store_dir, "qa-menu-state.json")
if not os.path.exists(marker_path):
    raise SystemExit(f"Missing menu state QA marker: {marker_path}")
if os.path.getmtime(marker_path) < session_start_epoch - 2:
    raise SystemExit(f"Menu state QA marker was not refreshed during this session: {marker_path}")
with open(marker_path) as file:
    marker = json.load(file)
rows = marker.get("rows", [])
if not isinstance(rows, list) or not rows:
    raise SystemExit("Menu state QA marker does not contain device rows")
required_top_level = ["lastUpdatedText", "deviceCount"]
missing_top_level = [key for key in required_top_level if key not in marker or marker.get(key) in ("", None)]
if missing_top_level:
    raise SystemExit(f"Menu state QA marker is missing fields: {', '.join(missing_top_level)}")
required_row_fields = ["name", "percentageText", "statusText", "symbolName"]
missing_row_fields = [
    key
    for key in required_row_fields
    if key not in rows[0] or rows[0].get(key) in ("", None)
]
if missing_row_fields:
    raise SystemExit(f"Menu state QA marker first row is missing fields: {', '.join(missing_row_fields)}")
if expected_notification_status == "denied" and marker.get("notificationStatus") != "denied":
    raise SystemExit("Menu state QA marker does not record the denied notification status")
if marker.get("deviceCount") != len(rows):
    raise SystemExit("Menu state QA marker deviceCount does not match row count")
print(f"QA session menu state marker: {marker_path}")
print(f"QA session menu state rows: {len(rows)}")
PY
  fi
fi

echo "System QA session complete"
echo "Log: $LOG_FILE"
