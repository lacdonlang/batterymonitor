#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JSON_FILE="${BATTERY_MONITOR_DEVICE_JSON:-}"
BLUETOOTH_JSON_FILE="${BATTERY_MONITOR_BLUETOOTH_JSON:-}"

usage() {
  cat <<'EOF'
Usage: ./scripts/report_bluetooth_candidate_visibility.sh [options]

Options:
  --json-file <path>  Optional. Read an existing BatteryMonitorCLI --json snapshot instead of running the CLI.
  --bluetooth-json-file <path>
                      Optional. Read existing system_profiler SPBluetoothDataType -json output.

Examples:
  ./scripts/report_bluetooth_candidate_visibility.sh
  ./scripts/report_bluetooth_candidate_visibility.sh --json-file /path/to/battery-snapshot.json
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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

TEMP_JSON=""
cleanup() {
  if [ -n "$TEMP_JSON" ]; then
    rm -f "$TEMP_JSON"
  fi
}
trap cleanup EXIT INT TERM

if [ -z "$JSON_FILE" ]; then
  TEMP_JSON="$(mktemp "${TMPDIR:-/tmp}/battery-monitor-bluetooth-candidates.XXXXXX.json")"
  (cd "$ROOT" && swift run --quiet BatteryMonitorCLI --json > "$TEMP_JSON")
  JSON_FILE="$TEMP_JSON"
fi

if [ ! -f "$JSON_FILE" ]; then
  echo "Snapshot JSON not found: $JSON_FILE" >&2
  exit 66
fi

python3 - "$JSON_FILE" "$BLUETOOTH_JSON_FILE" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
bluetooth_json_path = sys.argv[2]


def normalized_address(value):
    return re.sub(r"[^0-9a-f]", "", str(value).casefold())


def normalized_name(value):
    return re.sub(r"[^0-9a-z]+", "-", str(value).casefold()).strip("-")


def escaped(value):
    return str(value).replace("|", "\\|")


def quoted_address(address):
    return '"' + str(address).replace('"', '\\"') + '"'


def is_battery_candidate(row):
    name = normalized_name(row.get("name", ""))
    minor_type = normalized_name(row.get("minor_type", ""))
    terms = [
        "airpods",
        "headphone",
        "keyboard",
        "magic-keyboard",
        "magic-mouse",
        "magic-trackpad",
        "mouse",
        "mx-master",
        "trackpad",
    ]
    return any(term in name or term in minor_type for term in terms)


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


def load_bluetooth_payload():
    if bluetooth_json_path:
        try:
            return json.loads(Path(bluetooth_json_path).read_text())
        except Exception as error:
            raise SystemExit(f"Unable to parse Bluetooth diagnostics JSON {bluetooth_json_path}: {error}")

    try:
        result = subprocess.run(
            ["/usr/sbin/system_profiler", "SPBluetoothDataType", "-json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except Exception as error:
        raise SystemExit(f"Bluetooth diagnostics unavailable: {error}")

    if result.returncode != 0:
        detail = result.stderr.strip()
        suffix = f": {detail}" if detail else ""
        raise SystemExit(f"Bluetooth diagnostics unavailable: system_profiler exited {result.returncode}{suffix}")

    try:
        return json.loads(result.stdout)
    except Exception as error:
        raise SystemExit(f"Unable to parse system_profiler Bluetooth JSON: {error}")


def deduplicated_candidates(rows):
    result = []
    index_by_address = {}
    for row in rows:
        address_key = normalized_address(row.get("address", ""))
        if not address_key:
            continue
        if address_key in index_by_address:
            existing = result[index_by_address[address_key]]
            if existing.get("is_connected") is not True and row.get("is_connected") is True:
                result[index_by_address[address_key]] = row
            continue
        index_by_address[address_key] = len(result)
        result.append(row)

    return sorted(result, key=lambda row: (row.get("is_connected") is not True, row.get("name", "").casefold()))


def same_visible_device(device, candidate):
    candidate_address = normalized_address(candidate.get("address", ""))
    device_id_address = normalized_address(device.get("id", ""))
    if candidate_address and candidate_address in device_id_address:
        return True

    device_name = normalized_name(device.get("name", ""))
    candidate_name = normalized_name(candidate.get("name", ""))
    return bool(device_name and candidate_name and (device_name in candidate_name or candidate_name in device_name))


try:
    snapshot = json.loads(json_path.read_text())
except Exception as error:
    raise SystemExit(f"Unable to parse BatteryMonitorCLI JSON {json_path}: {error}")

devices = snapshot.get("devices")
if not isinstance(devices, list):
    raise SystemExit(f"BatteryMonitorCLI JSON is missing a devices array: {json_path}")

bluetooth_payload = load_bluetooth_payload()
candidates = deduplicated_candidates([
    row for row in collect_bluetooth_devices(bluetooth_payload)
    if is_battery_candidate(row)
])

rows = []
missing_rows = []
visible_count = 0

for candidate in candidates:
    match = next((device for device in devices if same_visible_device(device, candidate)), None)
    command = f"./scripts/verify_device_visible.sh --address {quoted_address(candidate['address'])} --kind peripheral"
    if match:
        visible_count += 1
        visibility = "visible as {name} ({battery}%, {source})".format(
            name=match.get("name", ""),
            battery=match.get("percentage", ""),
            source=match.get("source", ""),
        )
        reason = ""
    elif candidate.get("is_connected") is True:
        visibility = "not visible"
        reason = "connected but not present in BatteryMonitorCLI snapshot; check Bluetooth permission and fallback readers"
        missing_rows.append((candidate, reason, command))
    elif candidate.get("is_connected") is False:
        visibility = "not visible"
        reason = "not connected; connect or wake the device, then rerun the visibility check"
        missing_rows.append((candidate, reason, command))
    else:
        visibility = "not visible"
        reason = "connection state unknown; confirm connection state, then rerun the visibility check"
        missing_rows.append((candidate, reason, command))

    if reason:
        visibility = f"{visibility} ({reason})"

    if candidate.get("is_connected") is True:
        bluetooth_state = "connected"
    elif candidate.get("is_connected") is False:
        bluetooth_state = "not connected"
    else:
        bluetooth_state = "unknown"

    rows.append({
        "name": candidate["name"],
        "state": bluetooth_state,
        "type": candidate.get("minor_type") or "unknown",
        "address": candidate["address"],
        "visibility": visibility,
        "command": command,
    })

print("Bluetooth battery candidate visibility report")
print(f"Snapshot devices: {len(devices)}")
print(f"Summary: paired battery candidates={len(candidates)}, visible={visible_count}, not visible={len(candidates) - visible_count}")
print()

if rows:
    print("| Name | Bluetooth | Type | Address | BatteryMonitorCLI | Verification command |")
    print("| --- | --- | --- | --- | --- | --- |")
    for row in rows:
        print(
            "| {name} | {state} | {type} | {address} | {visibility} | `{command}` |".format(
                name=escaped(row["name"]),
                state=escaped(row["state"]),
                type=escaped(row["type"]),
                address=escaped(row["address"]),
                visibility=escaped(row["visibility"]),
                command=escaped(row["command"]),
            )
        )
else:
    print("- No paired Bluetooth battery candidates found.")

print()
print("Missing Bluetooth battery candidates:")
if missing_rows:
    for candidate, reason, _ in missing_rows:
        if candidate.get("is_connected") is True:
            state = "connected"
        elif candidate.get("is_connected") is False:
            state = "not connected"
        else:
            state = "unknown"
        print(
            "- {name} | bluetooth={state} | type={minor_type} | address={address} | {reason}".format(
                name=candidate["name"],
                state=state,
                minor_type=candidate.get("minor_type") or "unknown",
                address=candidate["address"],
                reason=reason,
            )
        )
else:
    print("- none")

print()
print("Suggested verification commands:")
if missing_rows:
    seen = set()
    for _, _, command in missing_rows:
        if command in seen:
            continue
        seen.add(command)
        print(f"- {command}")
else:
    print("- none")
PY
