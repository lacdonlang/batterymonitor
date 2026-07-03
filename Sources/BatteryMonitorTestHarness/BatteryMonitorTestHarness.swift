import BatteryMonitorCore
import BatteryMonitorShared
import Foundation
import UserNotifications

@main
struct BatteryMonitorTestHarness {
    static func main() async {
        L10n.languageOverride = .simplifiedChinese

        var runner = TestRunner()

        await runner.run("BatteryPercentage calculates percentages") {
            try expect(BatteryPercentage.calculate(current: 1, max: 4) == 25)
            try expect(BatteryPercentage.calculate(current: 2, max: 3) == 67)
        }

        await runner.run("BatteryPercentage clamps invalid values") {
            try expect(BatteryPercentage.calculate(current: 120, max: 100) == 100)
            try expect(BatteryPercentage.calculate(current: -10, max: 100) == 0)
            try expect(BatteryPercentage.calculate(current: 10, max: 0) == 0)
        }

        await runner.run("BatteryDevice ID uses stable normalized identifier") {
            let id = BatteryDevice.makeID(
                name: "Magic Mouse",
                kind: .peripheral,
                source: "IOKit",
                stableIdentifier: "Serial Number 123"
            )

            try expect(id == "iokit:serial-number-123")
        }

        await runner.run("BatteryDevice ID falls back to name kind and source") {
            let id = BatteryDevice.makeID(
                name: "Magic Mouse 2",
                kind: .peripheral,
                source: "IORegistry"
            )

            try expect(id == "ioregistry:magic-mouse-2-peripheral-ioregistry")
        }

        await runner.run("SystemProfilerBluetoothDeviceResolver parses Bluetooth identities") {
            let identities = try SystemProfilerBluetoothDeviceResolver.parseIdentities(
                from: Data(systemProfilerBluetoothFixture().utf8)
            )

            try expect(identities.count == 3)
            try expect(identities[0].name == "Desk Mouse")
            try expect(identities[0].address == "04:4B:ED:BC:D9:8B")
            try expect(identities[0].minorType == "Mouse")
            try expect(identities[0].isConnected == true)
            try expect(identities[0].batteryLevelMain == nil)

            let airpods = identities.first { $0.name == "Desk AirPods" }
            try expect(airpods?.isConnected == false)
            try expect(airpods?.batteryLevelLeft == 100)
            try expect(airpods?.batteryLevelRight == 95)
            try expect(airpods?.batteryLevelCase == 11)
        }

        await runner.run("SystemProfilerBatteryReader splits earbuds and charging case") {
            let now = fixedDate()
            let airpods = BluetoothDeviceIdentity(
                name: "Desk AirPods",
                address: "50:F3:51:B4:B4:C8",
                minorType: "Headphones",
                isConnected: false,
                batteryLevelLeft: 100,
                batteryLevelRight: 95,
                batteryLevelCase: 11
            )
            let keyboardWithoutBattery = BluetoothDeviceIdentity(
                name: "Desk Keyboard",
                address: "38:09:FB:30:9F:78",
                minorType: "Keyboard",
                isConnected: true
            )

            let devices = SystemProfilerBatteryReader.makeDevices(
                now: now,
                bluetoothIdentities: [airpods, keyboardWithoutBattery]
            )

            try expect(devices.count == 2)
            try expect(devices[0].name == "Desk AirPods")
            try expect(devices[0].percentage == 95)
            try expect(devices[0].isCharging == nil)
            try expect(devices[0].isConnected == true)
            try expect(devices[0].source == "SystemProfiler")
            try expect(devices[0].id == "systemprofiler:50-f3-51-b4-b4-c8")
            try expect(devices[1].name == "Desk AirPods充电盒")
            try expect(devices[1].percentage == 11)
            try expect(devices[1].id == "systemprofiler:50-f3-51-b4-b4-c8-case")
        }

        await runner.run("SystemProfilerBatteryReader prefers main battery level over earbuds") {
            let identity = BluetoothDeviceIdentity(
                name: "Desk Headset",
                address: "AA:BB:CC:DD:EE:10",
                minorType: "Headphones",
                isConnected: true,
                batteryLevelMain: 85,
                batteryLevelLeft: 40,
                batteryLevelRight: 42
            )

            let devices = SystemProfilerBatteryReader.makeDevices(
                now: fixedDate(),
                bluetoothIdentities: [identity]
            )

            try expect(devices.count == 1)
            try expect(devices[0].percentage == 85)
        }

        await runner.run("IORegistryBatteryReader parses external HID batteries") {
            let now = fixedDate()
            let identities = [
                BluetoothDeviceIdentity(
                    name: "Desk Mouse",
                    address: "04:4B:ED:BC:D9:8B",
                    minorType: "Mouse",
                    isConnected: true
                ),
                BluetoothDeviceIdentity(
                    name: "Desk Keyboard",
                    address: "38:09:FB:30:9F:78",
                    minorType: "Keyboard",
                    isConnected: true
                )
            ]
            let devices = IORegistryBatteryReader.parseDevices(
                from: ioRegistryBatteryFixture(),
                now: now,
                bluetoothIdentities: identities
            )

            try expect(devices.count == 2)
            try expect(devices[0].name == "Desk Mouse (Magic Mouse)")
            try expect(devices[0].percentage == 94)
            try expect(devices[0].isCharging == false)
            try expect(devices[0].source == "IORegistry")
            try expect(devices[0].id == "ioregistry:04-4b-ed-bc-d9-8b")
            try expect(devices[1].name == "Desk Keyboard (Magic Keyboard)")
            try expect(devices[1].percentage == 22)
            try expect(devices[1].isCharging == true)
        }

        await runner.run("IORegistryBatteryReader infers charging from extended battery flags") {
            let identities = [
                BluetoothDeviceIdentity(
                    name: "Flags Keyboard",
                    address: "AA:BB:CC:DD:EE:01",
                    minorType: "Keyboard",
                    isConnected: true
                ),
                BluetoothDeviceIdentity(
                    name: "Flags Trackpad",
                    address: "AA:BB:CC:DD:EE:02",
                    minorType: "Trackpad",
                    isConnected: true
                )
            ]
            let devices = IORegistryBatteryReader.parseDevices(
                from: ioRegistryExtendedBatteryFlagsFixture(),
                now: fixedDate(),
                bluetoothIdentities: identities
            )
            let diagnostics = IORegistryBatteryReader.parseDiagnostics(
                from: ioRegistryExtendedBatteryFlagsFixture(),
                bluetoothIdentities: identities
            )

            try expect(devices.count == 2)
            try expect(devices[0].name == "Flags Keyboard (Magic Keyboard)")
            try expect(devices[0].isCharging == false)
            try expect(devices[1].name == "Flags Trackpad")
            try expect(devices[1].isCharging == true)
            try expect(diagnostics[0].chargingFields.isEmpty)
            try expect(diagnostics[0].inferredChargingState == false)
            try expect(diagnostics[1].inferredChargingState == true)
        }

        await runner.run("IORegistryBatteryReader decodes zero battery flags as not charging") {
            let devices = IORegistryBatteryReader.parseDevices(
                from: ioRegistryZeroBatteryFlagsFixture(),
                now: fixedDate(),
                bluetoothIdentities: [
                    BluetoothDeviceIdentity(
                        name: "Flags Mouse",
                        address: "AA:BB:CC:DD:EE:03",
                        minorType: "Mouse",
                        isConnected: true
                    )
                ]
            )
            let diagnostics = IORegistryBatteryReader.parseDiagnostics(
                from: ioRegistryZeroBatteryFlagsFixture()
            )

            try expect(devices.count == 1)
            try expect(devices[0].name == "Flags Mouse (Magic Mouse)")
            try expect(devices[0].isCharging == false)
            try expect(diagnostics.count == 1)
            try expect(diagnostics[0].inferredChargingState == false)
        }

        await runner.run("IORegistryBatteryReader reports battery source diagnostics") {
            let identities = [
                BluetoothDeviceIdentity(
                    name: "Desk Mouse",
                    address: "04:4B:ED:BC:D9:8B",
                    minorType: "Mouse",
                    isConnected: true
                ),
                BluetoothDeviceIdentity(
                    name: "Desk Keyboard",
                    address: "38:09:FB:30:9F:78",
                    minorType: "Keyboard",
                    isConnected: true
                )
            ]
            let diagnostics = IORegistryBatteryReader.parseDiagnostics(
                from: ioRegistryBatteryFixture(),
                bluetoothIdentities: identities
            )

            try expect(diagnostics.count == 2)
            try expect(diagnostics[0].name == "Desk Mouse (Magic Mouse)")
            try expect(diagnostics[0].chargingFields == ["IsCharging=No"])
            try expect(diagnostics[0].batteryStatusFlags == "0")
            try expect(diagnostics[1].name == "Desk Keyboard (Magic Keyboard)")
            try expect(diagnostics[1].chargingFields == ["Is Charging=Yes"])
            try expect(diagnostics[1].batteryStatusFlags == "6")
            try expect(diagnostics[1].inferredChargingState == true)
            try expect(diagnostics[1].supportsExtendedBatteryState == "Yes")
        }

        await runner.run("IOBluetoothBatteryReader selects displayed Bluetooth battery percentage") {
            try expect(IOBluetoothBatteryReader.selectDisplayedPercentage(
                single: 33,
                combined: 0,
                left: 0,
                right: 0,
                batteryCase: 0
            ) == 33)
            try expect(IOBluetoothBatteryReader.selectDisplayedPercentage(
                single: 0,
                combined: 0,
                left: 84,
                right: 18,
                batteryCase: 71
            ) == 18)
            try expect(IOBluetoothBatteryReader.selectDisplayedPercentage(
                single: 0,
                combined: 87,
                left: 10,
                right: 12,
                batteryCase: 13
            ) == 87)
            try expect(IOBluetoothBatteryReader.selectDisplayedPercentage(
                single: 0,
                combined: 255,
                left: nil,
                right: nil,
                batteryCase: nil
            ) == nil)

            let device = IOBluetoothBatteryReader.makeDevice(
                name: "Desk AirPods Max",
                address: "70:F9:4A:9F:1E:76",
                percentage: 33,
                now: fixedDate()
            )

            try expect(device.id == "iobluetooth:70-f9-4a-9f-1e-76")
            try expect(device.source == "IOBluetooth")
            try expect(device.percentage == 33)
            try expect(device.isCharging == nil)
        }

        await runner.run("BluetoothLEBatteryServiceReader creates stable BLE battery devices") {
            let identifier = UUID(uuidString: "97915AA3-6779-EBAC-8AEA-132AD9959F80")!
            let device = BluetoothLEBatteryServiceReader.makeDevice(
                name: "MX Master 4 B",
                identifier: identifier,
                percentage: 75,
                now: fixedDate()
            )

            try expect(device.id == "corebluetooth:97915aa3-6779-ebac-8aea-132ad9959f80")
            try expect(device.name == "MX Master 4 B")
            try expect(device.source == "CoreBluetooth")
            try expect(device.percentage == 75)
            try expect(device.isCharging == nil)
        }

        await runner.run("AccessoryPowerSourceReader parses accessory power sources") {
            let now = fixedDate()
            let descriptions: [[String: Any]] = [
                [
                    "Type": "InternalBattery",
                    "Name": "InternalBattery-0",
                    "Current Capacity": 80,
                    "Max Capacity": 100
                ],
                [
                    "Type": "Accessory Source",
                    "Name": "Desk AirPods充电盒",
                    "Accessory Identifier": "7A292868-FBDF-36B1-E6A1-7B00BFA6E806",
                    "Current Capacity": 11,
                    "Max Capacity": 100,
                    "Is Charging": 1,
                    "Is Present": 1,
                    "Part Identifier": "Case"
                ],
                [
                    "Type": "Accessory Source",
                    "Name": "Desk Keyboard",
                    "Accessory Identifier": "38:09:FB:30:9F:78",
                    "Current Capacity": 16,
                    "Max Capacity": 100,
                    "Is Charging": 0,
                    "Is Present": 1
                ],
                [
                    "Type": "Accessory Source",
                    "Name": "Desk BLE Mouse",
                    "Accessory Identifier": "97915AA3-6779-EBAC-8AEA-132AD9959F80",
                    "Current Capacity": 75,
                    "Max Capacity": 100
                ],
                [
                    "Type": "Accessory Source",
                    "Name": "Gone Device",
                    "Current Capacity": 50,
                    "Is Present": 0
                ]
            ]

            let devices = AccessoryPowerSourceReader.makeDevices(from: descriptions, now: now)

            try expect(devices.count == 3)
            try expect(devices[0].name == "Desk AirPods充电盒")
            try expect(devices[0].percentage == 11)
            try expect(devices[0].isCharging == true)
            try expect(devices[0].source == "PowerSources")
            try expect(devices[0].id == "powersources:7a292868-fbdf-36b1-e6a1-7b00bfa6e806")
            try expect(devices[1].name == "Desk Keyboard")
            try expect(devices[1].isCharging == false)
            try expect(devices[1].id == "powersources:38-09-fb-30-9f-78")
            try expect(devices[2].name == "Desk BLE Mouse")
            try expect(devices[2].isCharging == nil)
        }

        await runner.run("CompositeBatteryReader merges charging state from accessory power sources") {
            let now = fixedDate()
            let bluetoothDevice = IOBluetoothBatteryReader.makeDevice(
                name: "Desk AirPods Max",
                address: "70:F9:4A:9F:1E:76",
                percentage: 95,
                now: now
            )
            let powerSourceDevices = AccessoryPowerSourceReader.makeDevices(
                from: [[
                    "Type": "Accessory Source",
                    "Name": "Desk AirPods Max",
                    "Accessory Identifier": "F9E11BAF-3B61-F341-9DDD-F9BC4FA13631",
                    "Current Capacity": 95,
                    "Max Capacity": 100,
                    "Is Charging": 1,
                    "Is Present": 1
                ]],
                now: now
            )
            let reader = CompositeBatteryReader(readers: [
                StubBatteryReader(devices: [bluetoothDevice]),
                StubBatteryReader(devices: powerSourceDevices)
            ])

            let devices = try reader.readDevices(now: now)

            try expect(devices.count == 1)
            try expect(devices[0].id == "iobluetooth:70-f9-4a-9f-1e-76")
            try expect(devices[0].source == "IOBluetooth")
            try expect(devices[0].isCharging == true)
        }

        await runner.run("CompositeBatteryReader keeps first duplicate device source") {
            let first = makeNamedDevice(
                name: "Desk Keyboard",
                percentage: 22,
                source: "IOKit",
                stableIdentifier: "38:09:FB:30:9F:78"
            )
            var duplicate = makeNamedDevice(
                name: "Desk Keyboard",
                percentage: 22,
                source: "IORegistry",
                stableIdentifier: "38-09-fb-30-9f-78"
            )
            duplicate.isCharging = true
            let unique = makeNamedDevice(
                name: "Desk Mouse",
                percentage: 94,
                source: "IORegistry",
                stableIdentifier: "04-4b-ed-bc-d9-8b"
            )
            let reader = CompositeBatteryReader(readers: [
                StubBatteryReader(devices: [first]),
                StubBatteryReader(devices: [duplicate, unique])
            ])

            let devices = try reader.readDevices(now: fixedDate())

            try expect(devices.count == 2)
            try expect(devices[0].name == "Desk Keyboard")
            try expect(devices[0].source == "IOKit")
            try expect(devices[0].isCharging == true)
            try expect(devices[1].name == "Desk Mouse")
        }

        await runner.run("BatterySnapshot Codable round-trips") {
            let snapshot = BatterySnapshot(
                devices: [
                    makeDevice(percentage: 40, kind: .internalBattery),
                    makeDevice(percentage: 12, kind: .peripheral)
                ],
                updatedAt: fixedDate()
            )
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try encoder.encode(snapshot)
            let decoded = try decoder.decode(BatterySnapshot.self, from: data)

            try expect(decoded == snapshot)
        }

        await runner.run("BatterySnapshotJSONRenderer emits pretty ISO8601 JSON") {
            let snapshot = BatterySnapshot(
                devices: [
                    makeNamedDevice(name: "Magic Mouse", percentage: 14, source: "IORegistry", stableIdentifier: "mouse")
                ],
                updatedAt: Date(timeIntervalSince1970: 100)
            )

            let json = try BatterySnapshotJSONRenderer.render(snapshot)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(BatterySnapshot.self, from: Data(json.utf8))

            try expect(decoded == snapshot)
            try expect(json.contains("\"updatedAt\" : \"1970-01-01T00:01:40Z\""))
            try expect(json.contains("\"name\" : \"Magic Mouse\""))
            try expect(json.contains("\"percentage\" : 14"))
            try expect(json.contains("\n"))
        }

        await runner.run("WidgetBatteryDisplayModel selects widget devices") {
            let updatedAt = Date(timeIntervalSince1970: 123)
            let fallbackDate = Date(timeIntervalSince1970: 456)
            let devices = [
                makeNamedDevice(name: "Mac", percentage: 61, source: "Test", stableIdentifier: "mac", kind: .internalBattery),
                makeNamedDevice(name: "AirPods", percentage: 55, source: "Test", stableIdentifier: "airpods"),
                makeNamedDevice(name: "Headphones", percentage: 44, source: "Test", stableIdentifier: "headphones"),
                makeNamedDevice(name: "Keyboard", percentage: 22, source: "Test", stableIdentifier: "keyboard"),
                makeNamedDevice(name: "Mouse", percentage: 12, source: "Test", stableIdentifier: "mouse"),
                makeNamedDevice(name: "MX Master", percentage: 75, source: "Test", stableIdentifier: "mx-master"),
                makeNamedDevice(name: "Speaker", percentage: 88, source: "Test", stableIdentifier: "speaker"),
                makeNamedDevice(name: "Trackpad", percentage: 35, source: "Test", stableIdentifier: "trackpad"),
                makeNamedDevice(name: "Watch", percentage: 52, source: "Test", stableIdentifier: "watch")
            ]
            let snapshot = BatterySnapshot(devices: devices, updatedAt: updatedAt)
            let model = WidgetBatteryDisplayModel(
                snapshot: snapshot,
                fallbackDate: fallbackDate,
                lowBatteryThreshold: 20
            )

            try expect(model.lastUpdatedAt == updatedAt)
            try expect(model.renderedAt == fallbackDate)
            try expect(model.hasSnapshot)
            try expect(model.freshnessText == "5 分钟前更新")
            try expect(model.lowestDevice?.name == "Mouse")
            try expect(model.mediumDevices.count == 3)
            try expect(!model.mediumDevices.contains { $0.name == "Trackpad" })
            try expect(model.largeDevices.count == 8)
            try expect(model.largeDevices.contains { $0.name == "Trackpad" })
            try expect(!model.largeDevices.contains { $0.name == "Watch" })
            try expect(model.isLowBattery(devices[4]))
            try expect(!model.isLowBattery(devices[3]))

            let emptyModel = WidgetBatteryDisplayModel(snapshot: nil, fallbackDate: fallbackDate)
            try expect(emptyModel.devices.isEmpty)
            try expect(emptyModel.lastUpdatedAt == fallbackDate)
            try expect(emptyModel.renderedAt == fallbackDate)
            try expect(!emptyModel.hasSnapshot)
            try expect(emptyModel.freshnessText == "暂无缓存")
            try expect(emptyModel.lowestDevice == nil)
        }

        await runner.run("WidgetBatteryDisplayModel formats cached snapshot freshness") {
            let device = makeNamedDevice(name: "Magic Mouse", percentage: 14, source: "Test", stableIdentifier: "mouse")
            let freshSnapshot = BatterySnapshot(
                devices: [device],
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
            let freshModel = WidgetBatteryDisplayModel(
                snapshot: freshSnapshot,
                fallbackDate: Date(timeIntervalSince1970: 1_030)
            )
            let cachedSnapshot = BatterySnapshot(
                devices: [device],
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
            let cachedModel = WidgetBatteryDisplayModel(
                snapshot: cachedSnapshot,
                fallbackDate: Date(timeIntervalSince1970: 5_000)
            )

            try expect(freshModel.freshnessText == "刚刚更新")
            try expect(cachedModel.freshnessText.hasPrefix("缓存 "))
        }

        await runner.run("WidgetDisplayReportRenderer renders small medium and large evidence") {
            let devices = [
                makeNamedDevice(name: "Mac", percentage: 61, source: "Test", stableIdentifier: "mac", kind: .internalBattery),
                makeNamedDevice(name: "AirPods", percentage: 55, source: "Test", stableIdentifier: "airpods"),
                makeNamedDevice(name: "Headphones", percentage: 44, source: "Test", stableIdentifier: "headphones"),
                makeNamedDevice(name: "Keyboard", percentage: 22, source: "Test", stableIdentifier: "keyboard"),
                makeNamedDevice(name: "Mouse", percentage: 12, source: "Test", stableIdentifier: "mouse"),
                makeNamedDevice(name: "MX Master", percentage: 75, source: "Test", stableIdentifier: "mx-master"),
                makeNamedDevice(name: "Speaker", percentage: 88, source: "Test", stableIdentifier: "speaker"),
                makeNamedDevice(name: "Trackpad", percentage: 35, source: "Test", stableIdentifier: "trackpad"),
                makeNamedDevice(name: "Watch", percentage: 52, source: "Test", stableIdentifier: "watch")
            ]
            let snapshot = BatterySnapshot(devices: devices, updatedAt: Date(timeIntervalSince1970: 1_000))
            let report = WidgetDisplayReportRenderer.render(
                snapshot: snapshot,
                renderedAt: Date(timeIntervalSince1970: 1_030)
            )

            try expect(report.contains("Widget display report"))
            try expect(report.contains("Has snapshot: true"))
            try expect(report.contains("Freshness: 刚刚更新"))
            try expect(report.contains("Small:\n- Mouse | 12% | 已连接 | low"))
            try expect(report.contains("Medium:\n- Mac | 61%"))
            try expect(report.contains("- Keyboard | 22%"))
            try expect(!report.contains("Medium:\n- Mac | 61%\n- AirPods | 55%\n- Headphones | 44%\n- Keyboard | 22%\n- Mouse"))
            try expect(report.contains("Large:"))
            try expect(report.contains("- Trackpad | 35%"))
            try expect(!report.contains("- Watch | 52%"))
        }

        await runner.run("WidgetSnapshotReader reads cached shared snapshot") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let snapshot = BatterySnapshot(
                devices: [
                    makeNamedDevice(name: "Keyboard", percentage: 22, source: "Test", stableIdentifier: "keyboard")
                ],
                updatedAt: Date(timeIntervalSince1970: 789)
            )

            try store.writeSnapshot(snapshot)

            let cachedSnapshot = WidgetSnapshotReader.read(from: store)
            let missingSnapshot = WidgetSnapshotReader.read(from: try SharedBatteryStore(directoryURL: temporaryDirectory()))

            try expect(cachedSnapshot == snapshot)
            try expect(missingSnapshot == nil)
            try expect(
                WidgetBatteryDisplayModel(
                    snapshot: cachedSnapshot,
                    fallbackDate: Date(timeIntervalSince1970: 999)
                ).lastUpdatedAt == snapshot.updatedAt
            )
        }

        await runner.run("WidgetSnapshotReader ignores notification state files") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let state = DeviceNotificationState(
                deviceID: "device-1",
                lastNotifiedAt: Date(timeIntervalSince1970: 100),
                wasLowBattery: true,
                lastSeenPercentage: 12,
                updatedAt: Date(timeIntervalSince1970: 101),
                deviceName: "Magic Mouse",
                deviceKind: .peripheral,
                deviceSource: "IORegistry"
            )

            try store.writeNotificationStates(["device-1": state])

            try expect(try store.readNotificationStates() == ["device-1": state])
            try expect(WidgetSnapshotReader.read(from: store) == nil)
        }

        await runner.run("WidgetSnapshotReader returns nil for invalid cached snapshot JSON") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            try Data("{ invalid snapshot json".utf8).write(to: store.snapshotFileURL())

            try expect(WidgetSnapshotReader.read(from: store) == nil)
        }

