import BatteryMonitorShared
import Foundation

public enum DeviceTableRenderer {
    public static func render(devices: [BatteryDevice]) -> String {
        guard !devices.isEmpty else {
            return "No battery devices found."
        }

        var lines = [
            "Name\tKind\tBattery\tCharging\tSource\tID"
        ]
        lines += devices.map { device in
            [
                device.name,
                device.kind.rawValue,
                "\(device.percentage)%",
                chargingText(device.isCharging),
                device.source,
                device.id
            ].joined(separator: "\t")
        }
        return lines.joined(separator: "\n")
    }

    private static func chargingText(_ isCharging: Bool?) -> String {
        switch isCharging {
        case .some(true):
            return "charging"
        case .some(false):
            return "not charging"
        case .none:
            return "not reported"
        }
    }
}
