import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth
import BatteryMonitorShared
import IOKit
import IOKit.ps
import ObjectiveC

public enum BatteryReadError: Error, CustomStringConvertible, Sendable {
    case unavailablePowerSourceSnapshot
    case unavailablePowerSourceList
    case noReadersConfigured

    public var description: String {
        switch self {
        case .unavailablePowerSourceSnapshot:
            return "Unable to create an IOKit power source snapshot."
        case .unavailablePowerSourceList:
            return "Unable to read IOKit power sources."
        case .noReadersConfigured:
            return "No battery readers are configured."
        }
    }
}

public protocol BatteryReading: Sendable {
    func readDevices(now: Date) throws -> [BatteryDevice]
}

private func normalizedAddress(_ value: String) -> String {
    String(value.lowercased().unicodeScalars.filter { scalar in
        CharacterSet(charactersIn: "0123456789abcdef").contains(scalar)
    })
}

public struct CommandResult: Equatable, Sendable {
    public var standardOutput: String
    public var standardError: String
    public var exitCode: Int32

    public init(standardOutput: String, standardError: String = "", exitCode: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

public enum CommandRunError: Error, CustomStringConvertible, Sendable {
    case nonZeroExit(executablePath: String, arguments: [String], exitCode: Int32, standardError: String)

    public var description: String {
        switch self {
        case let .nonZeroExit(executablePath, arguments, exitCode, standardError):
            let command = ([executablePath] + arguments).joined(separator: " ")
            return "Command failed with exit code \(exitCode): \(command)\n\(standardError)"
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(executablePath: String, arguments: [String]) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executablePath: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let result = CommandResult(
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self),
            exitCode: process.terminationStatus
        )

        guard result.exitCode == 0 else {
            throw CommandRunError.nonZeroExit(
                executablePath: executablePath,
                arguments: arguments,
                exitCode: result.exitCode,
                standardError: result.standardError
            )
        }

        return result
    }
}

public final class DefaultBatteryReader: BatteryReading, @unchecked Sendable {
    private let reader: RenamingBatteryReader

    public init(commandRunner: any CommandRunning = ProcessCommandRunner()) {
        let bluetoothResolver = CachedBluetoothDeviceResolver(
            resolver: SystemProfilerBluetoothDeviceResolver(commandRunner: commandRunner)
        )
        // Order matters: earlier readers win device identity in deduplication,
        // later readers only fill in missing charging/connection state.
        // AccessoryPowerSourceReader goes last so existing device IDs stay
        // stable while its authoritative `Is Charging` flag (the system
        // battery widget's own source) is merged into every matched device.
        reader = RenamingBatteryReader(base: CompositeBatteryReader(readers: [
            IOKitPowerSourceReader(),
            AppleSmartBatteryReader(),
            IORegistryBatteryReader(commandRunner: commandRunner, bluetoothResolver: bluetoothResolver),
            IOBluetoothBatteryReader(bluetoothResolver: bluetoothResolver),
            SystemProfilerBatteryReader(bluetoothResolver: bluetoothResolver),
            BluetoothLEBatteryServiceReader(),
            AccessoryPowerSourceReader()
        ]))
    }

    public func readDevices(now: Date = Date()) throws -> [BatteryDevice] {
        try reader.readDevices(now: now)
    }
}

/// Readers report the internal battery with IOKit names like
/// "InternalBattery-0"; every consumer should see the Mac's product name
/// instead. Renaming happens after identity/dedup so device IDs (and with
/// them notification state) stay stable.
public struct RenamingBatteryReader: BatteryReading {
    public var base: any BatteryReading
    public var internalBatteryDisplayName: String?

    public init(base: any BatteryReading, internalBatteryDisplayName: String? = MacProductName.displayName) {
        self.base = base
        self.internalBatteryDisplayName = internalBatteryDisplayName
    }

    public func readDevices(now: Date) throws -> [BatteryDevice] {
        let devices = try base.readDevices(now: now)
        guard let internalBatteryDisplayName, !internalBatteryDisplayName.isEmpty else {
            return devices
        }
        return devices.map { device in
            guard device.kind == .internalBattery else {
                return device
            }
            var renamed = device
            renamed.name = internalBatteryDisplayName
            return renamed
        }
    }
}

public final class CompositeBatteryReader: BatteryReading, @unchecked Sendable {
    private let readers: [any BatteryReading]

    public init(readers: [any BatteryReading]) {
        self.readers = readers
    }

    public func readDevices(now: Date = Date()) throws -> [BatteryDevice] {
        guard !readers.isEmpty else {
            throw BatteryReadError.noReadersConfigured
        }

        var devices: [BatteryDevice] = []
        var firstError: Error?

        for reader in readers {
            do {
                devices += try reader.readDevices(now: now)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if devices.isEmpty, let firstError {
            throw firstError
        }

        return Self.deduplicated(devices)
    }

    public static func deduplicated(_ devices: [BatteryDevice]) -> [BatteryDevice] {
        var result: [BatteryDevice] = []
        var indexByKey: [String: Int] = [:]

        for device in devices {
            let keys = dedupeKeys(for: device)
            if let existingIndex = keys.compactMap({ indexByKey[$0] }).first {
                result[existingIndex] = merged(preferred: result[existingIndex], fallback: device)
                for key in keys {
                    indexByKey[key] = existingIndex
                }
                continue
            }

            result.append(device)
            let index = result.count - 1
            for key in keys {
                indexByKey[key] = index
            }
        }

        return result
    }

    private static func dedupeKeys(for device: BatteryDevice) -> Set<String> {
        var keys = Set<String>()

        if let idSuffix = device.id.split(separator: ":", maxSplits: 1).last, !idSuffix.isEmpty {
            keys.insert("id:\(idSuffix)")
        }

        let normalizedName = normalizeToken(device.name)
        if !normalizedName.isEmpty, !normalizedName.hasPrefix("bluetooth-device") {
            keys.insert("name:\(device.kind.rawValue):\(normalizedName)")
        }

        return keys
    }

    private static func merged(preferred: BatteryDevice, fallback: BatteryDevice) -> BatteryDevice {
        var merged = preferred
        if merged.isCharging == nil, let isCharging = fallback.isCharging {
            merged.isCharging = isCharging
        }
        if !merged.isConnected, fallback.isConnected {
            merged.isConnected = true
        }
        return merged
    }

    private static func normalizeToken(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" {
                    return
                }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public struct BluetoothDeviceIdentity: Equatable, Sendable {
    public var name: String
    public var address: String
    public var minorType: String?
    public var isConnected: Bool?
    public var batteryLevelMain: Int?
    public var batteryLevelLeft: Int?
    public var batteryLevelRight: Int?
    public var batteryLevelCase: Int?

    public init(
        name: String,
        address: String,
        minorType: String?,
        isConnected: Bool?,
        batteryLevelMain: Int? = nil,
        batteryLevelLeft: Int? = nil,
        batteryLevelRight: Int? = nil,
        batteryLevelCase: Int? = nil
    ) {
        self.name = name
        self.address = address
        self.minorType = minorType
        self.isConnected = isConnected
        self.batteryLevelMain = batteryLevelMain
        self.batteryLevelLeft = batteryLevelLeft
        self.batteryLevelRight = batteryLevelRight
        self.batteryLevelCase = batteryLevelCase
    }
}

public final class AppleSmartBatteryReader: BatteryReading, @unchecked Sendable {
    public init() {}

    public func readDevices(now: Date = Date()) throws -> [BatteryDevice] {
        guard let properties = Self.readProperties(),
              (Self.boolValue(properties["BatteryInstalled"]) ?? true) else {
            return []
        }

        let currentCapacity = Self.intValue(properties["CurrentCapacity"])
            ?? Self.intValue(properties["AppleRawCurrentCapacity"])
            ?? 0
        let maxCapacity = Self.intValue(properties["MaxCapacity"]) ?? 100
        let percentage = BatteryPercentage.calculate(current: currentCapacity, max: maxCapacity)
        let name = "InternalBattery-0"
        let serial = Self.stringValue(properties["Serial"])
            ?? Self.stringValue(Self.dictionaryValue(properties["BatteryData"])?.object(forKey: "Serial"))
            ?? "AppleSmartBattery"

        return [
            BatteryDevice(
                id: BatteryDevice.makeID(
                    name: name,
                    kind: .internalBattery,
                    source: "AppleSmartBattery",
                    stableIdentifier: serial
                ),
                name: name,
                kind: .internalBattery,
                percentage: percentage,
                isCharging: Self.chargingState(from: properties),
                isConnected: true,
                source: "AppleSmartBattery",
                updatedAt: now
            )
        ]
    }

    private static func readProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }

        var propertiesRef: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let properties = propertiesRef?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return properties
    }

    private static func chargingState(from properties: [String: Any]) -> Bool? {
        if let isCharging = boolValue(properties["IsCharging"])
            ?? boolValue(properties["Is Charging"])
            ?? boolValue(properties[kIOPSIsChargingKey]) {
            return isCharging
        }

        if (boolValue(properties["FullyCharged"]) ?? boolValue(properties["Fully Charged"])) == true {
            return false
        }

        if let externalConnected = boolValue(properties["ExternalConnected"])
            ?? boolValue(properties["AppleRawExternalConnected"]),
           externalConnected == false {
            return false
        }

        if let amperage = intValue(properties["InstantAmperage"]) ?? intValue(properties["Amperage"]) {
            if amperage > 0 {
                return true
            }
            if amperage < 0 {
                return false
            }
        }

        if let chargerData = dictionaryValue(properties["ChargerData"]),
           let chargingCurrent = intValue(chargerData.object(forKey: "ChargingCurrent")) {
            return chargingCurrent > 0
        }

        return nil
    }

    private static func dictionaryValue(_ value: Any?) -> NSDictionary? {
        value as? NSDictionary
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "true", "1":
                return true
            case "no", "false", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

public protocol BluetoothDeviceResolving: Sendable {
    func readBluetoothDeviceIdentities() throws -> [BluetoothDeviceIdentity]
}

public final class CachedBluetoothDeviceResolver: BluetoothDeviceResolving, @unchecked Sendable {
    private let resolver: any BluetoothDeviceResolving
    private let cacheDuration: TimeInterval
    private let lock = NSLock()
    private var cachedAt: Date?
    private var cachedIdentities: [BluetoothDeviceIdentity]?

    public init(resolver: any BluetoothDeviceResolving, cacheDuration: TimeInterval = 5) {
        self.resolver = resolver
        self.cacheDuration = cacheDuration
    }

    public func readBluetoothDeviceIdentities() throws -> [BluetoothDeviceIdentity] {
        lock.lock()
        if let cachedAt,
           let cachedIdentities,
           Date().timeIntervalSince(cachedAt) <= cacheDuration {
            lock.unlock()
            return cachedIdentities
        }
        lock.unlock()

        let identities = try resolver.readBluetoothDeviceIdentities()

        lock.lock()
        cachedAt = Date()
        cachedIdentities = identities
        lock.unlock()

        return identities
    }
}

public struct SystemProfilerBluetoothDeviceResolver: BluetoothDeviceResolving {
    private let commandRunner: any CommandRunning

    public init(commandRunner: any CommandRunning = ProcessCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func readBluetoothDeviceIdentities() throws -> [BluetoothDeviceIdentity] {
        let result = try commandRunner.run(
            executablePath: "/usr/sbin/system_profiler",
            arguments: ["SPBluetoothDataType", "-json"]
        )
        return try Self.parseIdentities(from: Data(result.standardOutput.utf8))
    }

    public static func parseIdentities(from data: Data) throws -> [BluetoothDeviceIdentity] {
        let object = try JSONSerialization.jsonObject(with: data)
        var identities: [BluetoothDeviceIdentity] = []
        collectIdentities(from: object, isConnected: nil, into: &identities)
        return deduplicated(identities)
    }

    private static func collectIdentities(
        from object: Any,
        isConnected: Bool?,
        into identities: inout [BluetoothDeviceIdentity]
    ) {
        if let array = object as? [Any] {
            for item in array {
                collectIdentities(from: item, isConnected: isConnected, into: &identities)
            }
            return
        }

        guard let dictionary = object as? [String: Any] else {
            return
        }

        for (key, value) in dictionary {
            if key == "device_connected" {
                collectIdentities(from: value, isConnected: true, into: &identities)
                continue
            }
            if key == "device_not_connected" {
                collectIdentities(from: value, isConnected: false, into: &identities)
                continue
            }

            if let device = value as? [String: Any],
               let address = stringValue(in: device, key: "device_address"),
               !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                identities.append(BluetoothDeviceIdentity(
                    name: key,
                    address: address,
                    minorType: stringValue(in: device, key: "device_minorType"),
                    isConnected: isConnected,
                    batteryLevelMain: percentageValue(in: device, key: "device_batteryLevelMain"),
                    batteryLevelLeft: percentageValue(in: device, key: "device_batteryLevelLeft"),
                    batteryLevelRight: percentageValue(in: device, key: "device_batteryLevelRight"),
                    batteryLevelCase: percentageValue(in: device, key: "device_batteryLevelCase")
                ))
            }

            collectIdentities(from: value, isConnected: isConnected, into: &identities)
        }
    }

    private static func deduplicated(_ identities: [BluetoothDeviceIdentity]) -> [BluetoothDeviceIdentity] {
        var result: [BluetoothDeviceIdentity] = []
        var seenAddresses = Set<String>()

        for identity in identities.sorted(by: identitySort) {
            let address = normalizedAddress(identity.address)
            guard !address.isEmpty, !seenAddresses.contains(address) else {
                continue
            }

            result.append(identity)
            seenAddresses.insert(address)
        }

        return result
    }

    private static func identitySort(lhs: BluetoothDeviceIdentity, rhs: BluetoothDeviceIdentity) -> Bool {
        switch (lhs.isConnected, rhs.isConnected) {
        case (.some(true), .some(false)), (.some(true), .none), (.none, .some(false)):
            return true
        case (.some(false), .some(true)), (.none, .some(true)), (.some(false), .none):
            return false
        default:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func stringValue(in dictionary: [String: Any], key: String) -> String? {
        if let value = dictionary[key] as? String {
            return value
        }
        if let value = dictionary[key] as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    /// system_profiler reports battery levels as strings such as "11%".
    private static func percentageValue(in dictionary: [String: Any], key: String) -> Int? {
        guard let raw = stringValue(in: dictionary, key: key) else {
            return nil
        }
        let digits = raw.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
        guard let value = Int(digits), value >= 1, value <= 100 else {
            return nil
        }
        return value
    }
}

public final class IOBluetoothBatteryReader: BatteryReading, @unchecked Sendable {
    private typealias UInt8Getter = @convention(c) (AnyObject, Selector) -> UInt8

    private let bluetoothResolver: any BluetoothDeviceResolving

    public init(bluetoothResolver: any BluetoothDeviceResolving = SystemProfilerBluetoothDeviceResolver()) {
        self.bluetoothResolver = bluetoothResolver
    }

    public func readDevices(now: Date = Date()) throws -> [BatteryDevice] {
        let identities = try bluetoothResolver.readBluetoothDeviceIdentities()
        return Self.readDevices(now: now, bluetoothIdentities: identities)
    }

    public static func readDevices(
        now: Date,
        bluetoothIdentities: [BluetoothDeviceIdentity]
    ) -> [BatteryDevice] {
        bluetoothIdentities.compactMap { identity in
            guard identity.isConnected != false else {
                return nil
            }

            let address = normalizedAddress(identity.address)
            guard !address.isEmpty,
                  let device = IOBluetoothDevice(addressString: identity.address),
                  device.isConnected() else {
                return nil
            }

            guard let percentage = displayedPercentage(for: device), percentage > 0 else {
                return nil
            }

            let name = nonEmpty(identity.name)
                ?? nonEmpty(device.nameOrAddress)
                ?? "Bluetooth Device \(address.suffix(4).uppercased())"
            return makeDevice(
                name: name,
                address: identity.address,
                percentage: percentage,
                now: now
            )
        }
    }

    public static func makeDevice(
        name: String,
        address: String,
        percentage: Int,
        now: Date
    ) -> BatteryDevice {
        BatteryDevice(
            id: BatteryDevice.makeID(
                name: name,
                kind: .peripheral,
                source: "IOBluetooth",
                stableIdentifier: address
            ),
            name: name,
            kind: .peripheral,
            percentage: percentage,
            // IOBluetooth exposes no charging state; nil keeps low-battery
            // alerts active instead of pretending the device is discharging.
            isCharging: nil,
            isConnected: true,
            source: "IOBluetooth",
            updatedAt: now
        )
    }

    public static func selectDisplayedPercentage(
        single: Int?,
        combined: Int?,
        left: Int?,
        right: Int?,
        batteryCase: Int?
    ) -> Int? {
        if let combined = validPercentage(combined) {
            return combined
        }
        if let single = validPercentage(single) {
            return single
        }

        let parts = [left, right, batteryCase].compactMap(validPercentage)
        return parts.min()
    }

    private static func displayedPercentage(for device: IOBluetoothDevice) -> Int? {
        let object = device as AnyObject
        let single = intValue(object, selectorName: "batteryPercentSingle")
        let combined = intValue(object, selectorName: "batteryPercentCombined")
        let left = intValue(object, selectorName: "batteryPercentLeft")
        let right = intValue(object, selectorName: "batteryPercentRight")
        let batteryCase = intValue(object, selectorName: "batteryPercentCase")

        return selectDisplayedPercentage(
            single: single,
            combined: combined,
            left: left,
            right: right,
            batteryCase: batteryCase
        )
    }

    private static func intValue(_ object: AnyObject, selectorName: String) -> Int? {
        let selector = Selector((selectorName))
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector) else {
            return nil
        }

        let implementation = method_getImplementation(method)
        let getter = unsafeBitCast(implementation, to: UInt8Getter.self)
        return Int(getter(object, selector))
    }

    private static func validPercentage(_ value: Int?) -> Int? {
        guard let value, value >= 0, value <= 100 else {
            return nil
        }
        guard value > 0 else {
            return nil
        }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Reads battery levels that bluetoothd publishes through `system_profiler
/// SPBluetoothDataType`. This is the only public source for AirPods-style
/// devices that report battery over proximity pairing without a classic
/// Bluetooth connection, and it also exposes the charging case as its own
/// device the same way the system battery widget does.
public final class SystemProfilerBatteryReader: BatteryReading, @unchecked Sendable {
    private let bluetoothResolver: any BluetoothDeviceResolving

    public init(bluetoothResolver: any BluetoothDeviceResolving = SystemProfilerBluetoothDeviceResolver()) {
        self.bluetoothResolver = bluetoothResolver
    }

    public func readDevices(now: Date = Date()) throws -> [BatteryDevice] {
        let identities = try bluetoothResolver.readBluetoothDeviceIdentities()
        return Self.makeDevices(now: now, bluetoothIdentities: identities)
    }

    public static func makeDevices(
        now: Date,
        bluetoothIdentities: [BluetoothDeviceIdentity]
    ) -> [BatteryDevice] {
        bluetoothIdentities.flatMap { identity -> [BatteryDevice] in
            let name = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !identity.address.isEmpty else {
                return []
            }

            var devices: [BatteryDevice] = []
            let earbudLevels = [identity.batteryLevelLeft, identity.batteryLevelRight].compactMap { $0 }
            let mainLevel = identity.batteryLevelMain ?? earbudLevels.min()

            if let mainLevel {
                devices.append(makeDevice(
                    name: name,
                    stableIdentifier: identity.address,
                    percentage: mainLevel,
                    now: now
                ))
            }

            if let caseLevel = identity.batteryLevelCase {
                devices.append(makeDevice(
                    name: "\(name)充电盒",
                    stableIdentifier: "\(identity.address)-case",
                    percentage: caseLevel,
                    now: now
                ))
            }

            return devices
        }
    }

    public static func makeDevice(
        name: String,
        stableIdentifier: String,
        percentage: Int,
        now: Date
    ) -> BatteryDevice {
        BatteryDevice(
            id: BatteryDevice.makeID(
                name: name,
                kind: .peripheral,
                source: "SystemProfiler",
                stableIdentifier: stableIdentifier
            ),
            name: name,
            kind: .peripheral,
            percentage: percentage,
            isCharging: nil,
            isConnected: true,
            source: "SystemProfiler",
            updatedAt: now
        )
    }
}

public final class BluetoothLEBatteryServiceReader: BatteryReading, @unchecked Sendable {
    private let timeout: TimeInterval
    private let session = BluetoothLEBatteryServiceSession()

    public init(timeout: TimeInterval = 4) {
        self.timeout = timeout
    }

    public func readDevices(now: Date = Date()) throws -> [BatteryDevice] {
        session.readBatteryDevices(now: now, timeout: timeout)
    }

    public static func makeDevice(
        name: String?,
        identifier: UUID,
        percentage: Int,
        now: Date
    ) -> BatteryDevice {
        let deviceName = nonEmpty(name) ?? "Bluetooth LE Battery Device"
        return BatteryDevice(
            id: BatteryDevice.makeID(
                name: deviceName,
                kind: .peripheral,
                source: "CoreBluetooth",
                stableIdentifier: identifier.uuidString
            ),
            name: deviceName,
            kind: .peripheral,
            percentage: percentage,
            // The BLE Battery Service only reports a level, not charging state.
            isCharging: nil,
            isConnected: true,
            source: "CoreBluetooth",
            updatedAt: now
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// One long-lived CoreBluetooth session shared by every read. The central
/// manager is created once and its callbacks are delivered on `queue`; all
/// mutable state is confined to that queue. `readBatteryDevices` blocks the
/// calling thread on a semaphore until the session finishes or times out, so
/// it stays safe to call from any thread without touching the main run loop.
private final class BluetoothLEBatteryServiceSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lacdon.batterymonitor.ble-battery-reader")
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private var centralManager: CBCentralManager?

    // Session state, accessed only on `queue`.
    private var now = Date()
    private var pendingPeripheralIDs = Set<UUID>()
    private var sessionConnectedPeripheralIDs = Set<UUID>()
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var devices: [BatteryDevice] = []
    private var completion: DispatchSemaphore?
    private var isCollecting = false

    func readBatteryDevices(now: Date, timeout: TimeInterval) -> [BatteryDevice] {
        let semaphore = DispatchSemaphore(value: 0)
        queue.sync {
            self.now = now
            self.devices = []
            self.pendingPeripheralIDs = []
            self.sessionConnectedPeripheralIDs = []
            self.peripheralsByID = [:]
            self.completion = semaphore
            self.isCollecting = true
            self.startSessionOnQueue()
        }

        _ = semaphore.wait(timeout: .now() + timeout)

        var result: [BatteryDevice] = []
        queue.sync {
            result = self.devices
            self.endSessionOnQueue()
        }
        return result
    }

    private func startSessionOnQueue() {
        guard let centralManager else {
            // State arrives asynchronously via centralManagerDidUpdateState.
            centralManager = CBCentralManager(delegate: self, queue: queue)
            return
        }

        handleStateOnQueue(centralManager.state)
    }

    private func handleStateOnQueue(_ state: CBManagerState) {
        guard isCollecting else {
            return
        }

        switch state {
        case .poweredOn:
            discoverConnectedPeripheralsOnQueue()
        case .poweredOff, .unauthorized, .unsupported:
            signalCompletionOnQueue()
        case .unknown, .resetting:
            break // Wait for the next state update or the caller's timeout.
        @unknown default:
            signalCompletionOnQueue()
        }
    }

    private func discoverConnectedPeripheralsOnQueue() {
        guard let centralManager else {
            signalCompletionOnQueue()
            return
        }

        let peripherals = centralManager.retrieveConnectedPeripherals(withServices: [batteryServiceUUID])
        guard !peripherals.isEmpty else {
            signalCompletionOnQueue()
            return
        }

        for peripheral in peripherals {
            peripheralsByID[peripheral.identifier] = peripheral
            pendingPeripheralIDs.insert(peripheral.identifier)
            peripheral.delegate = self

            if peripheral.state == .connected {
                peripheral.discoverServices([batteryServiceUUID])
            } else {
                centralManager.connect(peripheral)
            }
        }
    }

    private func endSessionOnQueue() {
        for identifier in sessionConnectedPeripheralIDs {
            if let peripheral = peripheralsByID[identifier] {
                centralManager?.cancelPeripheralConnection(peripheral)
            }
        }
        isCollecting = false
        completion = nil
    }

    private func signalCompletionOnQueue() {
        completion?.signal()
        completion = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleStateOnQueue(central.state)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isCollecting else {
            central.cancelPeripheralConnection(peripheral)
            return
        }

        sessionConnectedPeripheralIDs.insert(peripheral.identifier)
        peripheral.delegate = self
        peripheral.discoverServices([batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishOnQueue(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        finishOnQueue(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCollecting else {
            return
        }

        guard error == nil,
              let services = peripheral.services,
              let batteryService = services.first(where: { $0.uuid == batteryServiceUUID }) else {
            finishOnQueue(peripheral)
            return
        }

        peripheral.discoverCharacteristics([batteryLevelUUID], for: batteryService)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCollecting else {
            return
        }

        guard error == nil,
              let characteristics = service.characteristics,
              let batteryLevel = characteristics.first(where: { $0.uuid == batteryLevelUUID }) else {
            finishOnQueue(peripheral)
            return
        }

        peripheral.readValue(for: batteryLevel)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCollecting else {
            return
        }

        defer {
            finishOnQueue(peripheral)
        }

        guard error == nil,
              characteristic.uuid == batteryLevelUUID,
              let value = characteristic.value?.first else {
            return
        }

        devices.append(BluetoothLEBatteryServiceReader.makeDevice(
            name: peripheral.name,
            identifier: peripheral.identifier,
            percentage: Int(value),
            now: now
        ))
    }

    private func finishOnQueue(_ peripheral: CBPeripheral) {
        guard isCollecting else {
            return
        }

        pendingPeripheralIDs.remove(peripheral.identifier)
        if pendingPeripheralIDs.isEmpty {
            signalCompletionOnQueue()
        }
    }
}

public struct IORegistryBatteryDiagnostic: Equatable, Sendable {
    private static let batteryChargingFlag = 1 << 1

    public var name: String
    public var address: String
    public var percentage: Int
    public var chargingFields: [String]
    public var batteryStatusFlags: String?
    public var supportsExtendedBatteryState: String?

    public var inferredChargingState: Bool? {
        guard let flags = Self.intValue(batteryStatusFlags) else {
            return nil
        }

        if Self.extendedBatteryStateSupported(supportsExtendedBatteryState) {
            return (flags & Self.batteryChargingFlag) != 0
        }

        if flags == 0 {
            return false
        }

        return nil
    }

    public init(
        name: String,
        address: String,
        percentage: Int,
        chargingFields: [String],
        batteryStatusFlags: String?,
        supportsExtendedBatteryState: String?
    ) {
        self.name = name
        self.address = address
        self.percentage = BatteryPercentage.clamp(percentage)
        self.chargingFields = chargingFields
        self.batteryStatusFlags = batteryStatusFlags
        self.supportsExtendedBatteryState = supportsExtendedBatteryState
    }

    private static func extendedBatteryStateSupported(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "1":
            return true
        default:
            return false
        }
    }

    private static func intValue(_ value: String?) -> Int? {
        guard let value else {
            return nil
        }

        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum BatterySourceDiagnosticsRenderer {
    public static func render(ioRegistry diagnostics: [IORegistryBatteryDiagnostic]) -> String {
        guard !diagnostics.isEmpty else {
            return """
            IORegistry battery diagnostics
            No IORegistry BatteryPercent peripheral records found.
            """
        }

        var lines = [
            "IORegistry battery diagnostics",
            "Name\tBattery\tChargingFields\tBatteryStatusFlags\tDecodedCharging\tSupportsExtendedBatteryState\tAddress"
        ]
        lines += diagnostics.map { diagnostic in
            [
                diagnostic.name,
                "\(diagnostic.percentage)%",
                diagnostic.chargingFields.isEmpty ? "not reported" : diagnostic.chargingFields.joined(separator: ", "),
                diagnostic.batteryStatusFlags ?? "not reported",
                chargingText(diagnostic.inferredChargingState),
                diagnostic.supportsExtendedBatteryState ?? "not reported",
                diagnostic.address.isEmpty ? "not reported" : diagnostic.address
            ].joined(separator: "\t")
        }
        return lines.joined(separator: "\n")
    }

    private static func chargingText(_ isCharging: Bool?) -> String {
        switch isCharging {
        case true:
            return "charging"
        case false:
            return "not charging"
        case nil:
            return "not reported"
        }
    }
}

public final class IORegistryBatteryReader: BatteryReading, @unchecked Sendable {
    private let commandRunner: any CommandRunning
    private let bluetoothResolver: (any BluetoothDeviceResolving)?

    public init(
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        bluetoothResolver: (any BluetoothDeviceResolving)? = nil
    ) {
        self.commandRunner = commandRunner
        self.bluetoothResolver = bluetoothResolver ?? SystemProfilerBluetoothDeviceResolver(commandRunner: commandRunner)
    }

    public func readDevices(now: Date = Date()) throws -> [BatteryDevice] {
        let result = try commandRunner.run(
            executablePath: "/usr/sbin/ioreg",
            arguments: ["-r", "-l", "-k", "BatteryPercent"]
        )
        let bluetoothIdentities = (try? bluetoothResolver?.readBluetoothDeviceIdentities()) ?? []
        return Self.parseDevices(
            from: result.standardOutput,
            now: now,
            bluetoothIdentities: bluetoothIdentities
        )
    }

    public func readDiagnostics() throws -> [IORegistryBatteryDiagnostic] {
        let result = try commandRunner.run(
            executablePath: "/usr/sbin/ioreg",
            arguments: ["-r", "-l", "-k", "BatteryPercent"]
        )
        let bluetoothIdentities = (try? bluetoothResolver?.readBluetoothDeviceIdentities()) ?? []
        return Self.parseDiagnostics(
            from: result.standardOutput,
            bluetoothIdentities: bluetoothIdentities
        )
    }

    public static func parseDevices(
        from output: String,
        now: Date,
        bluetoothIdentities: [BluetoothDeviceIdentity] = []
    ) -> [BatteryDevice] {
        let records = parseRecords(from: output)
        var identitiesByAddress: [String: BluetoothDeviceIdentity] = [:]
        for identity in bluetoothIdentities {
            let address = normalizedAddress(identity.address)
            guard !address.isEmpty, identitiesByAddress[address] == nil else {
                continue
            }
            identitiesByAddress[address] = identity
        }

        return records.compactMap { record in
            makeDevice(from: record, now: now, identitiesByAddress: identitiesByAddress)
        }
    }

    public static func parseDiagnostics(
        from output: String,
        bluetoothIdentities: [BluetoothDeviceIdentity] = []
    ) -> [IORegistryBatteryDiagnostic] {
        let records = parseRecords(from: output)
        var identitiesByAddress: [String: BluetoothDeviceIdentity] = [:]
        for identity in bluetoothIdentities {
            let address = normalizedAddress(identity.address)
            guard !address.isEmpty, identitiesByAddress[address] == nil else {
                continue
            }
            identitiesByAddress[address] = identity
        }

        return records.compactMap { record in
            diagnostic(from: record, identitiesByAddress: identitiesByAddress)
        }
    }

    private static func parseRecords(from output: String) -> [[String: String]] {
        var records: [[String: String]] = []
        var current: [String: String] = [:]

        func flushCurrent() {
            guard !current.isEmpty else {
                return
            }
            records.append(current)
            current.removeAll()
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("+-o ") || trimmed.hasPrefix("|-o ") {
                flushCurrent()
                continue
            }

            guard let property = parsePropertyLine(trimmed) else {
                continue
            }
            current[property.key] = property.value
        }

        flushCurrent()
        return records
    }

    private static func parsePropertyLine(_ line: String) -> (key: String, value: String)? {
        guard line.hasPrefix("\""),
              let keyEnd = line.dropFirst().firstIndex(of: "\"") else {
            return nil
        }

        let key = String(line[line.index(after: line.startIndex)..<keyEnd])
        guard let equals = line[keyEnd...].firstIndex(of: "=") else {
            return nil
        }

        let valueStart = line.index(after: equals)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, strippedValue(rawValue))
    }

    private static func strippedValue(_ value: String) -> String {
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func makeDevice(
        from record: [String: String],
        now: Date,
        identitiesByAddress: [String: BluetoothDeviceIdentity]
    ) -> BatteryDevice? {
        guard let percentage = intValue(record["BatteryPercent"]),
              (boolValue(record["HasBattery"]) ?? true),
              !(boolValue(record["Built-In"]) ?? false) else {
            return nil
        }

        let address = normalizedAddress(record["DeviceAddress"] ?? record["SerialNumber"] ?? "")
        let identity = identitiesByAddress[address]
        let productID = intValue(record["ProductID"])
        let modelName = productModelName(productID: productID)
        let name = resolvedName(
            product: nonEmpty(record["Product"]),
            identity: identity,
            modelName: modelName,
            address: address
        )
        let stableIdentifier = nonEmpty(record["DeviceAddress"])
            ?? nonEmpty(record["SerialNumber"])
            ?? nonEmpty(record["LocationID"])
            ?? name

        return BatteryDevice(
            id: BatteryDevice.makeID(
                name: name,
                kind: .peripheral,
                source: "IORegistry",
                stableIdentifier: stableIdentifier
            ),
            name: name,
            kind: .peripheral,
            percentage: percentage,
            isCharging: chargingState(from: record),
            isConnected: true,
            source: "IORegistry",
            updatedAt: now
        )
    }

    private static func diagnostic(
        from record: [String: String],
        identitiesByAddress: [String: BluetoothDeviceIdentity]
    ) -> IORegistryBatteryDiagnostic? {
        guard let percentage = intValue(record["BatteryPercent"]),
              (boolValue(record["HasBattery"]) ?? true),
              !(boolValue(record["Built-In"]) ?? false) else {
            return nil
        }

        let address = normalizedAddress(record["DeviceAddress"] ?? record["SerialNumber"] ?? "")
        let identity = identitiesByAddress[address]
        let name = resolvedName(
            product: nonEmpty(record["Product"]),
            identity: identity,
            modelName: productModelName(productID: intValue(record["ProductID"])),
            address: address
        )

        return IORegistryBatteryDiagnostic(
            name: name,
            address: nonEmpty(record["DeviceAddress"]) ?? nonEmpty(record["SerialNumber"]) ?? address,
            percentage: percentage,
            chargingFields: chargingFieldDiagnostics(from: record),
            batteryStatusFlags: nonEmpty(record["BatteryStatusFlags"]),
            supportsExtendedBatteryState: nonEmpty(record["SupportsExtendedBatteryState"])
        )
    }

    private static func chargingState(from record: [String: String]) -> Bool? {
        if let isCharging = boolValue(record["IsCharging"])
            ?? boolValue(record["Is Charging"])
            ?? boolValue(record["Charging"]) {
            return isCharging
        }

        if (boolValue(record["FullyCharged"])
            ?? boolValue(record["Fully Charged"])) == true {
            return false
        }

        if let flags = intValue(record["BatteryStatusFlags"]) {
            if boolValue(record["SupportsExtendedBatteryState"]) == true {
                return (flags & (1 << 1)) != 0
            }

            if flags == 0 {
                return false
            }
        }

        return nil
    }

    private static func chargingFieldDiagnostics(from record: [String: String]) -> [String] {
        [
            "IsCharging",
            "Is Charging",
            "Charging",
            "FullyCharged",
            "Fully Charged",
            "ChargeStatus"
        ].compactMap { key in
            nonEmpty(record[key]).map { "\(key)=\($0)" }
        }
    }

    private static func resolvedName(
        product: String?,
        identity: BluetoothDeviceIdentity?,
        modelName: String?,
        address: String
    ) -> String {
        if let product {
            return product
        }

        if let identityName = nonEmpty(identity?.name) {
            guard let modelName, !containsModel(identityName, modelName: modelName) else {
                return identityName
            }
            return "\(identityName) (\(modelName))"
        }

        if let modelName {
            return modelName
        }

        if let minorType = nonEmpty(identity?.minorType) {
            return minorType
        }

        return fallbackName(address: address)
    }

    private static func containsModel(_ name: String, modelName: String) -> Bool {
        name.range(of: modelName, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func productModelName(productID: Int?) -> String? {
        guard let productID else {
            return nil
        }

        switch productID {
        case 0x0269:
            return "Magic Mouse"
        case 0x0265:
            return "Magic Trackpad"
        case 0x026C, 0x0322:
            return "Magic Keyboard"
        default:
            return nil
        }
    }

    private static func fallbackName(address: String) -> String {
        guard address.count >= 4 else {
            return "External Battery Device"
        }

        return "Bluetooth Device \(address.suffix(4).uppercased())"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func intValue(_ value: String?) -> Int? {
        guard let value else {
            return nil
        }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func boolValue(_ value: String?) -> Bool? {
        guard let value else {
            return nil
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "1":
            return true
        case "no", "false", "0":
            return false
        default:
            return nil
        }
    }
}

/// Reads the accessory power sources that powerd publishes for Bluetooth
/// peripherals: AirPods earbuds and their charging case, Magic accessories,
/// and BLE devices. This is the same data the system battery widget renders,
/// and it is the only source that carries a real `Is Charging` flag for
/// AirPods-style devices. `IOPSCopyPowerSourcesByType` is exported by IOKit
/// but not declared in the public macOS headers, so the symbol is resolved at
/// runtime and the reader returns nothing if it ever disappears.
public final class AccessoryPowerSourceReader: BatteryReading, @unchecked Sendable {
    private typealias CopyPowerSourcesByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private static let allPowerSourcesType: Int32 = 0

    public init() {}

    public func readDevices(now: Date = Date()) throws -> [BatteryDevice] {
        guard let handle = dlopen(nil, RTLD_LAZY) else {
            return []
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else {
            return []
        }

        let copyPowerSourcesByType = unsafeBitCast(symbol, to: CopyPowerSourcesByType.self)
        guard let snapshotRef = copyPowerSourcesByType(Self.allPowerSourcesType) else {
            return []
        }
        let snapshot = snapshotRef.takeRetainedValue()

        guard let sourcesRef = IOPSCopyPowerSourcesList(snapshot) else {
            return []
        }
        let sources = sourcesRef.takeRetainedValue() as NSArray

        let descriptions = sources.compactMap { source -> [String: Any]? in
            guard let descriptionRef = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef) else {
                return nil
            }
            return descriptionRef.takeUnretainedValue() as? [String: Any]
        }

        return Self.makeDevices(from: descriptions, now: now)
    }

    public static func makeDevices(from descriptions: [[String: Any]], now: Date) -> [BatteryDevice] {
        descriptions.compactMap { description in
            guard stringValue(in: description, key: kIOPSTypeKey) == "Accessory Source" else {
                return nil
            }
            if let isPresent = boolValue(in: description, key: "Is Present"), !isPresent {
                return nil
            }
            guard let name = stringValue(in: description, key: kIOPSNameKey),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let current = intValue(in: description, key: kIOPSCurrentCapacityKey) else {
                return nil
            }

            let maxCapacity = intValue(in: description, key: kIOPSMaxCapacityKey) ?? 100
            let percentage = BatteryPercentage.calculate(current: current, max: maxCapacity)
            guard percentage > 0 else {
                return nil
            }

            let stableIdentifier = stringValue(in: description, key: "Accessory Identifier") ?? name
            return BatteryDevice(
                id: BatteryDevice.makeID(
                    name: name,
                    kind: .peripheral,
                    source: "PowerSources",
                    stableIdentifier: stableIdentifier
                ),
                name: name,
                kind: .peripheral,
                percentage: percentage,
                isCharging: boolValue(in: description, key: kIOPSIsChargingKey),
                isConnected: true,
                source: "PowerSources",
                updatedAt: now
            )
        }
    }

    private static func stringValue(in dictionary: [String: Any], key: String) -> String? {
        dictionary[key] as? String
    }

    private static func intValue(in dictionary: [String: Any], key: String) -> Int? {
        (dictionary[key] as? NSNumber)?.intValue
    }

    private static func boolValue(in dictionary: [String: Any], key: String) -> Bool? {
        (dictionary[key] as? NSNumber)?.boolValue
    }
}

public final class IOKitPowerSourceReader: BatteryReading, @unchecked Sendable {
    public init() {}

    public func readDevices(now: Date = Date()) throws -> [BatteryDevice] {
        guard let snapshotRef = IOPSCopyPowerSourcesInfo() else {
            throw BatteryReadError.unavailablePowerSourceSnapshot
        }
        let snapshot = snapshotRef.takeRetainedValue()

        guard let sourcesRef = IOPSCopyPowerSourcesList(snapshot) else {
            throw BatteryReadError.unavailablePowerSourceList
        }

        let sources = sourcesRef.takeRetainedValue() as NSArray
        return sources.compactMap { source in
            parsePowerSource(snapshot: snapshot, source: source as CFTypeRef, now: now)
        }
    }

    private func parsePowerSource(snapshot: CFTypeRef, source: CFTypeRef, now: Date) -> BatteryDevice? {
        guard let descriptionRef = IOPSGetPowerSourceDescription(snapshot, source) else {
            return nil
        }

        let description = descriptionRef.takeUnretainedValue() as NSDictionary
        let name = stringValue(in: description, key: kIOPSNameKey) ?? "Unknown Battery"
        let type = stringValue(in: description, key: kIOPSTypeKey)
        let transportType = stringValue(in: description, key: "Transport Type")
        let current = intValue(in: description, key: kIOPSCurrentCapacityKey)
            ?? intValue(in: description, key: "Current")
            ?? 0
        let maxCapacity = intValue(in: description, key: kIOPSMaxCapacityKey) ?? 100
        let percentage = BatteryPercentage.calculate(current: current, max: maxCapacity)
        let isCharging = boolValue(in: description, key: kIOPSIsChargingKey)
            ?? boolValue(in: description, key: "IsCharging")
        let isConnected = boolValue(in: description, key: "Is Present") ?? true
        let kind = deviceKind(name: name, type: type, transportType: transportType)
        let stableIdentifier = stringValue(in: description, key: "Hardware Serial Number")
            ?? stringValue(in: description, key: "Power Source ID")
            ?? "\(name)-\(type ?? "unknown")-\(transportType ?? "unknown")"
        let id = BatteryDevice.makeID(
            name: name,
            kind: kind,
            source: "IOKit",
            stableIdentifier: stableIdentifier
        )

        return BatteryDevice(
            id: id,
            name: name,
            kind: kind,
            percentage: percentage,
            isCharging: isCharging,
            isConnected: isConnected,
            source: "IOKit",
            updatedAt: now
        )
    }

    private func deviceKind(name: String, type: String?, transportType: String?) -> DeviceKind {
        let normalizedName = name.lowercased()
        let normalizedType = type?.lowercased() ?? ""
        let normalizedTransport = transportType?.lowercased() ?? ""

        if normalizedType == kIOPSInternalBatteryType.lowercased()
            || normalizedName.contains("internalbattery")
            || normalizedTransport == "internal" {
            return .internalBattery
        }

        if normalizedType.contains("ups") {
            return .ups
        }

        if normalizedType.contains("battery") || normalizedTransport.contains("bluetooth") {
            return .peripheral
        }

        return .unknown
    }

    private func stringValue(in dictionary: NSDictionary, key: String) -> String? {
        if let value = dictionary[key] as? String {
            return value
        }
        if let value = dictionary[key] as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func intValue(in dictionary: NSDictionary, key: String) -> Int? {
        if let value = dictionary[key] as? Int {
            return value
        }
        if let value = dictionary[key] as? NSNumber {
            return value.intValue
        }
        if let value = dictionary[key] as? String {
            return Int(value)
        }
        return nil
    }

    private func boolValue(in dictionary: NSDictionary, key: String) -> Bool? {
        if let value = dictionary[key] as? Bool {
            return value
        }
        if let value = dictionary[key] as? NSNumber {
            return value.boolValue
        }
        if let value = dictionary[key] as? String {
            switch value.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
