#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JSON_FILE="${BATTERY_MONITOR_DEVICE_JSON:-}"
BLUETOOTH_JSON_FILE="${BATTERY_MONITOR_BLUETOOTH_JSON:-}"
NAME_PATTERN=""
KIND=""
SOURCE=""
ADDRESS=""

usage() {
  cat <<'EOF'
Usage: ./scripts/verify_device_visible.sh (--name <device-name-substring> | --address <bluetooth-address>) [options]

Options:
  --name <text>       Optional if --address is provided. Case-insensitive substring to match device name.
  --address <address> Optional. Bluetooth address to match, such as 08:65:18:B7:1C:E6.
  --kind <kind>       Optional. Expected kind, such as internalBattery or peripheral.
  --source <source>   Optional. Expected source, such as IOKit, IORegistry, IOBluetooth, or CoreBluetooth.
  --json-file <path>  Optional. Read an existing BatteryMonitorCLI --json snapshot instead of running the CLI.
  --bluetooth-json-file <path>
                      Optional. Read existing system_profiler SPBluetoothDataType -json output for missing-device diagnostics.

Examples:
  ./scripts/verify_device_visible.sh --name "Magic Trackpad" --kind peripheral
  ./scripts/verify_device_visible.sh --address "08:65:18:B7:1C:E6" --kind peripheral
  ./scripts/verify_device_visible.sh --name "InternalBattery" --kind internalBattery --source IOKit
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 64
      }
      NAME_PATTERN="$2"
      shift 2
      ;;
    --address)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 64
      }
      ADDRESS="$2"
      shift 2
      ;;
    --kind)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 64
      }
      KIND="$2"
      shift 2
      ;;
    --source)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 64
      }
      SOURCE="$2"
      shift 2
      ;;
    --json-file)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 64
      }
      JSON_FILE="$2"
      shift 2
      ;;
    --bluetooth-json-file)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 64
      }
      BLUETOOTH_JSON_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [ -z "$NAME_PATTERN" ] && [ -z "$ADDRESS" ]; then
  echo "Missing required --name or --address argument" >&2
  usage >&2
  exit 64
fi

TEMP_JSON=""
cleanup() {
  if [ -n "$TEMP_JSON" ]; then
    rm -f "$TEMP_JSON"
  fi
}
trap cleanup EXIT INT TERM

if [ -z "$JSON_FILE" ]; then
  TEMP_JSON="$(mktemp "${TMPDIR:-/tmp}/battery-monitor-device-visible.XXXXXX.json")"
  (cd "$ROOT" && swift run --quiet BatteryMonitorCLI --json > "$TEMP_JSON")
  JSON_FILE="$TEMP_JSON"
fi

if [ ! -f "$JSON_FILE" ]; then
  echo "Snapshot JSON not found: $JSON_FILE" >&2
  exit 66
fi

python3 - "$JSON_FILE" "$NAME_PATTERN" "$KIND" "$SOURCE" "$BLUETOOTH_JSON_FILE" "$ADDRESS" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
raw_name_pattern = sys.argv[2]
name_pattern = raw_name_pattern.casefold()
expected_kind = sys.argv[3]
expected_source = sys.argv[4]
bluetooth_json_path = sys.argv[5]
raw_address_filter = sys.argv[6]


def normalized_address(value):
    return re.sub(r"[^0-9a-f]", "", str(value).casefold())


address_filter = normalized_address(raw_address_filter)

try:
    snapshot = json.loads(json_path.read_text())
except Exception as error:
    raise SystemExit(f"Unable to parse BatteryMonitorCLI JSON {json_path}: {error}")

devices = snapshot.get("devices")
if not isinstance(devices, list):
    raise SystemExit(f"BatteryMonitorCLI JSON is missing a devices array: {json_path}")

matches = []
available_rows = []
for device in devices:
    name = str(device.get("name", ""))
    kind = str(device.get("kind", ""))
    source = str(device.get("source", ""))
    percentage = device.get("percentage")
    charging = device.get("isCharging", None)
    connected = device.get("isConnected", True)
    device_id = str(device.get("id", ""))

    charging_text = "not reported"
    if charging is True:
        charging_text = "charging"
    elif charging is False:
        charging_text = "not charging"

    row = {
        "name": name,
        "kind": kind,
        "source": source,
        "percentage": percentage,
        "charging": charging_text,
        "connected": connected,
        "id": device_id,
    }
    available_rows.append(row)

    if connected is False:
        continue
    if name_pattern and name_pattern not in name.casefold():
        continue
    if address_filter and address_filter not in normalized_address(device_id):
        continue
    if expected_kind and kind != expected_kind:
        continue
    if expected_source and source != expected_source:
        continue
    if not isinstance(percentage, int) or percentage < 0 or percentage > 100:
        raise SystemExit(f"Matched device has invalid percentage: {name} ({percentage!r})")
    matches.append(row)

