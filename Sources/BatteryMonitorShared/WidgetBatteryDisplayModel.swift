import Foundation

public struct WidgetBatteryDisplayModel: Equatable, Sendable {
    public var devices: [BatteryDevice]
    public var lastUpdatedAt: Date
    public var renderedAt: Date
    public var hasSnapshot: Bool
    public var lowBatteryThreshold: Int

    public init(
        snapshot: BatterySnapshot?,
        fallbackDate: Date,
        lowBatteryThreshold: Int = MonitorSettings.default.lowBatteryThreshold
    ) {
        self.devices = snapshot?.connectedDevices ?? []
        self.lastUpdatedAt = snapshot?.updatedAt ?? fallbackDate
        self.renderedAt = fallbackDate
        self.hasSnapshot = snapshot != nil
        self.lowBatteryThreshold = BatteryPercentage.clamp(lowBatteryThreshold)
    }

    public var lowestDevice: BatteryDevice? {
        devices.min { lhs, rhs in
            if lhs.percentage == rhs.percentage {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.percentage < rhs.percentage
        }
    }

    public static let mediumDeviceLimit = 3
    public static let largeDeviceLimit = 8

    public var mediumDevices: [BatteryDevice] {
        Array(devices.prefix(Self.mediumDeviceLimit))
    }

    public var largeDevices: [BatteryDevice] {
        Array(devices.prefix(Self.largeDeviceLimit))
    }

    public var freshnessText: String {
        guard hasSnapshot else {
            return L10n.text(.widgetNoCache)
        }

        let elapsedSeconds = max(0, Int(renderedAt.timeIntervalSince(lastUpdatedAt)))
        if elapsedSeconds < 60 {
            return L10n.text(.widgetJustUpdated)
        }

        let elapsedMinutes = elapsedSeconds / 60
        if elapsedMinutes < 60 {
            return L10n.format(.widgetMinutesAgo, elapsedMinutes)
        }

        return L10n.format(.widgetCachedAt, lastUpdatedAt.formatted(date: .omitted, time: .shortened) as CVarArg)
    }

    public func isLowBattery(_ device: BatteryDevice) -> Bool {
        device.percentage < lowBatteryThreshold
    }
}