        await runner.run("MonitorSettings clamps unsafe values") {
            let settings = MonitorSettings(
                lowBatteryThreshold: 150,
                recoveryMargin: -10,
                pollingInterval: 1,
                reminderCooldown: 1
            )

            try expect(settings.lowBatteryThreshold == 100)
            try expect(settings.recoveryMargin == 1)
            try expect(settings.pollingInterval == 30)
            try expect(settings.reminderCooldown == 60)
            try expect(settings.recoveryThreshold == 100)
        }

        await runner.run("MonitorSettings defaults match MVP policy") {
            let settings = MonitorSettings.default

            try expect(settings.lowBatteryThreshold == 20)
            try expect(settings.recoveryMargin == 5)
            try expect(settings.recoveryThreshold == 25)
            try expect(settings.pollingInterval == 180)
            try expect(settings.reminderCooldown == 7_200)
            try expect(!settings.launchAtLogin)
            try expect(settings.ignoredDeviceIDs.isEmpty)
            try expect(settings.ignoredDeviceFingerprints.isEmpty)
        }

        await runner.run("RuleEngine sends alert for low battery") {
            let now = fixedDate()
            let device = makeDevice(percentage: 19)
            let result = evaluate(devices: [device], states: [:], now: now)

            try expect(result.alerts == [LowBatteryAlert(device: device, threshold: 20)])
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == now)
            try expect(result.updatedStates[device.id]?.wasLowBattery == true)
            try expect(result.updatedStates[device.id]?.lastSeenPercentage == 19)
        }

        await runner.run("RuleEngine records notification state fingerprint") {
            let now = fixedDate()
            let device = makeNamedDevice(
                name: "Magic Keyboard",
                percentage: 19,
                source: "IORegistry",
                stableIdentifier: "keyboard"
            )
            let result = evaluate(devices: [device], states: [:], now: now)
            let state = try require(result.updatedStates[device.id])

            try expect(result.alerts == [LowBatteryAlert(device: device, threshold: 20)])
            try expect(state.deviceID == device.id)
            try expect(state.lastNotifiedAt == now)
            try expect(state.wasLowBattery == true)
            try expect(state.lastSeenPercentage == 19)
            try expect(state.updatedAt == now)
            try expect(state.deviceName == device.name)
            try expect(state.deviceKind == device.kind)
            try expect(state.deviceSource == device.source)
        }

        await runner.run("RuleEngine does not alert at threshold boundary") {
            let now = fixedDate()
            let device = makeDevice(percentage: 20)
            let result = evaluate(devices: [device], states: [:], now: now)

            try expect(result.alerts.isEmpty)
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == nil)
            try expect(result.updatedStates[device.id]?.wasLowBattery == false)
            try expect(result.updatedStates[device.id]?.lastSeenPercentage == 20)
        }

        await runner.run("RuleEngine suppresses repeated alert during cooldown") {
            let now = fixedDate()
            let device = makeDevice(percentage: 10)
            let existingState = DeviceNotificationState(
                deviceID: device.id,
                lastNotifiedAt: now.addingTimeInterval(-120),
                wasLowBattery: true,
                lastSeenPercentage: 12,
                updatedAt: now.addingTimeInterval(-120)
            )

            let result = evaluate(devices: [device], states: [device.id: existingState], now: now)

            try expect(result.alerts.isEmpty)
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == existingState.lastNotifiedAt)
            try expect(result.updatedStates[device.id]?.lastSeenPercentage == 10)
        }

        await runner.run("RuleEngine migrates notification state when device ID changes") {
            let now = fixedDate()
            let oldID = "ioregistry:old-mouse-id"
            let device = BatteryDevice(
                id: "ioregistry:new-mouse-id",
                name: "Magic Mouse",
                kind: .peripheral,
                percentage: 10,
                isCharging: nil,
                isConnected: true,
                source: "IORegistry",
                updatedAt: now
            )
            let existingState = DeviceNotificationState(
                deviceID: oldID,
                lastNotifiedAt: now.addingTimeInterval(-120),
                wasLowBattery: true,
                lastSeenPercentage: 12,
                updatedAt: now.addingTimeInterval(-120),
                deviceName: device.name,
                deviceKind: device.kind,
                deviceSource: device.source
            )

            let result = evaluate(devices: [device], states: [oldID: existingState], now: now)

            try expect(result.alerts.isEmpty)
            try expect(result.updatedStates[oldID] == nil)
            try expect(result.updatedStates[device.id]?.deviceID == device.id)
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == existingState.lastNotifiedAt)
            try expect(result.updatedStates[device.id]?.wasLowBattery == true)
            try expect(result.updatedStates[device.id]?.lastSeenPercentage == 10)
        }

        await runner.run("RuleEngine limits unmatched ID change to one new-device alert") {
            let now = fixedDate()
            let oldID = "ioregistry:old-keyboard-id"
            let device = BatteryDevice(
                id: "ioregistry:new-keyboard-id",
                name: "Magic Keyboard",
                kind: .peripheral,
                percentage: 10,
                isCharging: nil,
                isConnected: true,
                source: "IORegistry",
                updatedAt: now
            )
            let unmatchedState = DeviceNotificationState(
                deviceID: oldID,
                lastNotifiedAt: now.addingTimeInterval(-120),
                wasLowBattery: true,
                lastSeenPercentage: 12,
                updatedAt: now.addingTimeInterval(-120),
                deviceName: "Different Keyboard",
                deviceKind: device.kind,
                deviceSource: device.source
            )

            let firstResult = evaluate(devices: [device], states: [oldID: unmatchedState], now: now)
            let secondResult = evaluate(
                devices: [device],
                states: firstResult.updatedStates,
                now: now.addingTimeInterval(120)
            )

            try expect(firstResult.alerts == [LowBatteryAlert(device: device, threshold: 20)])
            try expect(firstResult.updatedStates[oldID] == unmatchedState)
            try expect(firstResult.updatedStates[device.id]?.lastNotifiedAt == now)
            try expect(firstResult.updatedStates[device.id]?.wasLowBattery == true)
            try expect(secondResult.alerts.isEmpty)
            try expect(secondResult.updatedStates[device.id]?.lastNotifiedAt == now)
        }

        await runner.run("RuleEngine does not steal state from a visible same-named device") {
            let now = fixedDate()
            let original = BatteryDevice(
                id: "ioregistry:mouse-a",
                name: "Magic Mouse",
                kind: .peripheral,
                percentage: 80,
                isCharging: nil,
                isConnected: true,
                source: "IORegistry",
                updatedAt: now
            )
            let newcomer = BatteryDevice(
                id: "ioregistry:mouse-b",
                name: "Magic Mouse",
                kind: .peripheral,
                percentage: 10,
                isCharging: nil,
                isConnected: true,
                source: "IORegistry",
                updatedAt: now
            )
            let originalState = DeviceNotificationState(
                deviceID: original.id,
                lastNotifiedAt: now.addingTimeInterval(-120),
                wasLowBattery: true,
                lastSeenPercentage: 12,
                updatedAt: now.addingTimeInterval(-120),
                deviceName: original.name,
                deviceKind: original.kind,
                deviceSource: original.source
            )

            let result = evaluate(
                devices: [original, newcomer],
                states: [original.id: originalState],
                now: now
            )

            try expect(result.alerts == [LowBatteryAlert(device: newcomer, threshold: 20)])
            try expect(result.updatedStates[original.id]?.deviceID == original.id)
            try expect(result.updatedStates[original.id]?.lastNotifiedAt == originalState.lastNotifiedAt)
            try expect(result.updatedStates[newcomer.id]?.lastNotifiedAt == now)
        }

        await runner.run("RuleEngine skips migration when multiple orphaned states match") {
            let now = fixedDate()
            let device = BatteryDevice(
                id: "ioregistry:new-trackpad-id",
                name: "Magic Trackpad",
                kind: .peripheral,
                percentage: 10,
                isCharging: nil,
                isConnected: true,
                source: "IORegistry",
                updatedAt: now
            )
            let makeOrphanState = { (id: String) in
                DeviceNotificationState(
                    deviceID: id,
                    lastNotifiedAt: now.addingTimeInterval(-120),
                    wasLowBattery: true,
                    lastSeenPercentage: 12,
                    updatedAt: now.addingTimeInterval(-120),
                    deviceName: device.name,
                    deviceKind: device.kind,
                    deviceSource: device.source
                )
            }
            let states = [
                "ioregistry:orphan-a": makeOrphanState("ioregistry:orphan-a"),
                "ioregistry:orphan-b": makeOrphanState("ioregistry:orphan-b")
            ]

            let result = evaluate(devices: [device], states: states, now: now)

            try expect(result.alerts == [LowBatteryAlert(device: device, threshold: 20)])
            try expect(result.updatedStates["ioregistry:orphan-a"] != nil)
            try expect(result.updatedStates["ioregistry:orphan-b"] != nil)
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == now)
        }

        await runner.run("RuleEngine drops notification states unseen beyond retention") {
            let now = fixedDate()
            let device = makeDevice(percentage: 80)
            let staleState = DeviceNotificationState(
                deviceID: "ioregistry:long-gone",
                lastNotifiedAt: nil,
                wasLowBattery: false,
                lastSeenPercentage: 50,
                updatedAt: now.addingTimeInterval(-RuleEngine.staleStateRetentionInterval - 3_600),
                deviceName: "Long Gone Mouse",
                deviceKind: .peripheral,
                deviceSource: "IORegistry"
            )
            let recentState = DeviceNotificationState(
                deviceID: "ioregistry:recently-seen",
                lastNotifiedAt: nil,
                wasLowBattery: false,
                lastSeenPercentage: 50,
                updatedAt: now.addingTimeInterval(-3_600),
                deviceName: "Recently Seen Mouse",
                deviceKind: .peripheral,
                deviceSource: "IORegistry"
            )

            let result = evaluate(
                devices: [device],
                states: [
                    staleState.deviceID: staleState,
                    recentState.deviceID: recentState
                ],
                now: now
            )

            try expect(result.updatedStates[staleState.deviceID] == nil)
            try expect(result.updatedStates[recentState.deviceID] != nil)
        }

        await runner.run("RuleEngine sends alert after cooldown window") {
            let now = fixedDate()
            let device = makeDevice(percentage: 10)
            let existingState = DeviceNotificationState(
                deviceID: device.id,
                lastNotifiedAt: now.addingTimeInterval(-7_200),
                wasLowBattery: true,
                lastSeenPercentage: 12,
                updatedAt: now.addingTimeInterval(-7_200)
            )

            let result = evaluate(devices: [device], states: [device.id: existingState], now: now)

            try expect(result.alerts.count == 1)
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == now)
        }

        await runner.run("RuleEngine resets state at recovery threshold") {
            let now = fixedDate()
            let device = makeDevice(percentage: 25)
            let existingState = DeviceNotificationState(
                deviceID: device.id,
                lastNotifiedAt: now.addingTimeInterval(-100),
                wasLowBattery: true,
                lastSeenPercentage: 12,
                updatedAt: now.addingTimeInterval(-100)
            )

            let result = evaluate(devices: [device], states: [device.id: existingState], now: now)

            try expect(result.alerts.isEmpty)
            try expect(result.updatedStates[device.id]?.wasLowBattery == false)
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == existingState.lastNotifiedAt)
        }

        await runner.run("RuleEngine keeps low state below recovery threshold") {
            let now = fixedDate()
            let device = makeDevice(percentage: 24)
            let existingState = DeviceNotificationState(
                deviceID: device.id,
                lastNotifiedAt: now.addingTimeInterval(-100),
                wasLowBattery: true,
                lastSeenPercentage: 12,
                updatedAt: now.addingTimeInterval(-100)
            )

            let result = evaluate(devices: [device], states: [device.id: existingState], now: now)

            try expect(result.alerts.isEmpty)
            try expect(result.updatedStates[device.id]?.wasLowBattery == true)
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == existingState.lastNotifiedAt)
            try expect(result.updatedStates[device.id]?.lastSeenPercentage == 24)
        }

        await runner.run("RuleEngine alerts immediately after recovery and new low transition") {
            let now = fixedDate()
            let device = makeDevice(percentage: 10)
            let recoveredState = DeviceNotificationState(
                deviceID: device.id,
                lastNotifiedAt: now.addingTimeInterval(-120),
                wasLowBattery: false,
                lastSeenPercentage: 25,
                updatedAt: now.addingTimeInterval(-60)
            )

            let result = evaluate(devices: [device], states: [device.id: recoveredState], now: now)

            try expect(result.alerts == [LowBatteryAlert(device: device, threshold: 20)])
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == now)
            try expect(result.updatedStates[device.id]?.wasLowBattery == true)
        }

        await runner.run("RuleEngine suppresses alert while charging") {
            let now = fixedDate()
            let device = makeDevice(percentage: 10, isCharging: true)
            let result = evaluate(devices: [device], states: [:], now: now)

            try expect(result.alerts.isEmpty)
            try expect(result.updatedStates[device.id]?.wasLowBattery == true)
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == nil)
        }

        await runner.run("RuleEngine suppresses alert for charging internal battery") {
            let now = fixedDate()
            let device = makeDevice(percentage: 10, isCharging: true, kind: .internalBattery)
            let result = evaluate(devices: [device], states: [:], now: now)

            try expect(result.alerts.isEmpty)
            try expect(result.updatedStates[device.id]?.wasLowBattery == true)
            try expect(result.updatedStates[device.id]?.lastNotifiedAt == nil)
            try expect(result.updatedStates[device.id]?.deviceKind == .internalBattery)
        }

        await runner.run("RuleEngine alerts when charging state is unknown") {
            let now = fixedDate()
            let device = makeDevice(percentage: 10, isCharging: nil)
            let result = evaluate(devices: [device], states: [:], now: now)

            try expect(result.alerts.count == 1)
        }

        await runner.run("LowBatteryNotificationPayload matches notification copy") {
            let device = makeNamedDevice(
                name: "Magic Mouse",
                percentage: 14,
                source: "IORegistry",
                stableIdentifier: "04-4b-ed-bc-d9-8b"
            )
            let payload = LowBatteryNotificationPayload.make(
                for: LowBatteryAlert(device: device, threshold: 20)
            )

            try expect(payload.identifier == "battery-low-\(device.id)")
            try expect(payload.title == "Magic Mouse 电量低")
            try expect(payload.body == "当前电量 14%，请及时充电。")
            try expect(payload.deviceIDs == [device.id])
            try expect(payload.deviceFingerprints == [MonitorSettings.deviceFingerprint(for: device)])
        }

        await runner.run("LowBatteryNotificationPayload merges simultaneous alerts") {
            let keyboard = makeNamedDevice(
                name: "Magic Keyboard",
                percentage: 12,
                source: "Test",
                stableIdentifier: "keyboard"
            )
            let mouse = makeNamedDevice(
                name: "Magic Mouse",
                percentage: 14,
                source: "Test",
                stableIdentifier: "mouse"
            )
            let payload = try require(LowBatteryNotificationPayload.make(for: [
                LowBatteryAlert(device: mouse, threshold: 20),
                LowBatteryAlert(device: keyboard, threshold: 20)
            ]))

            try expect(payload.identifier == "battery-low-batch-2-test-keyboard-test-mouse")
            try expect(payload.title == "2 个设备电量低")
            try expect(payload.body == "Magic Keyboard 12%、Magic Mouse 14%，请及时充电。")
            try expect(payload.deviceIDs == [keyboard.id, mouse.id])
            try expect(payload.deviceFingerprints == [
                MonitorSettings.deviceFingerprint(for: keyboard),
                MonitorSettings.deviceFingerprint(for: mouse)
            ])
        }

        await runner.run("LowBatteryNotificationReportRenderer renders payload evidence") {
            let snapshot = BatterySnapshot(
                devices: [
                    makeNamedDevice(
                        name: "Magic Keyboard",
                        percentage: 22,
                        source: "IORegistry",
                        stableIdentifier: "keyboard"
                    ),
                    makeNamedDevice(
                        name: "Magic Mouse",
                        percentage: 93,
                        source: "IORegistry",
                        stableIdentifier: "mouse"
                    ),
                    BatteryDevice(
                        id: "test:headphones",
                        name: "Charging Headphones",
                        kind: .peripheral,
                        percentage: 12,
                        isCharging: true,
                        isConnected: true,
                        source: "Test",
                        updatedAt: fixedDate()
                    )
                ],
                updatedAt: fixedDate()
            )
            let report = LowBatteryNotificationReportRenderer.render(
                snapshot: snapshot,
                threshold: 100,
                renderedAt: fixedDate().addingTimeInterval(10)
            )

            try expect(report.contains("Low battery notification report"))
            try expect(report.contains("Low battery threshold: 100%"))
            try expect(report.contains("Cooldown state: empty"))
            try expect(report.contains("Alert count: 2"))
            try expect(report.contains("Category identifier: \(LowBatteryNotificationAction.categoryIdentifier)"))
            try expect(report.contains("\(LowBatteryNotificationAction.snoozeIdentifier)=\(LowBatteryNotificationAction.snoozeTitle)"))
            try expect(report.contains("\(LowBatteryNotificationAction.ignoreDeviceIdentifier)=\(LowBatteryNotificationAction.ignoreDeviceTitle)"))
            try expect(report.contains("Payload title: 2 个设备电量低"))
            try expect(report.contains("Payload body: Magic Keyboard 22%、Magic Mouse 93%，请及时充电。"))
            try expect(report.contains("- Magic Keyboard | 22% | IORegistry | ioregistry:keyboard"))
            try expect(report.contains("- Magic Mouse | 93% | IORegistry | ioregistry:mouse"))
            try expect(!report.contains("- Charging Headphones | 12%"))
        }

        await runner.run("UserNotificationService registers low battery actions") {
            let center = SpyUserNotificationCenter()
            let service = UserNotificationService(center: center)

            service.registerNotificationActions()

            let category = try require(center.categories.first)
            let actions = category.actions
            try expect(center.categories.count == 1)
            try expect(category.identifier == LowBatteryNotificationAction.categoryIdentifier)
            try expect(actions.map(\.identifier) == [
                LowBatteryNotificationAction.snoozeIdentifier,
                LowBatteryNotificationAction.ignoreDeviceIdentifier
            ])
            try expect(actions.map(\.title) == [
                LowBatteryNotificationAction.snoozeTitle,
                LowBatteryNotificationAction.ignoreDeviceTitle
            ])
        }

        await runner.run("UserNotificationService submits low battery request") {
            let center = SpyUserNotificationCenter()
            let service = UserNotificationService(center: center)
            let device = makeNamedDevice(
                name: "Magic Mouse",
                percentage: 14,
                source: "IORegistry",
                stableIdentifier: "04-4b-ed-bc-d9-8b"
            )

            let authorizationGranted = await service.requestAuthorization()
            let status = await service.authorizationStatus()
            try await service.sendLowBatteryAlert(LowBatteryAlert(device: device, threshold: 20))

            try expect(authorizationGranted)
            try expect(center.authorizationRequestOptions?.contains(.alert) == true)
            try expect(center.authorizationRequestOptions?.contains(.sound) == true)
            try expect(status == .authorized)
            try expect(center.requests.count == 1)
            try expect(center.requests[0].identifier == "battery-low-\(device.id)")
            try expect(center.requests[0].content.categoryIdentifier == LowBatteryNotificationAction.categoryIdentifier)
            try expect(center.requests[0].content.title == "Magic Mouse 电量低")
            try expect(center.requests[0].content.body == "当前电量 14%，请及时充电。")
            try expect(center.requests[0].content.userInfo[LowBatteryNotificationAction.deviceIDsUserInfoKey] as? [String] == [device.id])
            try expect(center.requests[0].content.userInfo[LowBatteryNotificationAction.deviceFingerprintsUserInfoKey] as? [String] == [MonitorSettings.deviceFingerprint(for: device)])
            try expect(center.requests[0].content.sound != nil)
        }

        await runner.run("UserNotificationService submits merged low battery request") {
            let center = SpyUserNotificationCenter()
            let service = UserNotificationService(center: center)
            let keyboard = makeNamedDevice(
                name: "Magic Keyboard",
                percentage: 12,
                source: "Test",
                stableIdentifier: "keyboard"
            )
            let mouse = makeNamedDevice(
                name: "Magic Mouse",
                percentage: 14,
                source: "Test",
                stableIdentifier: "mouse"
            )

            try await service.sendLowBatteryAlerts([
                LowBatteryAlert(device: mouse, threshold: 20),
                LowBatteryAlert(device: keyboard, threshold: 20)
            ])

            try expect(center.requests.count == 1)
            try expect(center.requests[0].identifier == "battery-low-batch-2-test-keyboard-test-mouse")
            try expect(center.requests[0].content.categoryIdentifier == LowBatteryNotificationAction.categoryIdentifier)
            try expect(center.requests[0].content.title == "2 个设备电量低")
            try expect(center.requests[0].content.body == "Magic Keyboard 12%、Magic Mouse 14%，请及时充电。")
            try expect(center.requests[0].content.userInfo[LowBatteryNotificationAction.deviceIDsUserInfoKey] as? [String] == [keyboard.id, mouse.id])
            try expect(center.requests[0].content.userInfo[LowBatteryNotificationAction.deviceFingerprintsUserInfoKey] as? [String] == [
                MonitorSettings.deviceFingerprint(for: keyboard),
                MonitorSettings.deviceFingerprint(for: mouse)
            ])
            try expect(center.requests[0].content.sound != nil)
        }

        await runner.run("LowBatteryNotificationActionHandler ignores devices from action payload") {
            let directory = temporaryDirectory()
            let settingsStore = SettingsStore(directoryURL: directory)
            let handler = LowBatteryNotificationActionHandler(settingsStore: settingsStore)
            let keyboard = makeNamedDevice(
                name: "Magic Keyboard",
                percentage: 12,
                source: "Test",
                stableIdentifier: "keyboard"
            )
            let payload = LowBatteryNotificationPayload.make(
                for: LowBatteryAlert(device: keyboard, threshold: 20)
            )

            let result = try handler.handle(
                actionIdentifier: LowBatteryNotificationAction.ignoreDeviceIdentifier,
                userInfo: payload.userInfo
            )
            let settings = settingsStore.load()

            try expect(result == .ignoredDevices(
                deviceIDs: [keyboard.id],
                deviceFingerprints: [MonitorSettings.deviceFingerprint(for: keyboard)]
            ))
            try expect(settings.ignoredDeviceIDs == [keyboard.id])
            try expect(settings.ignoredDeviceFingerprints == [MonitorSettings.deviceFingerprint(for: keyboard)])
        }

        await runner.run("LowBatteryNotificationActionHandler snoozes without changing ignored devices") {
            let directory = temporaryDirectory()
            let settingsStore = SettingsStore(directoryURL: directory)
            let handler = LowBatteryNotificationActionHandler(settingsStore: settingsStore)
            let device = makeNamedDevice(
                name: "Magic Mouse",
                percentage: 14,
                source: "Test",
                stableIdentifier: "mouse"
            )
            let payload = LowBatteryNotificationPayload.make(
                for: LowBatteryAlert(device: device, threshold: 20)
            )

            let result = try handler.handle(
                actionIdentifier: LowBatteryNotificationAction.snoozeIdentifier,
                userInfo: payload.userInfo
            )
            let settings = settingsStore.load()

            try expect(result == .snoozed(deviceIDs: [device.id]))
            try expect(settings.ignoredDeviceIDs.isEmpty)
            try expect(settings.ignoredDeviceFingerprints.isEmpty)
        }

        await runner.run("NotificationPermissionDisplayModel formats status for UI") {
            let denied = NotificationPermissionDisplayModel(status: .denied)
            let authorized = NotificationPermissionDisplayModel(status: .authorized)
            let notDetermined = NotificationPermissionDisplayModel(status: .notDetermined)
            let unknown = NotificationPermissionDisplayModel(status: .unknown)

            try expect(denied.statusText == "已关闭")
            try expect(denied.warningText == "通知权限已关闭")
            try expect(denied.settingsActionTitle == "打开系统设置")
            try expect(denied.settingsURL == SystemSettingsDestination.notifications)
            try expect(denied.symbolName == "bell.slash")
            try expect(denied.isAlertingDisabled)

            try expect(authorized.statusText == "已允许")
            try expect(authorized.warningText == nil)
            try expect(authorized.settingsActionTitle == nil)
            try expect(authorized.settingsURL == nil)
            try expect(authorized.symbolName == "bell")
            try expect(!authorized.isAlertingDisabled)

            try expect(notDetermined.statusText == "未请求")
            try expect(notDetermined.warningText == nil)
            try expect(notDetermined.settingsActionTitle == nil)
            try expect(!notDetermined.isAlertingDisabled)

            try expect(unknown.statusText == "未知")
            try expect(unknown.warningText == "通知权限状态未知")
            try expect(unknown.settingsActionTitle == "打开系统设置")
            try expect(unknown.settingsURL == SystemSettingsDestination.notifications)
            try expect(unknown.symbolName == "questionmark.circle")
        }

        await runner.run("NotificationPermissionDisplayModel guides blocked statuses to system settings") {
            try expect(NotificationPermissionDisplayModel(status: .denied).settingsActionTitle == "打开系统设置")
            try expect(NotificationPermissionDisplayModel(status: .denied).settingsURL == SystemSettingsDestination.notifications)
            try expect(NotificationPermissionDisplayModel(status: .unknown).settingsActionTitle == "打开系统设置")
            try expect(NotificationPermissionDisplayModel(status: .unknown).settingsURL == SystemSettingsDestination.notifications)
            try expect(NotificationPermissionDisplayModel(status: .authorized).settingsActionTitle == nil)
            try expect(NotificationPermissionDisplayModel(status: .authorized).settingsURL == nil)
            try expect(NotificationPermissionDisplayModel(status: .notDetermined).settingsActionTitle == nil)
            try expect(NotificationPermissionDisplayModel(status: .provisional).settingsActionTitle == nil)
            try expect(NotificationPermissionDisplayModel(status: .ephemeral).settingsActionTitle == nil)
        }

        await runner.run("Permission display models target specific system settings panes") {
            try expect(SystemSettingsDestination.app.path == "/System/Applications/System Settings.app")
            try expect(SystemSettingsDestination.notifications.scheme == "x-apple.systempreferences")
            try expect(SystemSettingsDestination.bluetooth.scheme == "x-apple.systempreferences")
            try expect(NotificationPermissionDisplayModel(status: .denied).settingsURL == SystemSettingsDestination.notifications)
            try expect(BluetoothPermissionDisplayModel(status: .denied).settingsURL == SystemSettingsDestination.bluetooth)
            try expect(BluetoothPermissionDisplayModel(status: .restricted).settingsURL == SystemSettingsDestination.bluetooth)
        }

        await runner.run("BluetoothPermissionDisplayModel formats status for UI") {
            let denied = BluetoothPermissionDisplayModel(status: .denied)
            let restricted = BluetoothPermissionDisplayModel(status: .restricted)
            let authorized = BluetoothPermissionDisplayModel(status: .authorized)
            let notDetermined = BluetoothPermissionDisplayModel(status: .notDetermined)
            let unknown = BluetoothPermissionDisplayModel(status: .unknown)

            try expect(denied.statusText == "已关闭")
            try expect(denied.warningText == "蓝牙权限已关闭，部分外设电量可能不可见")
            try expect(denied.settingsActionTitle == "打开系统设置")
            try expect(denied.settingsURL == SystemSettingsDestination.bluetooth)
            try expect(denied.symbolName == "antenna.radiowaves.left.and.right.slash")
            try expect(denied.isBluetoothBatteryLimited)

            try expect(restricted.statusText == "受限制")
            try expect(restricted.warningText == "蓝牙权限受系统限制，部分外设电量可能不可见")
            try expect(restricted.settingsActionTitle == "打开系统设置")
            try expect(restricted.settingsURL == SystemSettingsDestination.bluetooth)
            try expect(restricted.isBluetoothBatteryLimited)

            try expect(authorized.statusText == "已允许")
            try expect(authorized.warningText == nil)
            try expect(authorized.settingsActionTitle == nil)
            try expect(authorized.settingsURL == nil)
            try expect(!authorized.isBluetoothBatteryLimited)

            try expect(notDetermined.statusText == "未请求")
            try expect(notDetermined.warningText == nil)
            try expect(notDetermined.settingsActionTitle == nil)
            try expect(!notDetermined.isBluetoothBatteryLimited)

            try expect(unknown.statusText == "未知")
            try expect(unknown.warningText == "蓝牙权限状态未知，部分外设电量可能不可见")
            try expect(unknown.settingsActionTitle == "打开系统设置")
            try expect(unknown.settingsURL == SystemSettingsDestination.bluetooth)
            try expect(unknown.symbolName == "questionmark.circle")
        }

        await runner.run("MenuBarDeviceRowModel formats device row display") {
            let internalBattery = MenuBarDeviceRowModel(
                device: makeDevice(percentage: 80, kind: .internalBattery),
                threshold: 20
            )
            let lowPeripheral = MenuBarDeviceRowModel(
                device: makeDevice(percentage: 14, isCharging: nil, kind: .peripheral),
                threshold: 20
            )
            let chargingPeripheral = MenuBarDeviceRowModel(
                device: makeDevice(percentage: 10, isCharging: true, kind: .peripheral),
                threshold: 20
            )
            let disconnectedPeripheral = MenuBarDeviceRowModel(
                device: makeDevice(percentage: 10, isConnected: false, kind: .peripheral),
                threshold: 20
            )
            let ups = MenuBarDeviceRowModel(
                device: makeDevice(percentage: 50, kind: .ups),
                threshold: 20
            )
            let unknown = MenuBarDeviceRowModel(
                device: makeDevice(percentage: 50, kind: .unknown),
                threshold: 20
            )

            try expect(internalBattery.name == "Test Device")
            try expect(internalBattery.percentageText == "80%")
            try expect(internalBattery.statusText == "未充电")
            try expect(internalBattery.symbolName == "laptopcomputer")
            try expect(!internalBattery.isLowBattery)

            try expect(lowPeripheral.percentageText == "14%")
            try expect(lowPeripheral.statusText == "已连接")
            try expect(lowPeripheral.symbolName == "battery.75percent")
            try expect(lowPeripheral.isLowBattery)

            try expect(chargingPeripheral.statusText == "充电中")
            try expect(!chargingPeripheral.isLowBattery)
            try expect(chargingPeripheral.isCharging)
            try expect(!lowPeripheral.isCharging)
            try expect(!disconnectedPeripheral.isCharging)

            try expect(disconnectedPeripheral.statusText == "已断开")
            try expect(!disconnectedPeripheral.isLowBattery)

            try expect(ups.symbolName == "powerplug")
            try expect(unknown.symbolName == "battery.50")
        }

        await runner.run("MenuBarSnapshotSummaryModel formats last update text") {
            let snapshot = BatterySnapshot(
                devices: [
                    makeDevice(percentage: 80, kind: .internalBattery),
                    makeDevice(percentage: 22, kind: .peripheral)
                ],
                updatedAt: fixedDate()
            )
            let summary = MenuBarSnapshotSummaryModel(snapshot: snapshot, timeText: "12:34:56")
            let emptySummary = MenuBarSnapshotSummaryModel(snapshot: .empty(updatedAt: fixedDate()), timeText: "00:00:00")

            try expect(summary.lastUpdatedText == "更新于 12:34:56")
            try expect(summary.deviceCount == 2)
            try expect(!summary.isEmpty)
            try expect(emptySummary.lastUpdatedText == "更新于 00:00:00")
            try expect(emptySummary.deviceCount == 0)
            try expect(emptySummary.isEmpty)
        }

        await runner.run("IgnoredDeviceListModel exposes unavailable ignored devices") {
            let visibleKeyboard = makeNamedDevice(
                name: "Magic Keyboard",
                percentage: 22,
                source: "IORegistry",
                stableIdentifier: "38-09-fb-30-9f-78"
            )
            let staleID = "ioregistry:old-keyboard"
            let staleFingerprint = "old mouse|peripheral|ioregistry"
            let settings = MonitorSettings(
                ignoredDeviceIDs: [visibleKeyboard.id, staleID],
                ignoredDeviceFingerprints: [
                    MonitorSettings.deviceFingerprint(for: visibleKeyboard),
                    staleFingerprint
                ]
            )

            let model = IgnoredDeviceListModel(settings: settings, visibleDevices: [visibleKeyboard])

            try expect(model.unavailableItems == [
                IgnoredDeviceListItem(
                    source: .deviceID,
                    value: staleID,
                    title: "未连接设备",
                    detailText: "ID: \(staleID)"
                ),
                IgnoredDeviceListItem(
                    source: .deviceFingerprint,
                    value: staleFingerprint,
                    title: "old mouse",
                    detailText: "指纹: \(staleFingerprint)"
                )
            ])
        }

        await runner.run("RuleEngine ignores configured devices") {
            let now = fixedDate()
            let device = makeDevice(percentage: 10)
            let settings = MonitorSettings(ignoredDeviceIDs: [device.id])
            let snapshot = BatterySnapshot(devices: [device], updatedAt: now)
            let result = RuleEngine(settings: settings).evaluate(snapshot: snapshot, states: [:], now: now)

            try expect(result.alerts.isEmpty)
            try expect(result.updatedStates[device.id]?.lastSeenPercentage == 10)
        }

        await runner.run("RuleEngine ignores configured devices when ID changes but fingerprint matches") {
            let now = fixedDate()
            let originalDevice = makeNamedDevice(
                name: "Magic Keyboard",
                percentage: 10,
                source: "IORegistry",
                stableIdentifier: "old-keyboard-id"
            )
            let reconnectedDevice = makeNamedDevice(
                name: originalDevice.name,
                percentage: 10,
                source: originalDevice.source,
                stableIdentifier: "new-keyboard-id"
            )
            let settings = MonitorSettings(
                ignoredDeviceIDs: [originalDevice.id],
                ignoredDeviceFingerprints: [MonitorSettings.deviceFingerprint(for: originalDevice)]
            )
            let snapshot = BatterySnapshot(devices: [reconnectedDevice], updatedAt: now)
            let result = RuleEngine(settings: settings).evaluate(snapshot: snapshot, states: [:], now: now)

            try expect(originalDevice.id != reconnectedDevice.id)
            try expect(settings.isIgnored(reconnectedDevice))
            try expect(result.alerts.isEmpty)
            try expect(result.updatedStates[reconnectedDevice.id]?.lastSeenPercentage == 10)
            try expect(result.updatedStates[reconnectedDevice.id]?.lastNotifiedAt == nil)
        }

        await runner.run("RuleEngine ignores disconnected devices") {
            let now = fixedDate()
            let device = makeDevice(percentage: 10, isConnected: false)
            let result = evaluate(devices: [device], states: [:], now: now)

            try expect(result.alerts.isEmpty)
            try expect(result.updatedStates[device.id] == nil)
        }

        await runner.run("SharedBatteryStore writes and reads snapshot") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let snapshot = BatterySnapshot(devices: [makeDevice(percentage: 50)], updatedAt: Date(timeIntervalSince1970: 100))

            try store.writeSnapshot(snapshot)

            try expect(try store.readSnapshot() == snapshot)
            try expect(FileManager.default.fileExists(atPath: store.snapshotFileURL().path))
        }

        await runner.run("SharedBatteryStore replaces snapshot without leaving temporary file") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let oldSnapshot = BatterySnapshot(
                devices: [makeDevice(percentage: 80, kind: .internalBattery)],
                updatedAt: Date(timeIntervalSince1970: 100)
            )
            let newSnapshot = BatterySnapshot(
                devices: [makeNamedDevice(name: "Magic Keyboard", percentage: 22, source: "IORegistry", stableIdentifier: "keyboard")],
                updatedAt: Date(timeIntervalSince1970: 200)
            )
            let temporarySnapshotURL = directory.appendingPathComponent(".\(BatteryMonitorConstants.snapshotFileName).tmp")

            try store.writeSnapshot(oldSnapshot)
            try store.writeSnapshot(newSnapshot)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rawData = try Data(contentsOf: store.snapshotFileURL())
            let decoded = try decoder.decode(BatterySnapshot.self, from: rawData)

            try expect(decoded == newSnapshot)
            try expect(!FileManager.default.fileExists(atPath: temporarySnapshotURL.path))
        }

        await runner.run("SharedBatteryStore writes and reads notification states") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let state = DeviceNotificationState(
                deviceID: "device-1",
                lastNotifiedAt: Date(timeIntervalSince1970: 200),
                wasLowBattery: true,
                lastSeenPercentage: 12,
                updatedAt: Date(timeIntervalSince1970: 201)
            )

            try store.writeNotificationStates(["device-1": state])

            try expect(try store.readNotificationStates() == ["device-1": state])
            try expect(FileManager.default.fileExists(atPath: store.notificationStateFileURL().path))
        }

        await runner.run("SharedBatteryStore replaces notification states without leaving temporary file") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let oldState = DeviceNotificationState(
                deviceID: "device-1",
                lastNotifiedAt: Date(timeIntervalSince1970: 100),
                wasLowBattery: true,
                lastSeenPercentage: 10,
                updatedAt: Date(timeIntervalSince1970: 101),
                deviceName: "Magic Mouse",
                deviceKind: .peripheral,
                deviceSource: "IORegistry"
            )
            let newState = DeviceNotificationState(
                deviceID: "device-1",
                lastNotifiedAt: Date(timeIntervalSince1970: 200),
                wasLowBattery: false,
                lastSeenPercentage: 26,
                updatedAt: Date(timeIntervalSince1970: 201),
                deviceName: "Magic Mouse",
                deviceKind: .peripheral,
                deviceSource: "IORegistry"
            )
            let temporaryStateURL = directory.appendingPathComponent(".\(BatteryMonitorConstants.notificationStateFileName).tmp")

            try store.writeNotificationStates(["device-1": oldState])
            try store.writeNotificationStates(["device-1": newState])

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rawData = try Data(contentsOf: store.notificationStateFileURL())
            let decoded = try decoder.decode([String: DeviceNotificationState].self, from: rawData)

            try expect(decoded == ["device-1": newState])
            try expect(!FileManager.default.fileExists(atPath: temporaryStateURL.path))
        }

        await runner.run("SharedBatteryStore reads legacy notification state JSON") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let legacyJSON = """
            {
              "device-1": {
                "deviceID": "device-1",
                "lastNotifiedAt": "1970-01-01T00:03:20Z",
                "lastSeenPercentage": 12,
                "updatedAt": "1970-01-01T00:03:21Z",
                "wasLowBattery": true
              }
            }
            """

            try legacyJSON.write(to: store.notificationStateFileURL(), atomically: true, encoding: .utf8)

            let states = try store.readNotificationStates()
            let state = try require(states["device-1"], "missing legacy notification state")

            try expect(state.deviceID == "device-1")
            try expect(state.lastNotifiedAt == Date(timeIntervalSince1970: 200))
            try expect(state.lastSeenPercentage == 12)
            try expect(state.updatedAt == Date(timeIntervalSince1970: 201))
            try expect(state.wasLowBattery)
            try expect(state.deviceName == nil)
            try expect(state.deviceKind == nil)
            try expect(state.deviceSource == nil)
        }

        await runner.run("SettingsStore returns defaults when missing") {
            let store = SettingsStore(fileURL: temporaryDirectory().appendingPathComponent("settings.json"))

            try expect(store.load() == .default)
        }

        await runner.run("SettingsStore returns defaults for invalid JSON") {
            let fileURL = temporaryDirectory().appendingPathComponent("settings.json")
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "{not valid json".write(to: fileURL, atomically: true, encoding: .utf8)

            let store = SettingsStore(fileURL: fileURL)

            try expect(store.load() == .default)
        }

        await runner.run("SettingsStore reads legacy settings without ignored fingerprints") {
            let fileURL = temporaryDirectory().appendingPathComponent("settings.json")
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let legacyJSON = """
            {
              "ignoredDeviceIDs" : [
                "device-1"
              ],
              "lowBatteryThreshold" : 15,
              "pollingInterval" : 600,
              "recoveryMargin" : 6,
              "reminderCooldown" : 3600
            }
            """
            try legacyJSON.write(to: fileURL, atomically: true, encoding: .utf8)

            let settings = SettingsStore(fileURL: fileURL).load()

            try expect(settings.lowBatteryThreshold == 15)
            try expect(settings.recoveryMargin == 6)
            try expect(settings.pollingInterval == 600)
            try expect(settings.reminderCooldown == 3_600)
            try expect(!settings.launchAtLogin)
            try expect(settings.ignoredDeviceIDs == ["device-1"])
            try expect(settings.ignoredDeviceFingerprints.isEmpty)
        }

        await runner.run("SettingsStore saves and loads settings") {
            let store = SettingsStore(fileURL: temporaryDirectory().appendingPathComponent("settings.json"))
            let settings = MonitorSettings(
                lowBatteryThreshold: 15,
                recoveryMargin: 6,
                pollingInterval: 600,
                reminderCooldown: 3_600,
                launchAtLogin: true,
                ignoredDeviceIDs: ["device-1"],
                ignoredDeviceFingerprints: ["magic-keyboard|peripheral|ioregistry"]
            )

            try store.save(settings)

            try expect(store.load() == settings)
        }

        await runner.run("SettingsStore replaces settings without leaving temporary file") {
            let fileURL = temporaryDirectory().appendingPathComponent("settings.json")
            let temporarySettingsURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(BatteryMonitorConstants.settingsFileName).tmp")
            let store = SettingsStore(fileURL: fileURL)
            let oldSettings = MonitorSettings(lowBatteryThreshold: 30, pollingInterval: 300)
            let newSettings = MonitorSettings(
                lowBatteryThreshold: 15,
                recoveryMargin: 6,
                pollingInterval: 600,
                reminderCooldown: 3_600,
                launchAtLogin: true,
                ignoredDeviceIDs: ["device-1"]
            )

            try store.save(oldSettings)
            try store.save(newSettings)

            try expect(store.load() == newSettings)
            try expect(!FileManager.default.fileExists(atPath: temporarySettingsURL.path))
        }

        await runner.run("SettingsReportRenderer renders persisted settings impact") {
            let ignoredDevice = makeNamedDevice(
                name: "Magic Keyboard",
                percentage: 12,
                source: "IORegistry",
                stableIdentifier: "38-09-fb-30-9f-78"
            )
            let lowDevice = makeNamedDevice(
                name: "Magic Mouse",
                percentage: 14,
                source: "IORegistry",
                stableIdentifier: "04-4b-ed-bc-d9-8b"
            )
            let normalDevice = makeNamedDevice(
                name: "InternalBattery-0",
                percentage: 80,
                source: "IOKit",
                stableIdentifier: "mac",
                kind: .internalBattery
            )
            let settings = MonitorSettings(
                lowBatteryThreshold: 20,
                recoveryMargin: 5,
                pollingInterval: 180,
                reminderCooldown: 7_200,
                launchAtLogin: true,
                ignoredDeviceIDs: [ignoredDevice.id],
                ignoredDeviceFingerprints: [MonitorSettings.deviceFingerprint(for: ignoredDevice)]
            )
            let snapshot = BatterySnapshot(
                devices: [ignoredDevice, lowDevice, normalDevice],
                updatedAt: fixedDate()
            )

            let report = SettingsReportRenderer.render(
                settings: settings,
                snapshot: snapshot,
                renderedAt: fixedDate()
            )

            try expect(report.contains("Settings report"))
            try expect(report.contains("Low battery threshold: 20%"))
            try expect(report.contains("Recovery threshold: 25%"))
            try expect(report.contains("Polling interval: 180s"))
            try expect(report.contains("Reminder cooldown: 7200s"))
            try expect(report.contains("Launch at login preference: true"))
            try expect(report.contains("Ignored device IDs: \(ignoredDevice.id)"))
            try expect(report.contains("Ignored device fingerprints: \(MonitorSettings.deviceFingerprint(for: ignoredDevice))"))
            try expect(report.contains("Snapshot devices: 3"))
            try expect(report.contains("- Magic Keyboard | 12% | macOS not reported | ignored | \(ignoredDevice.id)"))
            try expect(report.contains("- Magic Mouse | 14% | macOS not reported | low under threshold | \(lowDevice.id)"))
            try expect(report.contains("- InternalBattery-0 | 80% | macOS not reported | recovered | \(normalDevice.id)"))
        }

        await runner.run("SettingsBackedLoginItemService persists launch at login preference") {
            let directory = temporaryDirectory()
            let settingsStore = SettingsStore(directoryURL: directory)
            let controller = SpyLoginItemController(isEnabled: false)
            let systemService = MainAppLoginItemService(loginItem: controller)
            let service = SettingsBackedLoginItemService(
                loginItemService: systemService,
                settingsStore: settingsStore
            )

            try service.setEnabled(true)
            try expect(service.isEnabled())
            try expect(settingsStore.load().launchAtLogin)

            try service.setEnabled(false)
            try expect(!service.isEnabled())
            try expect(!settingsStore.load().launchAtLogin)
        }

        await runner.run("MainAppLoginItemService toggles login item controller") {
            let controller = SpyLoginItemController(isEnabled: false)
            let service = MainAppLoginItemService(loginItem: controller)

            try expect(!service.isEnabled())

            try service.setEnabled(true)
            try expect(service.isEnabled())
            try expect(controller.registerCount == 1)
            try expect(controller.unregisterCount == 0)

            try service.setEnabled(true)
            try expect(controller.registerCount == 1)

            try service.setEnabled(false)
            try expect(!service.isEnabled())
            try expect(controller.unregisterCount == 1)

            try service.setEnabled(false)
            try expect(controller.unregisterCount == 1)
        }

        await runner.run("MonitorEngine refresh reads, writes, alerts, and reloads widget") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let settingsStore = SettingsStore(directoryURL: directory)
            try settingsStore.save(.default)

            let device = makeDevice(percentage: 10)
            let reader = StubBatteryReader(devices: [device])
            let notifier = SpyNotificationService()
            let widgetReloader = SpyWidgetReloader()
            let engine = MonitorEngine(
                reader: reader,
                store: store,
                settingsStore: settingsStore,
                notifier: notifier,
                widgetReloader: widgetReloader
            )
            let now = Date(timeIntervalSince1970: 300)
            let expectedDevice = BatteryDevice(
                id: device.id,
                name: device.name,
                kind: device.kind,
                percentage: device.percentage,
                isCharging: device.isCharging,
                isConnected: device.isConnected,
                source: device.source,
                updatedAt: now
            )

            let result = try await engine.refresh(now: now)
            let sentAlerts = await notifier.alerts()

            try expect(result.snapshot.devices == [expectedDevice])
            try expect(result.alerts.count == 1)
            try expect(sentAlerts == [LowBatteryAlert(device: expectedDevice, threshold: 20)])
            try expect(widgetReloader.reloadCount == 1)
            try expect(try store.readSnapshot() == BatterySnapshot(devices: [expectedDevice], updatedAt: now))
            try expect(try store.readNotificationStates()[device.id]?.lastNotifiedAt == now)
        }

        await runner.run("MonitorEngine sends simultaneous low battery alerts as one batch") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let settingsStore = SettingsStore(directoryURL: directory)
            try settingsStore.save(.default)

            let keyboard = makeNamedDevice(
                name: "Magic Keyboard",
                percentage: 12,
                source: "Test",
                stableIdentifier: "keyboard"
            )
            let mouse = makeNamedDevice(
                name: "Magic Mouse",
                percentage: 14,
                source: "Test",
                stableIdentifier: "mouse"
            )
            let reader = StubBatteryReader(devices: [mouse, keyboard])
            let notifier = SpyNotificationService()
            let engine = MonitorEngine(
                reader: reader,
                store: store,
                settingsStore: settingsStore,
                notifier: notifier
            )
            let now = Date(timeIntervalSince1970: 310)

            let result = try await engine.refresh(now: now)
            let sentAlerts = await notifier.alerts()
            let sentBatches = await notifier.batches()

            try expect(result.alerts.count == 2)
            try expect(sentAlerts == result.alerts)
            try expect(sentBatches == [result.alerts])
            try expect(try store.readNotificationStates()[keyboard.id]?.lastNotifiedAt == now)
            try expect(try store.readNotificationStates()[mouse.id]?.lastNotifiedAt == now)
        }

        await runner.run("MonitorEngine persists cooldown across restart") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let settingsStore = SettingsStore(directoryURL: directory)
            try settingsStore.save(.default)

            let device = makeDevice(percentage: 10)
            let firstNotifier = SpyNotificationService()
            let firstEngine = MonitorEngine(
                reader: StubBatteryReader(devices: [device]),
                store: store,
                settingsStore: settingsStore,
                notifier: firstNotifier,
                widgetReloader: SpyWidgetReloader()
            )
            let firstNow = Date(timeIntervalSince1970: 1_000)
            _ = try await firstEngine.refresh(now: firstNow)
            let firstAlerts = await firstNotifier.alerts()
            try expect(firstAlerts.count == 1)

            let secondNotifier = SpyNotificationService()
            let secondEngine = MonitorEngine(
                reader: StubBatteryReader(devices: [device]),
                store: store,
                settingsStore: settingsStore,
                notifier: secondNotifier,
                widgetReloader: SpyWidgetReloader()
            )
            _ = try await secondEngine.refresh(now: firstNow.addingTimeInterval(120))
            let secondAlerts = await secondNotifier.alerts()

            try expect(secondAlerts.isEmpty)
            try expect(try store.readNotificationStates()[device.id]?.lastNotifiedAt == firstNow)
        }

        await runner.run("MonitorEngine uses updated settings on immediate refresh") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let settingsStore = SettingsStore(directoryURL: directory)
            try settingsStore.save(.default)

            let device = makeDevice(percentage: 50)
            let notifier = SpyNotificationService()
            let engine = MonitorEngine(
                reader: StubBatteryReader(devices: [device]),
                store: store,
                settingsStore: settingsStore,
                notifier: notifier,
                widgetReloader: SpyWidgetReloader()
            )

            _ = try await engine.refresh(now: Date(timeIntervalSince1970: 2_000))
            let initialAlerts = await notifier.alerts()
            try expect(initialAlerts.isEmpty)

            try settingsStore.save(MonitorSettings(lowBatteryThreshold: 60))
            let result = try await engine.refresh(now: Date(timeIntervalSince1970: 2_001))
            let sentAlerts = await notifier.alerts()

            try expect(result.alerts.count == 1)
            try expect(result.alerts[0].threshold == 60)
            try expect(sentAlerts.count == 1)
            try expect(sentAlerts[0].threshold == 60)
        }

        await runner.run("MonitorEngine start reads persisted notification state before polling") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let settingsStore = SettingsStore(directoryURL: directory)
            try settingsStore.save(.default)

            let device = makeDevice(percentage: 10)
            let existingNotificationTime = Date(
                timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60
            )
            let existingState = DeviceNotificationState(
                deviceID: device.id,
                lastNotifiedAt: existingNotificationTime,
                wasLowBattery: true,
                lastSeenPercentage: 10,
                updatedAt: existingNotificationTime
            )
            try store.writeNotificationStates([device.id: existingState])

            let reader = CountingBatteryReader(device: device)
            let notifier = SpyNotificationService()
            let engine = MonitorEngine(
                reader: reader,
                store: store,
                settingsStore: settingsStore,
                notifier: notifier,
                widgetReloader: SpyWidgetReloader(),
                powerSourceObserverFactory: nil
            )

            engine.start()
            try await waitUntil { reader.readCount >= 1 }
            engine.stop()

            let alerts = await notifier.alerts()
            let persistedState = try require(try store.readNotificationStates()[device.id])

            try expect(alerts.isEmpty)
            try expect(persistedState.lastNotifiedAt == existingNotificationTime)
            try expect(persistedState.wasLowBattery)
            try expect(persistedState.lastSeenPercentage == 10)
        }

        await runner.run("MonitorEngine start wires power source change refresh") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let settingsStore = SettingsStore(directoryURL: directory)
            try settingsStore.save(MonitorSettings(pollingInterval: 30))

            let reader = CountingBatteryReader(device: makeDevice(percentage: 80, kind: .internalBattery))
            let observer = ManualPowerSourceObserver()
            let engine = MonitorEngine(
                reader: reader,
                store: store,
                settingsStore: settingsStore,
                notifier: NoopNotificationService(),
                widgetReloader: SpyWidgetReloader(),
                powerSourceObserverFactory: { onChange in
                    observer.onChange = onChange
                    return observer
                }
            )

            engine.start()
            try await waitUntil { reader.readCount >= 1 }
            try expect(observer.startCount == 1)

            observer.trigger()
            try await waitUntil { reader.readCount >= 2 }

            engine.stop()
            try expect(observer.stopCount == 1)
        }

        await runner.run("MonitorEngine start is idempotent") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let settingsStore = SettingsStore(directoryURL: directory)
            try settingsStore.save(MonitorSettings(pollingInterval: 30))

            let reader = CountingBatteryReader(device: makeDevice(percentage: 80, kind: .internalBattery))
            let observer = ManualPowerSourceObserver()
            let engine = MonitorEngine(
                reader: reader,
                store: store,
                settingsStore: settingsStore,
                notifier: NoopNotificationService(),
                widgetReloader: SpyWidgetReloader(),
                powerSourceObserverFactory: { onChange in
                    observer.onChange = onChange
                    return observer
                }
            )
            defer { engine.stop() }

            engine.start()
            engine.start()
            try await waitUntil { reader.readCount >= 1 }
            try await Task.sleep(nanoseconds: 100_000_000)

            try expect(reader.readCount == 1)
            try expect(observer.startCount == 1)
        }

        await runner.run("MonitorEngine persists states and retries after notification send failure") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let settingsStore = SettingsStore(directoryURL: directory)
            try settingsStore.save(.default)

            let device = makeDevice(percentage: 10)
            let notifier = FlakyNotificationService(failuresRemaining: 1)
            let engine = MonitorEngine(
                reader: StubBatteryReader(devices: [device]),
                store: store,
                settingsStore: settingsStore,
                notifier: notifier,
                widgetReloader: SpyWidgetReloader()
            )
            let firstNow = Date(timeIntervalSince1970: 2_000)

            let firstResult = try await engine.refresh(now: firstNow)
            let statesAfterFailure = try store.readNotificationStates()

            try expect(firstResult.alerts.count == 1)
            try expect(firstResult.notificationErrorDescription != nil)
            try expect(try store.readSnapshot()?.devices.count == 1)
            try expect(statesAfterFailure[device.id]?.wasLowBattery == true)
            try expect(statesAfterFailure[device.id]?.lastNotifiedAt == nil)

            let secondNow = firstNow.addingTimeInterval(180)
            let secondResult = try await engine.refresh(now: secondNow)
            let sentBatches = await notifier.batches()

            try expect(secondResult.notificationErrorDescription == nil)
            try expect(secondResult.alerts.count == 1)
            try expect(sentBatches == [secondResult.alerts])
            try expect(try store.readNotificationStates()[device.id]?.lastNotifiedAt == secondNow)
        }

        await runner.run("MonitorEngine retains recently seen devices as disconnected") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let settingsStore = SettingsStore(directoryURL: directory)
            try settingsStore.save(.default)

            let keyboard = makeNamedDevice(
                name: "Magic Keyboard",
                percentage: 60,
                source: "Test",
                stableIdentifier: "keyboard"
            )
            let airpods = makeNamedDevice(
                name: "AirPods Max",
                percentage: 45,
                source: "Test",
                stableIdentifier: "airpods"
            )
            let firstNow = Date(timeIntervalSince1970: 3_000)
            let firstEngine = MonitorEngine(
                reader: StubBatteryReader(devices: [keyboard, airpods]),
                store: store,
                settingsStore: settingsStore,
                notifier: NoopNotificationService(),
                widgetReloader: SpyWidgetReloader()
            )
            _ = try await firstEngine.refresh(now: firstNow)

            let secondEngine = MonitorEngine(
                reader: StubBatteryReader(devices: [keyboard]),
                store: store,
                settingsStore: settingsStore,
                notifier: NoopNotificationService(),
                widgetReloader: SpyWidgetReloader()
            )
            let secondNow = firstNow.addingTimeInterval(180)
            let secondResult = try await secondEngine.refresh(now: secondNow)
            let retained = secondResult.snapshot.devices.first { $0.id == airpods.id }

            try expect(secondResult.snapshot.devices.count == 2)
            try expect(retained?.isConnected == false)
            try expect(retained?.percentage == 45)
            try expect(retained?.updatedAt == firstNow)

            let expiredNow = firstNow.addingTimeInterval(
                MonitorEngine.disconnectedDeviceRetentionInterval + 3_600
            )
            let thirdResult = try await secondEngine.refresh(now: expiredNow)

            try expect(thirdResult.snapshot.devices.map(\.id) == [keyboard.id])
        }

        await runner.run("MonitorEngine does not alert for retained disconnected devices") {
            let directory = temporaryDirectory()
            let store = try SharedBatteryStore(directoryURL: directory)
            let settingsStore = SettingsStore(directoryURL: directory)
            try settingsStore.save(.default)

            let airpods = makeNamedDevice(
                name: "AirPods Max",
                percentage: 10,
                source: "Test",
                stableIdentifier: "airpods"
            )
            let firstNow = Date(timeIntervalSince1970: 4_000)
            let notifier = SpyNotificationService()
            let firstEngine = MonitorEngine(
                reader: StubBatteryReader(devices: [airpods]),
                store: store,
                settingsStore: settingsStore,
                notifier: notifier,
                widgetReloader: SpyWidgetReloader()
            )
            _ = try await firstEngine.refresh(now: firstNow)
            let firstAlerts = await notifier.alerts()
            try expect(firstAlerts.count == 1)

            let secondEngine = MonitorEngine(
                reader: StubBatteryReader(devices: []),
                store: store,
                settingsStore: settingsStore,
                notifier: notifier,
                widgetReloader: SpyWidgetReloader()
            )
            let cooldownExpiredNow = firstNow.addingTimeInterval(8_000)
            let secondResult = try await secondEngine.refresh(now: cooldownExpiredNow)
            let alertsAfterDisconnect = await notifier.alerts()

            try expect(secondResult.snapshot.devices.first?.isConnected == false)
            try expect(secondResult.alerts.isEmpty)
            try expect(alertsAfterDisconnect.count == 1)
        }

        await runner.run("RenamingBatteryReader renames internal battery to product name") {
            let devices = [
                BatteryDevice(
                    id: "internal",
                    name: "InternalBattery-0",
                    kind: .internalBattery,
                    percentage: 80,
                    isCharging: false,
                    isConnected: true,
                    source: "IOKit",
                    updatedAt: Date()
                ),
                BatteryDevice(
                    id: "mouse",
                    name: "Magic Mouse",
                    kind: .peripheral,
                    percentage: 50,
                    isCharging: nil,
                    isConnected: true,
                    source: "IOKit",
                    updatedAt: Date()
                )
            ]

            let renamed = try RenamingBatteryReader(
                base: StubBatteryReader(devices: devices),
                internalBatteryDisplayName: "MacBook Pro"
            ).readDevices(now: Date())
            try expect(renamed[0].name == "MacBook Pro")
            try expect(renamed[0].id == "internal")
            try expect(renamed[1].name == "Magic Mouse")

            let untouched = try RenamingBatteryReader(
                base: StubBatteryReader(devices: devices),
                internalBatteryDisplayName: nil
            ).readDevices(now: Date())
            try expect(untouched[0].name == "InternalBattery-0")
        }

        await runner.run("MacProductName trims marketing name and maps Intel identifiers") {
            try expect(MacProductName.trimmedMarketingName("MacBook Pro (14-inch, Nov 2023)") == "MacBook Pro")
            try expect(MacProductName.trimmedMarketingName("Mac mini") == "Mac mini")
            try expect(MacProductName.marketingName(forModelIdentifier: "MacBookPro16,1") == "MacBook Pro")
            try expect(MacProductName.marketingName(forModelIdentifier: "Macmini9,1") == "Mac mini")
            try expect(MacProductName.marketingName(forModelIdentifier: "Mac14,9") == nil)
            try expect(!MacProductName.displayName.isEmpty)
        }

        await runner.run("MonitorSettings decodes legacy JSON without language as system") {
            let legacyJSON = """
            {"lowBatteryThreshold":25,"recoveryMargin":5,"pollingInterval":180,"reminderCooldown":7200}
            """
            let decoded = try JSONDecoder().decode(MonitorSettings.self, from: Data(legacyJSON.utf8))
            try expect(decoded.language == .system)
            try expect(decoded.lowBatteryThreshold == 25)

            var settings = MonitorSettings.default
            settings.language = .english
            let roundTripped = try JSONDecoder().decode(
                MonitorSettings.self,
                from: JSONEncoder().encode(settings)
            )
            try expect(roundTripped.language == .english)
        }

        await runner.run("WidgetBatteryDisplayModel hides disconnected devices") {
            let snapshot = BatterySnapshot(
                devices: [
                    BatteryDevice(
                        id: "connected",
                        name: "Keyboard",
                        kind: .peripheral,
                        percentage: 60,
                        isCharging: nil,
                        isConnected: true,
                        source: "IOKit",
                        updatedAt: Date()
                    ),
                    BatteryDevice(
                        id: "gone",
                        name: "AirPods Pro",
                        kind: .peripheral,
                        percentage: 40,
                        isCharging: nil,
                        isConnected: false,
                        source: "IOKit",
                        updatedAt: Date()
                    )
                ],
                updatedAt: Date()
            )

            let model = WidgetBatteryDisplayModel(snapshot: snapshot, fallbackDate: Date())
            try expect(model.devices.map(\.id) == ["connected"])
            try expect(model.lowestDevice?.id == "connected")
        }

        await runner.run("IOKitPowerSourceReader reads and normalizes visible devices") {
            let devices = try IOKitPowerSourceReader().readDevices(now: Date())

            for device in devices {
                try expect(!device.name.isEmpty)
                try expect(device.percentage >= 0)
                try expect(device.percentage <= 100)
                try expect(device.source == "IOKit")
            }
        }

        await runner.run("DefaultBatteryReader reads visible devices") {
            let devices = try DefaultBatteryReader().readDevices(now: Date())

            for device in devices {
                try expect(!device.name.isEmpty)
                try expect(device.percentage >= 0)
                try expect(device.percentage <= 100)
                try expect(!device.source.isEmpty)
            }
        }

        await runner.run("DeviceTableRenderer prints device battery table") {
            let devices = [
                BatteryDevice(
                    id: "iokit:mac",
                    name: "MacBook Battery",
                    kind: .internalBattery,
                    percentage: 68,
                    isCharging: true,
                    isConnected: true,
                    source: "IOKit",
                    updatedAt: fixedDate()
                ),
                BatteryDevice(
                    id: "iokit:ups",
                    name: "Office UPS",
                    kind: .ups,
                    percentage: 50,
                    isCharging: false,
                    isConnected: true,
                    source: "IOKit",
                    updatedAt: fixedDate()
                ),
                BatteryDevice(
                    id: "ioregistry:mouse",
                    name: "Magic Mouse",
                    kind: .peripheral,
                    percentage: 14,
                    isCharging: nil,
                    isConnected: true,
                    source: "IORegistry",
                    updatedAt: fixedDate()
                )
            ]

            let table = DeviceTableRenderer.render(devices: devices)

            try expect(table.contains("Name\tKind\tBattery\tCharging\tSource\tID"))
            try expect(table.contains("MacBook Battery\tinternalBattery\t68%\tcharging\tIOKit\tiokit:mac"))
            try expect(table.contains("Office UPS\tups\t50%\tnot charging\tIOKit\tiokit:ups"))
            try expect(table.contains("Magic Mouse\tperipheral\t14%\tnot reported\tIORegistry\tioregistry:mouse"))
            try expect(DeviceTableRenderer.render(devices: []) == "No battery devices found.")
        }

        await runner.run("BatterySourceDiagnosticsRenderer prints IORegistry fields") {
            let diagnostics = [
                IORegistryBatteryDiagnostic(
                    name: "Magic Mouse",
                    address: "04-4b-ed-bc-d9-8b",
                    percentage: 93,
                    chargingFields: [],
                    batteryStatusFlags: "0",
                    supportsExtendedBatteryState: nil
                ),
                IORegistryBatteryDiagnostic(
                    name: "Magic Keyboard",
                    address: "38-09-fb-30-9f-78",
                    percentage: 22,
                    chargingFields: ["Is Charging=Yes"],
                    batteryStatusFlags: "6",
                    supportsExtendedBatteryState: "Yes"
                )
            ]
            let report = BatterySourceDiagnosticsRenderer.render(ioRegistry: diagnostics)

            try expect(report.contains("IORegistry battery diagnostics"))
            try expect(report.contains("Name\tBattery\tChargingFields\tBatteryStatusFlags\tDecodedCharging\tSupportsExtendedBatteryState\tAddress"))
            try expect(report.contains("Magic Mouse\t93%\tnot reported\t0\tnot charging\tnot reported\t04-4b-ed-bc-d9-8b"))
            try expect(report.contains("Magic Keyboard\t22%\tIs Charging=Yes\t6\tcharging\tYes\t38-09-fb-30-9f-78"))
        }

        await runner.run("DeviceCompatibilityReportRenderer renders M0 compatibility baseline") {
            let snapshot = BatterySnapshot(
                devices: [
                    BatteryDevice(
                        id: "iokit:mac",
                        name: "MacBook Battery",
                        kind: .internalBattery,
                        percentage: 68,
                        isCharging: true,
                        isConnected: true,
                        source: "IOKit",
                        updatedAt: fixedDate()
                    ),
                    BatteryDevice(
                        id: "ioregistry:mouse",
                        name: "Desk Magic Mouse",
                        kind: .peripheral,
                        percentage: 14,
                        isCharging: nil,
                        isConnected: true,
                        source: "IORegistry",
                        updatedAt: fixedDate()
                    )
                ],
                updatedAt: fixedDate()
            )

            let report = DeviceCompatibilityReportRenderer.render(
                snapshot: snapshot,
                generatedAt: Date(timeIntervalSince1970: 100),
                hardwareModel: "MacTest,1",
                operatingSystemVersion: "Version Test",
                historicalDevices: [
                    HistoricalCompatibilityDevice(
                        name: "Desk AirPods Max",
                        deviceType: "外设",
                        percentage: "42%",
                        chargingStatus: "未上报",
                        source: "IOBluetooth"
                    )
                ],
                bluetoothIdentities: [
                    BluetoothDeviceIdentity(
                        name: "Desk Magic Mouse",
                        address: "04:4B:ED:BC:D9:8B",
                        minorType: "Mouse",
                        isConnected: true
                    ),
                    BluetoothDeviceIdentity(
                        name: "Desk Keyboard",
                        address: "38:09:FB:30:9F:78",
                        minorType: "Keyboard",
                        isConnected: false
                    ),
                    BluetoothDeviceIdentity(
                        name: "Desk AirPods Max",
                        address: "70:F9:4A:9F:1E:76",
                        minorType: "Headphones",
                        isConnected: false
                    ),
                    BluetoothDeviceIdentity(
                        name: "Desk MX Master",
                        address: "D1:F6:C0:1B:2D:FE",
                        minorType: "Mouse",
                        isConnected: true
                    )
                ],
                ioRegistryDiagnostics: [
                    IORegistryBatteryDiagnostic(
                        name: "Desk Magic Mouse",
                        address: "04-4b-ed-bc-d9-8b",
                        percentage: 14,
                        chargingFields: [],
                        batteryStatusFlags: "0",
                        supportsExtendedBatteryState: nil
                    )
                ]
            )

            try expect(report.contains("机器型号：MacTest,1"))
            try expect(report.contains("macOS 版本：Version Test"))
            try expect(report.contains("- 默认组合 reader 当前可见 2 个电池设备。"))
            try expect(report.contains("- 另有 1 个历史已验证设备当前未检测到；保留在 MVP 支持范围，接入或唤醒后应再次验证可见。"))
            try expect(report.contains("| MacBook Battery | 本机电池 | 是 | 68% | 充电中 | IOKit |"))
            try expect(report.contains("| Desk Magic Mouse | 外设 | 是 | 14% | 未上报 | IORegistry |"))
            try expect(report.contains("| Desk AirPods Max | 外设 | 是（历史验证，当前未检测到） | 42% | 未上报 | IOBluetooth；接入或唤醒后重跑 M0 CLI |"))
            try expect(report.contains("| Magic Keyboard | 外设 | 否（当前未检测到） | 不适用 | 未知 | 接入后运行设备可见性校验并重跑 M0 CLI 报告 |"))
            try expect(report.contains("| Magic Trackpad | 外设 | 否（当前未检测到） | 不适用 | 未知 | 接入后运行设备可见性校验并重跑 M0 CLI 报告 |"))
            try expect(report.contains("- MacBook Battery（68%）"))
            try expect(report.contains("- Desk Magic Mouse（14%）"))
            try expect(report.contains("- Desk AirPods Max（42%，历史已验证；当前未检测到）"))
            try expect(report.contains("- Magic Keyboard：当前未检测到；接入后运行 `./scripts/verify_device_visible.sh --name \"Magic Keyboard\" --kind peripheral` 并重跑 M0 CLI 报告"))
            try expect(report.contains("- Magic Trackpad：当前未检测到；接入后运行 `./scripts/verify_device_visible.sh --name \"Magic Trackpad\" --kind peripheral` 并重跑 M0 CLI 报告"))
            try expect(report.contains("## 蓝牙候选设备诊断"))
            try expect(report.contains("## IORegistry 电池字段诊断"))
            try expect(report.contains("| Desk Magic Mouse | 14% | 未上报（缺少 IsCharging/Is Charging/Charging/FullyCharged 字段） | 0 | 未充电 | 未上报 | 04-4b-ed-bc-d9-8b |"))
            try expect(!report.contains("| Desk Magic Mouse | 已连接 | Mouse | 已连接但未读取到电量 |"))
            try expect(report.contains("| Desk Keyboard | 未连接 | Keyboard | 未连接，当前无法读取实时电量 | 连接或唤醒设备后运行设备可见性校验 |"))
            try expect(report.contains("| Desk AirPods Max | 未连接 | Headphones | 未连接，当前无法读取实时电量 | 连接或唤醒设备后运行设备可见性校验 |"))
            try expect(report.contains("| Desk MX Master | 已连接 | Mouse | 已连接但未读取到电量 | 检查蓝牙权限后重跑 CLI；如仍缺失需补充 fallback |"))

            let historicalDevices = DeviceCompatibilityReportRenderer.historicalDevices(from: report)
            try expect(historicalDevices.contains {
                $0.name == "Desk AirPods Max"
                    && $0.percentage == "42%"
                    && $0.source.contains("IOBluetooth")
            })
        }

        runner.finish()
    }
}

