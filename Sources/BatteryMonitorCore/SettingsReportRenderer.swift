import BatteryMonitorShared
import Foundation

public enum SettingsReportRenderer {
    public static func render(settings: MonitorSettings, snapshot: BatterySnapshot?, renderedAt: Date) -> String {
        var lines = [
            "Settings report",
            "Rendered at: \(ISO8601DateFormatter().string(from: renderedAt))",
            "Low battery threshold: \(settings.lowBatteryThreshold)%",
            "Recovery threshold: \(settings.recoveryThreshold)%",
            "Polling interval: \(Int(settings.pollingInterval))s",
            "Reminder cooldown: \(Int(settings.reminderCooldown))s",
            "Launch at login preference: \(settings.launchAtLogin)",
            "Ignored device IDs: \(listText(settings.ignoredDeviceIDs))",
            "Ignored device fingerprints: \(listText(settings.ignoredDeviceFingerprints))"
        ]

        guard let snapshot else {
            lines += [
                "Snapshot devices: 0",
                "Device settings impact:",
                "- no snapshot provided"
            ]
            return lines.joined(separator: "\n")
        }

        lines += [
            "Snapshot updated at: \(ISO8601DateFormatter().string(from: snapshot.updatedAt))",
            "Snapshot devices: \(snapshot.devices.count)",
            "Device settings impact:"
        ]

        if snapshot.devices.isEmpty {
            lines.append("- no devices")
            return lines.joined(separator: "\n")
        }

        lines += snapshot.devices.map { deviceLine($0, settings: settings) }
        return lines.joined(separator: "\n")
    }

    private static func deviceLine(_ device: BatteryDevice, settings: MonitorSettings) -> String {
        let ignored = settings.isIgnored(device)
        let low = device.isConnected && device.percentage < settings.lowBatteryThreshold
        let recovered = device.percentage >= settings.recoveryThreshold
        let chargingSuppressed = device.isCharging == true && low
        let impact: String

        if !device.isConnected {
            impact = "disconnected"
        } else if ignored {
            impact = "ignored"
        } else if chargingSuppressed {
            impact = "charging suppressed"
        } else if low {
            impact = "low under threshold"
        } else if recovered {
            impact = "recovered"
        } else {
            impact = "active"
        }

        return "- \(device.name) | \(device.percentage)% | \(chargingText(device.isCharging)) | \(impact) | \(device.id)"
    }

    private static func chargingText(_ isCharging: Bool?) -> String {
        switch isCharging {
        case .some(true):
            return "charging"
        case .some(false):
            return "not charging"
        case .none:
            return "macOS not reported"
        }
    }

    private static func listText(_ values: Set<String>) -> String {
        let sortedValues = values.sorted()
        return sortedValues.isEmpty ? "none" : sortedValues.joined(separator: ", ")
    }
}
