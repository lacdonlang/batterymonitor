import Foundation

public enum SystemSettingsDestination {
    public static let app = URL(fileURLWithPath: "/System/Applications/System Settings.app")
    public static let notifications = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    public static let bluetooth = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
}
