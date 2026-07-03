import Foundation

public enum DeviceKind: String, Codable, Equatable, Sendable {
    case internalBattery
    case peripheral
    case ups
    case unknown
}

public struct BatteryDevice: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: DeviceKind
    public var percentage: Int
    public var isCharging: Bool?
    public var isConnected: Bool
    public var source: String
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        kind: DeviceKind,
        percentage: Int,
        isCharging: Bool?,
        isConnected: Bool,
        source: String,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.percentage = BatteryPercentage.clamp(percentage)
        self.isCharging = isCharging
        self.isConnected = isConnected
        self.source = source
        self.updatedAt = updatedAt
    }
}

public struct BatterySnapshot: Codable, Equatable, Sendable {
    public var devices: [BatteryDevice]
    public var updatedAt: Date

    public init(devices: [BatteryDevice], updatedAt: Date) {
        self.devices = devices.sorted { lhs, rhs in
            if lhs.kind == rhs.kind {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.kind.sortOrder < rhs.kind.sortOrder
        }
        self.updatedAt = updatedAt
    }

    public static func empty(updatedAt: Date = Date()) -> BatterySnapshot {
        BatterySnapshot(devices: [], updatedAt: updatedAt)
    }

    /// Devices to show and alert on. Disconnected devices stay in `devices`
    /// for notification-state continuity (see MonitorEngine retention) but
    /// are hidden from every display surface; the settings ignore-list is the
    /// one place that deliberately reads the raw `devices`.
    public var connectedDevices: [BatteryDevice] {
        devices.filter(\.isConnected)
    }
}

public struct DeviceNotificationState: Codable, Equatable, Sendable {
    public var deviceID: String
    public var lastNotifiedAt: Date?
    public var wasLowBattery: Bool
    public var lastSeenPercentage: Int?
    public var updatedAt: Date
    public var deviceName: String?
    public var deviceKind: DeviceKind?
    public var deviceSource: String?

    public init(
        deviceID: String,
        lastNotifiedAt: Date?,
        wasLowBattery: Bool,
        lastSeenPercentage: Int?,
        updatedAt: Date,
        deviceName: String? = nil,
        deviceKind: DeviceKind? = nil,
        deviceSource: String? = nil
    ) {
        self.deviceID = deviceID
        self.lastNotifiedAt = lastNotifiedAt
        self.wasLowBattery = wasLowBattery
        self.lastSeenPercentage = lastSeenPercentage
        self.updatedAt = updatedAt
        self.deviceName = deviceName
        self.deviceKind = deviceKind
        self.deviceSource = deviceSource
    }
}

public struct LowBatteryAlert: Equatable, Sendable {
    public var device: BatteryDevice
    public var threshold: Int

    public init(device: BatteryDevice, threshold: Int) {
        self.device = device
        self.threshold = threshold
    }
}

public extension BatteryDevice {
    static func makeID(
        name: String,
        kind: DeviceKind,
        source: String,
        stableIdentifier: String? = nil
    ) -> String {
        let rawIdentifier = stableIdentifier?.isEmpty == false
            ? stableIdentifier!
            : "\(name)-\(kind.rawValue)-\(source)"
        let normalized = rawIdentifier
            .lowercased()
            .unicodeScalars
            .map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" {
                    return
                }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return "\(source.lowercased()):\(normalized)"
    }

    var isLowBatteryRelevantWhileCharging: Bool {
        if isCharging == true {
            return false
        }
        return true
    }

    /// True when the device is present and macOS reports it charging.
    var isActivelyCharging: Bool {
        isConnected && isCharging == true
    }

    var userVisibleChargingStatusText: String {
        if !isConnected {
            return L10n.text(.statusNotConnected)
        }

        switch isCharging {
        case .some(true):
            return L10n.text(.statusCharging)
        case .some(false):
            return L10n.text(.statusNotCharging)
        case .none:
            // AirPods-style peripherals never report charging state, so claim
            // neither charging nor discharging.
            return kind == .peripheral ? L10n.text(.statusConnected) : L10n.text(.statusChargingUnreported)
        }
    }
}

private extension DeviceKind {
    var sortOrder: Int {
        switch self {
        case .internalBattery:
            return 0
        case .peripheral:
            return 1
        case .ups:
            return 2
        case .unknown:
            return 3
        }
    }
}
