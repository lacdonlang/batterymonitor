import Foundation

public enum BatteryMonitorLanguage: String, CaseIterable, Sendable {
    case english
    case simplifiedChinese
}

/// User-facing language choice persisted in settings. `.system` follows
/// the macOS preferred language.
public enum LanguagePreference: String, Codable, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var overrideLanguage: BatteryMonitorLanguage? {
        switch self {
        case .system:
            return nil
        case .simplifiedChinese:
            return .simplifiedChinese
        case .english:
            return .english
        }
    }

    public var displayNameKey: L10nKey {
        switch self {
        case .system:
            return .languageSystem
        case .simplifiedChinese:
            return .languageChinese
        case .english:
            return .languageEnglish
        }
    }
}

public enum L10nKey: String, CaseIterable, Sendable {
    // Charging status
    case statusNotConnected
    case statusCharging
    case statusNotCharging
    case statusConnected
    case statusChargingUnreported
    case statusDisconnected

    // Menu bar
    case lastUpdatedAt
    case refresh
    case noBatteryData
    case devFallbackWarning
    case notificationSendFailed
    case settings
    case quit

    // Permissions
    case permissionNotRequested
    case permissionDenied
    case permissionAuthorized
    case permissionProvisional
    case permissionEphemeral
    case permissionUnknown
    case permissionRestricted
    case notificationPermissionDeniedWarning
    case notificationPermissionUnknownWarning
    case bluetoothDeniedWarning
    case bluetoothRestrictedWarning
    case bluetoothUnknownWarning
    case openSystemSettings

    // Notifications
    case snoozeAction
    case ignoreDeviceAction
    case lowBatteryTitle
    case lowBatteryBody
    case lowBatteryBatchTitle
    case lowBatteryBatchBody
    case listSeparator

    // Settings window
    case sectionAlerts
    case lowBatteryThresholdLabel
    case recoveryMarginLabel
    case pollingIntervalLabel
    case reminderCooldownLabel
    case sectionDevices
    case noDevices
    case ignoreDeviceToggle
    case unavailableIgnoredDevices
    case remove
    case sectionSystem
    case languageLabel
    case languageSystem
    case languageChinese
    case languageEnglish
    case launchAtLogin
    case notificationPermissionLabel
    case bluetoothPermissionLabel
    case unavailableDeviceTitle
    case fingerprintDetail

    // Widget
    case widgetNoCache
    case widgetJustUpdated
    case widgetMinutesAgo
    case widgetCachedAt
    case widgetNoData
    case widgetDescription
    case widgetTitle
}

public enum L10n {
    /// Set via `apply(_:)` when the user picks an explicit language in
    /// settings; nil follows the system. Test harnesses also pin this so
    /// assertions stay deterministic.
    nonisolated(unsafe) public static var languageOverride: BatteryMonitorLanguage?

