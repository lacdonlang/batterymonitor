import Foundation
import BatteryMonitorShared
import UserNotifications

public enum NotificationPermissionStatus: String, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown
}

public struct NotificationPermissionDisplayModel: Equatable, Sendable {
    public var statusText: String
    public var warningText: String?
    public var settingsActionTitle: String?
    public var settingsURL: URL?
    public var symbolName: String
    public var isAlertingDisabled: Bool

    public init(status: NotificationPermissionStatus) {
        switch status {
        case .notDetermined:
            statusText = L10n.text(.permissionNotRequested)
            warningText = nil
            settingsActionTitle = nil
            settingsURL = nil
            symbolName = "bell.badge"
            isAlertingDisabled = false
        case .denied:
            statusText = L10n.text(.permissionDenied)
            warningText = L10n.text(.notificationPermissionDeniedWarning)
            settingsActionTitle = L10n.text(.openSystemSettings)
            settingsURL = SystemSettingsDestination.notifications
            symbolName = "bell.slash"
            isAlertingDisabled = true
        case .authorized:
            statusText = L10n.text(.permissionAuthorized)
            warningText = nil
            settingsActionTitle = nil
            settingsURL = nil
            symbolName = "bell"
            isAlertingDisabled = false
        case .provisional:
            statusText = L10n.text(.permissionProvisional)
            warningText = nil
            settingsActionTitle = nil
            settingsURL = nil
            symbolName = "bell.badge"
            isAlertingDisabled = false
        case .ephemeral:
            statusText = L10n.text(.permissionEphemeral)
            warningText = nil
            settingsActionTitle = nil
            settingsURL = nil
            symbolName = "bell.badge"
            isAlertingDisabled = false
        case .unknown:
            statusText = L10n.text(.permissionUnknown)
            warningText = L10n.text(.notificationPermissionUnknownWarning)
            settingsActionTitle = L10n.text(.openSystemSettings)
            settingsURL = SystemSettingsDestination.notifications
            symbolName = "questionmark.circle"
            isAlertingDisabled = false
        }
    }
}

public protocol BatteryAlertNotifying: Sendable {
    func registerNotificationActions()
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> NotificationPermissionStatus
    func sendLowBatteryAlert(_ alert: LowBatteryAlert) async throws
    func sendLowBatteryAlerts(_ alerts: [LowBatteryAlert]) async throws
}

public extension BatteryAlertNotifying {
    func registerNotificationActions() {}

    func sendLowBatteryAlerts(_ alerts: [LowBatteryAlert]) async throws {
        for alert in alerts {
            try await sendLowBatteryAlert(alert)
        }
    }
}

public protocol UserNotificationCentering: Sendable {
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> NotificationPermissionStatus
    func add(_ request: UNNotificationRequest) async throws
}

public enum LowBatteryNotificationAction {
    public static let categoryIdentifier = "com.lacdon.batterymonitor.lowBattery"
    public static let snoozeIdentifier = "com.lacdon.batterymonitor.snooze"
    public static let ignoreDeviceIdentifier = "com.lacdon.batterymonitor.ignoreDevice"
    public static var snoozeTitle: String { L10n.text(.snoozeAction) }
    public static var ignoreDeviceTitle: String { L10n.text(.ignoreDeviceAction) }
    public static let deviceIDsUserInfoKey = "batteryMonitorDeviceIDs"
    public static let deviceFingerprintsUserInfoKey = "batteryMonitorDeviceFingerprints"

    public static func makeCategory() -> UNNotificationCategory {
        let snoozeAction = UNNotificationAction(
            identifier: snoozeIdentifier,
            title: snoozeTitle,
            options: []
        )
        let ignoreAction = UNNotificationAction(
            identifier: ignoreDeviceIdentifier,
            title: ignoreDeviceTitle,
            options: []
        )

        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [snoozeAction, ignoreAction],
            intentIdentifiers: [],
            options: []
        )
    }
}

