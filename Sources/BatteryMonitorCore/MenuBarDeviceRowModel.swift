import BatteryMonitorShared
import Foundation

public struct MenuBarDeviceRowModel: Equatable, Sendable {
    public var name: String
    public var percentageText: String
    public var statusText: String
    public var symbolName: String
    public var isLowBattery: Bool
    public var isCharging: Bool

    public init(device: BatteryDevice, threshold: Int) {
        name = device.name
        percentageText = "\(device.percentage)%"
        statusText = Self.statusText(for: device)
        symbolName = DeviceSymbol.name(for: device)
        isLowBattery = device.isConnected
            && device.percentage < BatteryPercentage.clamp(threshold)
            && device.isLowBatteryRelevantWhileCharging
        isCharging = device.isActivelyCharging
    }

    private static func statusText(for device: BatteryDevice) -> String {
        device.isConnected
            ? device.userVisibleChargingStatusText
            : L10n.text(.statusDisconnected)
    }
}