    public static var language: BatteryMonitorLanguage {
        if let languageOverride {
            return languageOverride
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    public static func apply(_ preference: LanguagePreference) {
        languageOverride = preference.overrideLanguage
    }

    public static func text(_ key: L10nKey) -> String {
        let entry = Self.table[key] ?? ("", "")
        return language == .simplifiedChinese ? entry.zh : entry.en
    }

    public static func format(_ key: L10nKey, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }

    private static let table: [L10nKey: (zh: String, en: String)] = [
        .statusNotConnected: ("未连接", "Not Connected"),
        .statusCharging: ("充电中", "Charging"),
        .statusNotCharging: ("未充电", "Not Charging"),
        .statusConnected: ("已连接", "Connected"),
        .statusChargingUnreported: ("macOS 未上报充电状态", "Charging state not reported by macOS"),
        .statusDisconnected: ("已断开", "Disconnected"),

        .lastUpdatedAt: ("更新于 %@", "Updated at %@"),
        .refresh: ("刷新", "Refresh"),
        .noBatteryData: ("暂无电池数据", "No battery data"),
        .devFallbackWarning: (
            "当前使用开发存储；打包 App 需启用 App Group",
            "Using development storage; the packaged app needs its App Group"
        ),
        .notificationSendFailed: ("通知发送失败：%@", "Failed to send notification: %@"),
        .settings: ("设置", "Settings"),
        .quit: ("退出", "Quit"),

        .permissionNotRequested: ("未请求", "Not Requested"),
        .permissionDenied: ("已关闭", "Denied"),
        .permissionAuthorized: ("已允许", "Allowed"),
        .permissionProvisional: ("临时允许", "Provisional"),
        .permissionEphemeral: ("本次允许", "Ephemeral"),
        .permissionUnknown: ("未知", "Unknown"),
        .permissionRestricted: ("受限制", "Restricted"),
        .notificationPermissionDeniedWarning: ("通知权限已关闭", "Notifications are turned off"),
        .notificationPermissionUnknownWarning: ("通知权限状态未知", "Notification permission state is unknown"),
        .bluetoothDeniedWarning: (
            "蓝牙权限已关闭，部分外设电量可能不可见",
            "Bluetooth permission is off; some peripheral battery levels may be hidden"
        ),
        .bluetoothRestrictedWarning: (
            "蓝牙权限受系统限制，部分外设电量可能不可见",
            "Bluetooth is restricted by the system; some peripheral battery levels may be hidden"
        ),
        .bluetoothUnknownWarning: (
            "蓝牙权限状态未知，部分外设电量可能不可见",
            "Bluetooth permission state is unknown; some peripheral battery levels may be hidden"
        ),
        .openSystemSettings: ("打开系统设置", "Open System Settings"),

        .snoozeAction: ("稍后提醒", "Remind Me Later"),
        .ignoreDeviceAction: ("忽略此设备", "Ignore This Device"),
        .lowBatteryTitle: ("%@ 电量低", "%@ Battery Low"),
        .lowBatteryBody: ("当前电量 %d%%，请及时充电。", "Battery is at %d%%. Please charge it soon."),
        .lowBatteryBatchTitle: ("%d 个设备电量低", "%d Devices Low on Battery"),
        .lowBatteryBatchBody: ("%@，请及时充电。", "%@. Please charge them soon."),
        .listSeparator: ("、", ", "),

        .sectionAlerts: ("提醒", "Alerts"),
        .lowBatteryThresholdLabel: ("低电量阈值：%d%%", "Low battery threshold: %d%%"),
        .recoveryMarginLabel: ("恢复缓冲：%d%%（恢复阈值 %d%%）", "Recovery margin: %d%% (recovers at %d%%)"),
        .pollingIntervalLabel: ("轮询间隔：%d 分钟", "Polling interval: %d min"),
        .reminderCooldownLabel: ("重复提醒：%d 小时", "Reminder cooldown: %d h"),
        .sectionDevices: ("设备", "Devices"),
        .noDevices: ("暂无设备", "No devices"),
        .ignoreDeviceToggle: ("%@ 忽略提醒", "Mute alerts for %@"),
        .unavailableIgnoredDevices: ("当前不可见的已忽略设备", "Ignored devices not currently visible"),
        .remove: ("移除", "Remove"),
        .sectionSystem: ("系统", "System"),
        .languageLabel: ("语言", "Language"),
        .languageSystem: ("跟随系统", "System Default"),
        .languageChinese: ("简体中文", "简体中文"),
        .languageEnglish: ("English", "English"),
        .launchAtLogin: ("登录时启动", "Launch at login"),
        .notificationPermissionLabel: ("通知权限", "Notifications"),
        .bluetoothPermissionLabel: ("蓝牙权限", "Bluetooth"),
        .unavailableDeviceTitle: ("未连接设备", "Unavailable device"),
        .fingerprintDetail: ("指纹: %@", "Fingerprint: %@"),

        .widgetNoCache: ("暂无缓存", "No cached data"),
        .widgetJustUpdated: ("刚刚更新", "Just updated"),
        .widgetMinutesAgo: ("%d 分钟前更新", "Updated %d min ago"),
        .widgetCachedAt: ("缓存 %@", "Cached %@"),
        .widgetNoData: ("暂无数据", "No data"),
        .widgetDescription: (
            "显示最近一次本机和外设电量快照。",
            "Shows the latest battery snapshot for this Mac and its peripherals."
        ),
        .widgetTitle: ("电池监控", "Battery Monitor")
    ]
}
