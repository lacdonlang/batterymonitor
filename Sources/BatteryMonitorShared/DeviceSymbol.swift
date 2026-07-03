import Foundation

/// Maps a device to the SF Symbol shown next to it in the menu bar list and
/// the widget. Lives in Shared so the widget (which doesn't link Core) can
/// use the same icons.
public enum DeviceSymbol {
    public static func name(for device: BatteryDevice) -> String {
        switch device.kind {
        case .internalBattery:
            return "laptopcomputer"
        case .peripheral:
            return peripheralSymbolName(for: device.name)
        case .ups:
            return "powerplug"
        case .unknown:
            return "battery.50"
        }
    }

    private static func peripheralSymbolName(for name: String) -> String {
        // Match on a lowercased, space-free name so "Air Pods Pro 2" and
        // "AirPods Pro" hit the same rules.
        let normalized = name.lowercased().replacingOccurrences(of: " ", with: "")

        if normalized.contains("充电盒") || normalized.contains("chargingcase")
            || (normalized.contains("airpods") && normalized.contains("case")) {
            return "airpodspro.chargingcase.wireless"
        }
        if normalized.contains("airpods") && normalized.contains("max") {
            return "airpods.max"
        }
        if normalized.contains("airpods") && normalized.contains("pro") {
            return "airpods.pro"
        }
        if normalized.contains("airpods") || normalized.contains("earbuds") {
            return "airpods"
        }
        if normalized.contains("headphone") || normalized.contains("headset") || normalized.contains("耳机") {
            return "headphones"
        }
        if normalized.contains("magicmouse") {
            return "magicmouse"
        }
        if normalized.contains("mouse") || normalized.contains("鼠标") || normalized.contains("mxmaster")
            || normalized.contains("trackball") {
            return "computermouse"
        }
        if normalized.contains("keyboard") || normalized.contains("键盘") {
            return "keyboard"
        }
        if normalized.contains("trackpad") || normalized.contains("触控板") {
            return "rectangle.and.hand.point.up.left"
        }
        if normalized.contains("iphone") || normalized.contains("手机") {
            return "iphone"
        }
        if normalized.contains("ipad") {
            return "ipad"
        }
        if normalized.contains("watch") || normalized.contains("手表") {
            return "applewatch"
        }
        if normalized.contains("pencil") {
            return "applepencil"
        }
        if normalized.contains("speaker") || normalized.contains("音箱") {
            return "hifispeaker"
        }
        if normalized.contains("controller") || normalized.contains("gamepad") || normalized.contains("手柄") {
            return "gamecontroller"
        }

        return "battery.75percent"
    }
}