public enum LowBatteryNotificationReportRenderer {
    public static func render(
        snapshot: BatterySnapshot,
        threshold: Int,
        renderedAt: Date
    ) -> String {
        let settings = MonitorSettings(lowBatteryThreshold: threshold)
        let evaluation = RuleEngine(settings: settings).evaluate(
            snapshot: snapshot,
            states: [:],
            now: renderedAt
        )
        let payload = LowBatteryNotificationPayload.make(for: evaluation.alerts)
        let alertLines = evaluation.alerts.isEmpty
            ? "- none"
            : evaluation.alerts
                .map { "- \($0.device.name) | \($0.device.percentage)% | \($0.device.source) | \($0.device.id)" }
                .joined(separator: "\n")

        return """
        Low battery notification report
        Rendered at: \(ISO8601DateFormatter().string(from: renderedAt))
        Snapshot updated at: \(ISO8601DateFormatter().string(from: snapshot.updatedAt))
        Low battery threshold: \(settings.lowBatteryThreshold)%
        Recovery threshold: \(settings.recoveryThreshold)%
        Cooldown state: empty
        Alert count: \(evaluation.alerts.count)
        Category identifier: \(LowBatteryNotificationAction.categoryIdentifier)
        Action identifiers: \(LowBatteryNotificationAction.snoozeIdentifier)=\(LowBatteryNotificationAction.snoozeTitle), \(LowBatteryNotificationAction.ignoreDeviceIdentifier)=\(LowBatteryNotificationAction.ignoreDeviceTitle)
        Payload identifier: \(payload?.identifier ?? "none")
        Payload title: \(payload?.title ?? "none")
        Payload body: \(payload?.body ?? "none")
        Payload device IDs: \((payload?.deviceIDs ?? []).joined(separator: ", "))
        Payload device fingerprints: \((payload?.deviceFingerprints ?? []).joined(separator: ", "))

        Alert devices:
        \(alertLines)
        """
    }
}

public struct LowBatteryNotificationPayload: Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var body: String
    public var deviceIDs: [String]
    public var deviceFingerprints: [String]

    public init(
        identifier: String,
        title: String,
        body: String,
        deviceIDs: [String] = [],
        deviceFingerprints: [String] = []
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.deviceIDs = deviceIDs
        self.deviceFingerprints = deviceFingerprints
    }

    public static func make(for alert: LowBatteryAlert) -> LowBatteryNotificationPayload {
        LowBatteryNotificationPayload(
            identifier: "battery-low-\(alert.device.id)",
            title: L10n.format(.lowBatteryTitle, alert.device.name),
            body: L10n.format(.lowBatteryBody, alert.device.percentage),
            deviceIDs: [alert.device.id],
            deviceFingerprints: [MonitorSettings.deviceFingerprint(for: alert.device)]
        )
    }

    public static func make(for alerts: [LowBatteryAlert]) -> LowBatteryNotificationPayload? {
        let sortedAlerts = alerts.sorted { lhs, rhs in
            lhs.device.name.localizedCaseInsensitiveCompare(rhs.device.name) == .orderedAscending
        }

        guard !sortedAlerts.isEmpty else {
            return nil
        }

        guard sortedAlerts.count > 1 else {
            return make(for: sortedAlerts[0])
        }

        let summary = sortedAlerts
            .map { "\($0.device.name) \($0.device.percentage)%" }
            .joined(separator: L10n.text(.listSeparator))

        return LowBatteryNotificationPayload(
            identifier: batchIdentifier(for: sortedAlerts),
            title: L10n.format(.lowBatteryBatchTitle, sortedAlerts.count),
            body: L10n.format(.lowBatteryBatchBody, summary),
            deviceIDs: sortedAlerts.map(\.device.id),
            deviceFingerprints: sortedAlerts.map { MonitorSettings.deviceFingerprint(for: $0.device) }
        )
    }

    public var userInfo: [AnyHashable: Any] {
        [
            LowBatteryNotificationAction.deviceIDsUserInfoKey: deviceIDs,
            LowBatteryNotificationAction.deviceFingerprintsUserInfoKey: deviceFingerprints
        ]
    }

    private static func batchIdentifier(for alerts: [LowBatteryAlert]) -> String {
        let suffix = alerts
            .map { sanitizedIdentifierComponent($0.device.id) }
            .joined(separator: "-")
        return "battery-low-batch-\(alerts.count)-\(String(suffix.prefix(160)))"
    }

    private static func sanitizedIdentifierComponent(_ value: String) -> String {
        let sanitized = value.unicodeScalars
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

        return sanitized.isEmpty ? "device" : sanitized
    }
}

