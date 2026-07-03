<p align="center">
  <img src="Resources/App/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Battery Monitor icon">
</p>

<h1 align="center">Battery Monitor</h1>

<p align="center">
  <a href="https://github.com/lacdonlang/batterymonitor/releases/latest"><img src="https://img.shields.io/github/v/release/lacdonlang/batterymonitor?label=release" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"></a>
</p>

<p align="center">
  <b>English</b> | <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  A macOS menu bar app that monitors the battery of your Mac and every Bluetooth peripheral, and notifies you before anything dies.
</p>

## Features

- **Every device in one list** — the internal battery, AirPods (including the charging case), Magic Keyboard / Mouse / Trackpad, Logitech MX devices, and anything else macOS can see.
- **Charging state that matches the system** — read from the same power source data as the built-in battery widget; charging devices are shown in green with a bolt.
- **Low-battery notifications** — configurable threshold, reminder cooldown, and recovery margin, with "Remind Me Later" and "Ignore This Device" actions.
- **Desktop widget** — small, medium, and large families with a frosted-glass look; each row doubles as a battery level meter.
- **Bilingual** — English and Simplified Chinese, following the system language by default with a manual override in Settings.
- **Launch at login**, per-device mute, and adjustable polling interval.

## Installation

Download the latest `BatteryMonitor-x.y.z.dmg` from [Releases](https://github.com/lacdonlang/batterymonitor/releases/latest), open it, and drag **BatteryMonitor** into your Applications folder.

The DMG is Developer ID signed and notarized by Apple, so it opens without Gatekeeper warnings after a one-time confirmation.

> [!NOTE]
> To add the widget: run the app once, then right-click the desktop → Edit Widgets → search for "Battery Monitor".

## Building from source

Requirements: macOS 14+, Xcode with command line tools, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/lacdonlang/batterymonitor.git
cd batterymonitor

# Generate the Xcode project (project.yml is the single source of truth)
xcodegen generate --spec project.yml

# Run the test suite (standalone harness, no XCTest required)
swift run BatteryMonitorTestHarness

# Full local verification: builds, tests, plist/entitlements/asset checks, Xcode build smoke tests
./scripts/test.sh
```

Inspect current device batteries from the command line:

```sh
swift run BatteryMonitorCLI            # table output
swift run BatteryMonitorCLI --json     # JSON output
```

Build a notarized release DMG (requires an Apple Developer account; see the script header for credential setup):

```sh
./scripts/release_dmg.sh
```

> [!IMPORTANT]
> The App Group identifier is Team-ID-prefixed (`<TeamID>.com.lacdon.batterymonitor`). If you fork and sign with your own account, replace the Team ID in `project.yml` and `Sources/BatteryMonitorShared/BatteryMonitorConstants.swift`. On macOS, a `group.`-prefixed App Group is rejected by containermanagerd and every file access in the container blocks forever.

## How it works

Battery data is merged from a prioritized chain of readers. Earlier readers own device identity during deduplication; later readers only fill in missing charging or connection state.

| Reader | Source | Covers |
|---|---|---|
| IOKitPowerSource | IOPS power source snapshot | Internal battery, some peripherals |
| AppleSmartBattery | IORegistry | Internal battery details |
| IORegistry HID | `BatteryPercent` property | Magic series peripherals |
| IOBluetooth | Classic Bluetooth battery fields | Headphones and similar |
| SystemProfiler | `SPBluetoothDataType` | AirPods left/right/case levels |
| CoreBluetooth BLE | Standard Battery Service (0x180F) | MX Master and other BLE devices |
| AccessoryPowerSource | Same interface as the system battery widget | Authoritative charging state |

The menu bar app polls every 3 minutes, reacts to power source change events, and writes snapshots into the App Group container; the WidgetKit extension renders from the same container. Disconnected devices are retained for 7 days to keep notification state continuous, but are hidden from the UI.

## License

[MIT](LICENSE) © 2026 lacdonlang