@MainActor
private struct TestRunner {
    private var passed = 0
    private var failed = 0

    mutating func run(_ name: String, _ test: () async throws -> Void) async {
        do {
            try await test()
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
    }

    func finish() {
        print("")
        print("Test result: \(passed) passed, \(failed) failed")
        if failed > 0 {
            Foundation.exit(1)
        }
    }
}

private enum TestFailure: Error, CustomStringConvertible {
    case expectationFailed(String)

    var description: String {
        switch self {
        case let .expectationFailed(message):
            return message
        }
    }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "expectation failed") throws {
    guard try condition() else {
        throw TestFailure.expectationFailed(message)
    }
}

private func require<T>(_ value: T?, _ message: String = "required value was nil") throws -> T {
    guard let value else {
        throw TestFailure.expectationFailed(message)
    }
    return value
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    throw TestFailure.expectationFailed("condition was not satisfied before timeout")
}

private func fixedDate() -> Date {
    Date(timeIntervalSince1970: 1_700_000_000)
}

private func evaluate(
    devices: [BatteryDevice],
    states: [String: DeviceNotificationState],
    now: Date
) -> RuleEvaluation {
    let snapshot = BatterySnapshot(devices: devices, updatedAt: now)
    return RuleEngine(settings: .default).evaluate(snapshot: snapshot, states: states, now: now)
}

private func makeDevice(
    percentage: Int,
    isCharging: Bool? = false,
    isConnected: Bool = true,
    kind: DeviceKind = .peripheral
) -> BatteryDevice {
    BatteryDevice(
        id: "device-\(percentage)-\(String(describing: isCharging))-\(isConnected)-\(kind.rawValue)",
        name: "Test Device",
        kind: kind,
        percentage: percentage,
        isCharging: isCharging,
        isConnected: isConnected,
        source: "Test",
        updatedAt: fixedDate()
    )
}

private func makeNamedDevice(
    name: String,
    percentage: Int,
    source: String,
    stableIdentifier: String,
    kind: DeviceKind = .peripheral
) -> BatteryDevice {
    BatteryDevice(
        id: BatteryDevice.makeID(
            name: name,
            kind: kind,
            source: source,
            stableIdentifier: stableIdentifier
        ),
        name: name,
        kind: kind,
        percentage: percentage,
        isCharging: nil,
        isConnected: true,
        source: source,
        updatedAt: fixedDate()
    )
}

private func ioRegistryBatteryFixture() -> String {
    """
    +-o AppleDeviceManagementHIDEventService  <class AppleDeviceManagementHIDEventService>
        {
          "HasBattery" = Yes
          "Built-In" = No
          "DeviceAddress" = "04-4b-ed-bc-d9-8b"
          "Product" =
          "SerialNumber" = "04:4B:ED:BC:D9:8B"
          "Transport" = "Bluetooth"
          "IsCharging" = No
          "ProductID" = 617
          "BatteryPercent" = 94
          "BatteryStatusFlags" = 0
        }

    +-o AppleDeviceManagementHIDEventService  <class AppleDeviceManagementHIDEventService>
        {
          "HasBattery" = Yes
          "Built-In" = No
          "DeviceAddress" = "38-09-fb-30-9f-78"
          "Product" =
          "SerialNumber" = "38:09:FB:30:9F:78"
          "Transport" = "Bluetooth"
          "Is Charging" = Yes
          "SupportsExtendedBatteryState" = Yes
          "ProductID" = 802
          "BatteryPercent" = 22
          "BatteryStatusFlags" = 6
        }
    """
}

private func ioRegistryExtendedBatteryFlagsFixture() -> String {
    """
    +-o AppleDeviceManagementHIDEventService  <class AppleDeviceManagementHIDEventService>
        {
          "HasBattery" = Yes
          "Built-In" = No
          "DeviceAddress" = "aa-bb-cc-dd-ee-01"
          "Product" =
          "SerialNumber" = "AA:BB:CC:DD:EE:01"
          "Transport" = "Bluetooth"
          "SupportsExtendedBatteryState" = Yes
          "ProductID" = 802
          "BatteryPercent" = 22
          "BatteryStatusFlags" = 4
        }

    +-o AppleDeviceManagementHIDEventService  <class AppleDeviceManagementHIDEventService>
        {
          "HasBattery" = Yes
          "Built-In" = No
          "DeviceAddress" = "aa-bb-cc-dd-ee-02"
          "Product" = "Flags Trackpad"
          "SerialNumber" = "AA:BB:CC:DD:EE:02"
          "Transport" = "Bluetooth"
          "SupportsExtendedBatteryState" = Yes
          "ProductID" = 0
          "BatteryPercent" = 18
          "BatteryStatusFlags" = 6
        }
    """
}

private func ioRegistryZeroBatteryFlagsFixture() -> String {
    """
    +-o AppleDeviceManagementHIDEventService  <class AppleDeviceManagementHIDEventService>
        {
          "HasBattery" = Yes
          "Built-In" = No
          "DeviceAddress" = "aa-bb-cc-dd-ee-03"
          "Product" =
          "SerialNumber" = "AA:BB:CC:DD:EE:03"
          "Transport" = "Bluetooth"
          "ProductID" = 617
          "BatteryPercent" = 94
          "BatteryStatusFlags" = 0
        }
    """
}

private func systemProfilerBluetoothFixture() -> String {
    """
    {
      "SPBluetoothDataType": [
        {
          "device_connected": [
            {
              "Desk Mouse": {
                "device_address": "04:4B:ED:BC:D9:8B",
                "device_minorType": "Mouse"
              }
            }
          ],
          "device_not_connected": [
            {
              "Desk Keyboard": {
                "device_address": "38:09:FB:30:9F:78",
                "device_minorType": "Keyboard"
              }
            },
            {
              "Desk AirPods": {
                "device_address": "50:F3:51:B4:B4:C8",
                "device_minorType": "Headphones",
                "device_batteryLevelLeft": "100%",
                "device_batteryLevelRight": "95%",
                "device_batteryLevelCase": "11%"
              }
            }
          ]
        }
      ]
    }
    """
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BatteryMonitorTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private struct StubBatteryReader: BatteryReading {
    var devices: [BatteryDevice]

    func readDevices(now: Date) throws -> [BatteryDevice] {
        devices.map { device in
            BatteryDevice(
                id: device.id,
                name: device.name,
                kind: device.kind,
                percentage: device.percentage,
                isCharging: device.isCharging,
                isConnected: device.isConnected,
                source: device.source,
                updatedAt: now
            )
        }
    }
}

private final class CountingBatteryReader: BatteryReading, @unchecked Sendable {
    private let lock = NSLock()
    private let device: BatteryDevice
    private var _readCount = 0

    init(device: BatteryDevice) {
        self.device = device
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _readCount
    }

    func readDevices(now: Date) throws -> [BatteryDevice] {
        lock.lock()
        _readCount += 1
        lock.unlock()

        return [
            BatteryDevice(
                id: device.id,
                name: device.name,
                kind: device.kind,
                percentage: device.percentage,
                isCharging: device.isCharging,
                isConnected: device.isConnected,
                source: device.source,
                updatedAt: now
            )
        ]
    }
}

private final class ManualPowerSourceObserver: PowerSourceChangeObserving, @unchecked Sendable {
    private let lock = NSLock()
    var onChange: (@Sendable () -> Void)?
    private var _startCount = 0
    private var _stopCount = 0

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startCount
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopCount
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        _startCount += 1
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        _stopCount += 1
    }

    func trigger() {
        onChange?()
    }
}

private actor SpyNotificationService: BatteryAlertNotifying {
    private var sentAlerts: [LowBatteryAlert] = []
    private var sentBatches: [[LowBatteryAlert]] = []

    func requestAuthorization() async -> Bool {
        true
    }

    func authorizationStatus() async -> NotificationPermissionStatus {
        .authorized
    }

    func sendLowBatteryAlert(_ alert: LowBatteryAlert) async throws {
        sentAlerts.append(alert)
    }

    func sendLowBatteryAlerts(_ alerts: [LowBatteryAlert]) async throws {
        sentBatches.append(alerts)
        sentAlerts.append(contentsOf: alerts)
    }

    func alerts() -> [LowBatteryAlert] {
        sentAlerts
    }

    func batches() -> [[LowBatteryAlert]] {
        sentBatches
    }
}

private actor FlakyNotificationService: BatteryAlertNotifying {
    struct SendFailure: Error {}

    private var failuresRemaining: Int
    private var sentBatches: [[LowBatteryAlert]] = []

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func requestAuthorization() async -> Bool {
        true
    }

    func authorizationStatus() async -> NotificationPermissionStatus {
        .authorized
    }

    func sendLowBatteryAlert(_ alert: LowBatteryAlert) async throws {
        try await sendLowBatteryAlerts([alert])
    }

    func sendLowBatteryAlerts(_ alerts: [LowBatteryAlert]) async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw SendFailure()
        }
        sentBatches.append(alerts)
    }

    func batches() -> [[LowBatteryAlert]] {
        sentBatches
    }
}

private final class SpyUserNotificationCenter: UserNotificationCentering, @unchecked Sendable {
    var authorizationRequestOptions: UNAuthorizationOptions?
    var authorizationResult = true
    var status: NotificationPermissionStatus = .authorized
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var requests: [UNNotificationRequest] = []

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequestOptions = options
        return authorizationResult
    }

    func authorizationStatus() async -> NotificationPermissionStatus {
        status
    }

    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
    }
}

private final class SpyLoginItemController: LoginItemControlling {
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func register() throws {
        registerCount += 1
        isEnabled = true
    }

    func unregister() throws {
        unregisterCount += 1
        isEnabled = false
    }
}

private final class SpyWidgetReloader: WidgetTimelineReloading, @unchecked Sendable {
    private let lock = NSLock()
    private var _reloadCount = 0

    var reloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _reloadCount
    }

    func reloadAllTimelines() {
        lock.lock()
        defer { lock.unlock() }
        _reloadCount += 1
    }
}