public enum LowBatteryNotificationRequestFactory {
    public static func makeRequest(for alert: LowBatteryAlert) -> UNNotificationRequest {
        makeRequest(payload: LowBatteryNotificationPayload.make(for: alert))
    }

    public static func makeRequest(for alerts: [LowBatteryAlert]) -> UNNotificationRequest? {
        guard let payload = LowBatteryNotificationPayload.make(for: alerts) else {
            return nil
        }
        return makeRequest(payload: payload)
    }

    private static func makeRequest(payload: LowBatteryNotificationPayload) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.categoryIdentifier = LowBatteryNotificationAction.categoryIdentifier
        content.userInfo = payload.userInfo

        return UNNotificationRequest(
            identifier: payload.identifier,
            content: content,
            trigger: nil
        )
    }
}

public final class UserNotificationService: BatteryAlertNotifying, @unchecked Sendable {
    private let center: any UserNotificationCentering

    public init(center: any UserNotificationCentering = UNUserNotificationCenter.current()) {
        self.center = center
    }

    public func registerNotificationActions() {
        center.setNotificationCategories([LowBatteryNotificationAction.makeCategory()])
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    public func authorizationStatus() async -> NotificationPermissionStatus {
        await center.authorizationStatus()
    }

    public func sendLowBatteryAlert(_ alert: LowBatteryAlert) async throws {
        try await center.add(LowBatteryNotificationRequestFactory.makeRequest(for: alert))
    }

    public func sendLowBatteryAlerts(_ alerts: [LowBatteryAlert]) async throws {
        guard let request = LowBatteryNotificationRequestFactory.makeRequest(for: alerts) else {
            return
        }
        try await center.add(request)
    }
}

extension UNUserNotificationCenter: UserNotificationCentering {
    public func authorizationStatus() async -> NotificationPermissionStatus {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }
}

public struct NoopNotificationService: BatteryAlertNotifying {
    public init() {}

    public func requestAuthorization() async -> Bool {
        true
    }

    public func authorizationStatus() async -> NotificationPermissionStatus {
        .authorized
    }

    public func sendLowBatteryAlert(_ alert: LowBatteryAlert) async throws {}
}

public enum LowBatteryNotificationActionHandlingResult: Equatable, Sendable {
    case ignoredDevices(deviceIDs: Set<String>, deviceFingerprints: Set<String>)
    case snoozed(deviceIDs: Set<String>)
    case ignoredUnknownAction
}

public struct LowBatteryNotificationActionHandler {
    private let settingsStore: SettingsStore

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    public func handle(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) throws -> LowBatteryNotificationActionHandlingResult {
        let deviceIDs = Set(Self.stringArray(
            from: userInfo[LowBatteryNotificationAction.deviceIDsUserInfoKey]
        ))
        let deviceFingerprints = Set(Self.stringArray(
            from: userInfo[LowBatteryNotificationAction.deviceFingerprintsUserInfoKey]
        ))

        switch actionIdentifier {
        case LowBatteryNotificationAction.ignoreDeviceIdentifier:
            var settings = settingsStore.load()
            settings.ignoredDeviceIDs.formUnion(deviceIDs)
            settings.ignoredDeviceFingerprints.formUnion(deviceFingerprints)
            try settingsStore.save(settings)
            return .ignoredDevices(deviceIDs: deviceIDs, deviceFingerprints: deviceFingerprints)

        case LowBatteryNotificationAction.snoozeIdentifier:
            return .snoozed(deviceIDs: deviceIDs)

        default:
            return .ignoredUnknownAction
        }
    }

    private static func stringArray(from value: Any?) -> [String] {
        if let values = value as? [String] {
            return values
        }

        if let values = value as? NSArray {
            return values.compactMap { $0 as? String }
        }

        return []
    }
}

public final class LowBatteryNotificationResponseDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let handler: LowBatteryNotificationActionHandler

    public init(handler: LowBatteryNotificationActionHandler) {
        self.handler = handler
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        do {
            _ = try handler.handle(
                actionIdentifier: response.actionIdentifier,
                userInfo: response.notification.request.content.userInfo
            )
        } catch {
            // The notification center requires completion even if settings persistence fails.
        }

        completionHandler()
    }
}
