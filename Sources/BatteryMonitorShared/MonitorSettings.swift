import Foundation

public struct MonitorSettings: Codable, Equatable, Sendable {
    public var lowBatteryThreshold: Int
    public var recoveryMargin: Int
    public var pollingInterval: TimeInterval
    public var reminderCooldown: TimeInterval
    public var launchAtLogin: Bool
    public var language: LanguagePreference
    public var ignoredDeviceIDs: Set<String>
    public var ignoredDeviceFingerprints: Set<String>

    public init(
        lowBatteryThreshold: Int = 20,
        recoveryMargin: Int = 5,
        pollingInterval: TimeInterval = 180,
        reminderCooldown: TimeInterval = 7_200,
        launchAtLogin: Bool = false,
        language: LanguagePreference = .system,
        ignoredDeviceIDs: Set<String> = [],
        ignoredDeviceFingerprints: Set<String> = []
    ) {
        self.lowBatteryThreshold = BatteryPercentage.clamp(lowBatteryThreshold)
        self.recoveryMargin = max(1, recoveryMargin)
        self.pollingInterval = max(30, pollingInterval)
        self.reminderCooldown = max(60, reminderCooldown)
        self.launchAtLogin = launchAtLogin
        self.language = language
        self.ignoredDeviceIDs = ignoredDeviceIDs
        self.ignoredDeviceFingerprints = ignoredDeviceFingerprints
    }

    public static let `default` = MonitorSettings()

    public var recoveryThreshold: Int {
        BatteryPercentage.clamp(lowBatteryThreshold + recoveryMargin)
    }

    public func isIgnored(_ device: BatteryDevice) -> Bool {
        ignoredDeviceIDs.contains(device.id)
            || ignoredDeviceFingerprints.contains(Self.deviceFingerprint(for: device))
    }

    public static func deviceFingerprint(for device: BatteryDevice) -> String {
        "\(device.name.lowercased())|\(device.kind.rawValue)|\(device.source.lowercased())"
    }
}

extension MonitorSettings {
    private enum CodingKeys: String, CodingKey {
        case lowBatteryThreshold
        case recoveryMargin
        case pollingInterval
        case reminderCooldown
        case launchAtLogin
        case language
        case ignoredDeviceIDs
        case ignoredDeviceFingerprints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lowBatteryThreshold: try container.decode(Int.self, forKey: .lowBatteryThreshold),
            recoveryMargin: try container.decode(Int.self, forKey: .recoveryMargin),
            pollingInterval: try container.decode(TimeInterval.self, forKey: .pollingInterval),
            reminderCooldown: try container.decode(TimeInterval.self, forKey: .reminderCooldown),
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false,
            language: try container.decodeIfPresent(LanguagePreference.self, forKey: .language) ?? .system,
            ignoredDeviceIDs: try container.decodeIfPresent(Set<String>.self, forKey: .ignoredDeviceIDs) ?? [],
            ignoredDeviceFingerprints: try container.decodeIfPresent(Set<String>.self, forKey: .ignoredDeviceFingerprints) ?? []
        )
    }

}
