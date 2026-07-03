#!/bin/sh
set -eu

APP_EXECUTABLE="${1:-DerivedData/Local/Build/Products/Debug/BatteryMonitor.app/Contents/MacOS/BatteryMonitor}"
BASELINE_SNAPSHOT_JSON="${2:-}"

if [ ! -x "$APP_EXECUTABLE" ]; then
  echo "App executable is missing or not executable: $APP_EXECUTABLE" >&2
  exit 1
fi

STORE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/battery-monitor-runtime-smoke.XXXXXX")"
LOG_FILE="$STORE_DIR/app.log"
BASELINE_FILE="$STORE_DIR/baseline-low-notifications.json"

run_app_once() {
  BATTERY_MONITOR_STORE_DIR="$STORE_DIR" \
  BATTERY_MONITOR_DISABLE_NOTIFICATIONS=1 \
    "$APP_EXECUTABLE" >"$LOG_FILE" 2>&1 &
  APP_PID=$!

  sleep 5

  if kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID"
    wait "$APP_PID" 2>/dev/null || true
  else
    wait "$APP_PID" || {
      cat "$LOG_FILE" >&2
      exit 1
    }
    echo "App exited before runtime smoke completed" >&2
    cat "$LOG_FILE" >&2
    exit 1
  fi
}

python3 - "$STORE_DIR" <<'PY'
import json
import os
import sys

settings_path = os.path.join(sys.argv[1], "settings.json")
with open(settings_path, "w") as file:
    json.dump(
        {
            "lowBatteryThreshold": 100,
            "recoveryMargin": 1,
            "pollingInterval": 180,
            "reminderCooldown": 7200,
            "ignoredDeviceIDs": [],
            "ignoredDeviceFingerprints": [],
        },
        file,
        indent=2,
        sort_keys=True,
    )
PY

run_app_once

python3 - "$STORE_DIR" "$BASELINE_FILE" "$BASELINE_SNAPSHOT_JSON" <<'PY'
import json
import os
import sys

store_dir = sys.argv[1]
baseline_path = sys.argv[2]
baseline_snapshot_path = sys.argv[3]
snapshot_path = os.path.join(store_dir, "battery-snapshot.json")
state_path = os.path.join(store_dir, "notification-state.json")

temporary_files = [
    name for name in os.listdir(store_dir)
    if name.startswith(".") and name.endswith(".tmp")
]
if temporary_files:
    raise SystemExit(f"Shared store left temporary files behind: {temporary_files}")

if not os.path.exists(snapshot_path):
    raise SystemExit(f"Missing snapshot file: {snapshot_path}")

with open(snapshot_path) as file:
    snapshot = json.load(file)

if not isinstance(snapshot.get("updatedAt"), str) or not snapshot["updatedAt"]:
    raise SystemExit(f"Snapshot is missing updatedAt: {snapshot}")

devices = snapshot.get("devices", [])
if not devices:
    raise SystemExit("Snapshot did not contain any devices")

for device in devices:
    for key in ("id", "name", "kind", "source", "updatedAt"):
        if not device.get(key):
            raise SystemExit(f"Device is missing {key}: {device}")
    percentage = device.get("percentage")
    if not isinstance(percentage, int) or percentage < 0 or percentage > 100:
        raise SystemExit(f"Device has invalid percentage: {device}")
    if not isinstance(device.get("isConnected"), bool):
        raise SystemExit(f"Device has invalid connection state: {device}")

if baseline_snapshot_path:
    if not os.path.exists(baseline_snapshot_path):
        raise SystemExit(f"Missing baseline snapshot JSON: {baseline_snapshot_path}")
    with open(baseline_snapshot_path) as file:
        baseline_snapshot = json.load(file)

    baseline_peripherals = [
        device for device in baseline_snapshot.get("devices", [])
        if device.get("kind") == "peripheral" and device.get("isConnected") is True
    ]
    app_device_ids = {device.get("id") for device in devices}
    app_device_fingerprints = {
        (device.get("name"), device.get("kind"), device.get("source"))
        for device in devices
    }
    missing_peripherals = [
        device for device in baseline_peripherals
        if device.get("id") not in app_device_ids
        and (device.get("name"), device.get("kind"), device.get("source")) not in app_device_fingerprints
    ]
    if missing_peripherals:
        names = ", ".join(
            f"{device.get('name', '<unnamed>')} ({device.get('source', '<unknown source>')})"
            for device in missing_peripherals
        )
        raise SystemExit(f"App snapshot is missing CLI-visible peripheral devices: {names}")

if not os.path.exists(state_path):
    raise SystemExit(f"Missing notification state file: {state_path}")

with open(state_path) as file:
    states = json.load(file)

eligible_low_devices = [
    device for device in devices
    if device.get("isConnected") is True
    and device.get("isCharging") is not True
    and device.get("percentage", 100) < 100
]
if not eligible_low_devices:
    raise SystemExit("Runtime smoke needs at least one visible device below the seeded 100% threshold")

low_states = {
    state.get("deviceID"): state.get("lastNotifiedAt")
    for state in states.values()
    if state.get("wasLowBattery") is True and state.get("lastNotifiedAt")
}
eligible_ids = {device["id"] for device in eligible_low_devices}
matched_low_states = {
    device_id: notified_at
    for device_id, notified_at in low_states.items()
    if device_id in eligible_ids
}
if not matched_low_states:
    raise SystemExit(
        "Seeded settings.json did not drive any visible device into low-battery notification state"
    )

with open(baseline_path, "w") as file:
    json.dump(matched_low_states, file, indent=2, sort_keys=True)
PY

run_app_once

python3 - "$STORE_DIR" "$BASELINE_FILE" <<'PY'
import json
import os
import sys

store_dir = sys.argv[1]
baseline_path = sys.argv[2]
snapshot_path = os.path.join(store_dir, "battery-snapshot.json")
state_path = os.path.join(store_dir, "notification-state.json")

temporary_files = [
    name for name in os.listdir(store_dir)
    if name.startswith(".") and name.endswith(".tmp")
]
if temporary_files:
    raise SystemExit(f"Shared store left temporary files behind after restart: {temporary_files}")

with open(snapshot_path) as file:
    snapshot = json.load(file)
with open(state_path) as file:
    states = json.load(file)
with open(baseline_path) as file:
    baseline_low_states = json.load(file)

if not snapshot.get("devices"):
    raise SystemExit("Cached snapshot disappeared after app restart")

current_notified_at = {
    state.get("deviceID"): state.get("lastNotifiedAt")
    for state in states.values()
    if state.get("deviceID")
}
for device_id, first_notified_at in baseline_low_states.items():
    if current_notified_at.get(device_id) != first_notified_at:
        raise SystemExit(
            f"Notification cooldown was not preserved for {device_id}: "
            f"{first_notified_at!r} -> {current_notified_at.get(device_id)!r}"
        )

print(
    f"Runtime smoke OK: {len(snapshot['devices'])} device(s), "
    f"cached snapshot survived app exit, cooldown state preserved, store={store_dir}"
)
PY
