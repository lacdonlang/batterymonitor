import Foundation

public enum WidgetDisplayReportRenderer {
    public static func render(snapshot: BatterySnapshot?, renderedAt: Date) -> String {
        let model = WidgetBatteryDisplayModel(snapshot: snapshot, fallbackDate: renderedAt)
        let small = model.lowestDevice.map { deviceLine($0, model: model) } ?? "暂无数据"
        let medium = deviceList(model.mediumDevices, model: model)
        let large = deviceList(model.largeDevices, model: model)

        return """
        Widget display report
        Has snapshot: \(model.hasSnapshot)
        Freshness: \(model.freshnessText)
        Last updated: \(ISO8601DateFormatter().string(from: model.lastUpdatedAt))
        Rendered at: \(ISO8601DateFormatter().string(from: model.renderedAt))
        Low battery threshold: \(model.lowBatteryThreshold)%

        Small:
        - \(small)

        Medium:
        \(medium)

        Large:
        \(large)
        """
    }

    private static func deviceList(_ devices: [BatteryDevice], model: WidgetBatteryDisplayModel) -> String {
        guard !devices.isEmpty else {
            return "- 暂无数据"
        }

        return devices
            .map { "- \(deviceLine($0, model: model))" }
            .joined(separator: "\n")
    }

    private static func deviceLine(_ device: BatteryDevice, model: WidgetBatteryDisplayModel) -> String {
        let lowText = model.isLowBattery(device) ? "low" : "normal"
        return "\(device.name) | \(device.percentage)% | \(statusText(for: device)) | \(lowText)"
    }

    private static func statusText(for device: BatteryDevice) -> String {
        device.userVisibleChargingStatusText
    }
}