if matches:
    print(f"Device visibility check OK: {len(matches)} match(es)")
    for row in matches:
        print(
            "- {name} | kind={kind} | battery={percentage}% | charging={charging} | "
            "source={source} | id={id}".format(**row)
        )
    raise SystemExit(0)

filters = []
if raw_name_pattern:
    filters.append(f"name contains {raw_name_pattern!r}")
if raw_address_filter:
    filters.append(f"address={raw_address_filter!r}")
if expected_kind:
    filters.append(f"kind={expected_kind!r}")
if expected_source:
    filters.append(f"source={expected_source!r}")
print("Device not visible for filter: " + ", ".join(filters), file=sys.stderr)
if available_rows:
    print("Currently visible devices:", file=sys.stderr)
    for row in available_rows:
        connected_text = "connected" if row["connected"] is not False else "disconnected"
        percentage_text = (
            f"{row['percentage']}%"
            if isinstance(row["percentage"], int)
            else str(row["percentage"])
        )
        print(
            "- {name} | kind={kind} | battery={battery} | charging={charging} | "
            "source={source} | {connected}".format(
                name=row["name"],
                kind=row["kind"],
                battery=percentage_text,
                charging=row["charging"],
                source=row["source"],
                connected=connected_text,
            ),
            file=sys.stderr,
        )
else:
    print("Currently visible devices: none", file=sys.stderr)


def load_bluetooth_payload():
    if bluetooth_json_path:
        try:
            return json.loads(Path(bluetooth_json_path).read_text())
        except Exception as error:
            print(f"Unable to parse Bluetooth diagnostics JSON {bluetooth_json_path}: {error}", file=sys.stderr)
            return None

    try:
        result = subprocess.run(
            ["/usr/sbin/system_profiler", "SPBluetoothDataType", "-json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except Exception as error:
        print(f"Bluetooth diagnostics unavailable: {error}", file=sys.stderr)
        return None

    if result.returncode != 0:
        stderr = result.stderr.strip()
        detail = f": {stderr}" if stderr else ""
        print(f"Bluetooth diagnostics unavailable: system_profiler exited {result.returncode}{detail}", file=sys.stderr)
        return None

    try:
        return json.loads(result.stdout)
    except Exception as error:
        print(f"Unable to parse system_profiler Bluetooth JSON: {error}", file=sys.stderr)
        return None


def collect_bluetooth_devices(value, is_connected=None):
    rows = []
    if isinstance(value, list):
        for item in value:
            rows.extend(collect_bluetooth_devices(item, is_connected))
        return rows

    if not isinstance(value, dict):
        return rows

    for key, child in value.items():
        if key == "device_connected":
            rows.extend(collect_bluetooth_devices(child, True))
            continue
        if key == "device_not_connected":
            rows.extend(collect_bluetooth_devices(child, False))
            continue

        if isinstance(child, dict):
            address = child.get("device_address")
            if address and str(key).strip():
                rows.append(
                    {
                        "name": str(key),
                        "address": str(address),
                        "minor_type": str(child.get("device_minorType", "unknown")),
                        "is_connected": is_connected,
                    }
                )
            rows.extend(collect_bluetooth_devices(child, is_connected))
        elif isinstance(child, list):
            rows.extend(collect_bluetooth_devices(child, is_connected))

    return rows


bluetooth_payload = load_bluetooth_payload()
if bluetooth_payload is not None:
    candidates = [
        row for row in collect_bluetooth_devices(bluetooth_payload)
        if (not name_pattern or name_pattern in row["name"].casefold())
        and (not address_filter or address_filter in normalized_address(row["address"]))
    ]
    if candidates:
        print("Paired Bluetooth candidates matching filter:", file=sys.stderr)
        for row in candidates:
            if row["is_connected"] is True:
                state = "connected"
                reason = "connected but not present in BatteryMonitorCLI snapshot"
            elif row["is_connected"] is False:
                state = "not connected"
                reason = "connect or wake the device, then rerun the visibility check"
            else:
                state = "unknown"
                reason = "confirm connection state, then rerun the visibility check"
            print(
                "- {name} | bluetooth={state} | type={minor_type} | address={address} | {reason}".format(
                    name=row["name"],
                    state=state,
                    minor_type=row["minor_type"],
                    address=row["address"],
                    reason=reason,
                ),
                file=sys.stderr,
            )
    else:
        print("Paired Bluetooth candidates matching filter: none", file=sys.stderr)
raise SystemExit(1)
PY
