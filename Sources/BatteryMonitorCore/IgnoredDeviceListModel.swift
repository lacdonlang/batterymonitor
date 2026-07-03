import Foundation
import BatteryMonitorShared

public struct IgnoredDeviceListItem: Identifiable, Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case deviceID
        case deviceFingerprint
    }

    public var source: Source
    public var value: String
    public var title: String
    public var detailText: String

    public var id: String {
        "\(source.rawValue):\(value)"
    }

    public init(source: Source, value: String, title: String, detailText: String) {
        self.source = source
        self.value = value
        self.title = title
        self.detailText = detailText
    }
}

public struct IgnoredDeviceListModel: Equatable, Sendable {
    public var unavailableItems: [IgnoredDeviceListItem]

    public init(settings: MonitorSettings, visibleDevices: [BatteryDevice]) {
        let visibleIDs = Set(visibleDevices.map(\.id))
        let visibleFingerprints = Set(visibleDevices.map { MonitorSettings.deviceFingerprint(for: $0) })

        let staleIDItems = settings.ignoredDeviceIDs
            .subtracting(visibleIDs)
            .sorted()
            .map { ignoredID in
                IgnoredDeviceListItem(
                    source: .deviceID,
                    value: ignoredID,
                    title: L10n.text(.unavailableDeviceTitle),
                    detailText: "ID: \(ignoredID)"
                )
            }

        let staleFingerprintItems = settings.ignoredDeviceFingerprints
            .subtracting(visibleFingerprints)
            .sorted()
            .map { fingerprint in
                IgnoredDeviceListItem(
                    source: .deviceFingerprint,
                    value: fingerprint,
                    title: Self.title(forFingerprint: fingerprint),
                    detailText: L10n.format(.fingerprintDetail, fingerprint)
                )
            }

        unavailableItems = staleIDItems + staleFingerprintItems
    }

    private static func title(forFingerprint fingerprint: String) -> String {
        let name = fingerprint.split(separator: "|", omittingEmptySubsequences: false).first
        if let name, !name.isEmpty {
            return String(name)
        }
        return L10n.text(.unavailableDeviceTitle)
    }
}
