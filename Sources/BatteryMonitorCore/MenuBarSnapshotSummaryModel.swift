import BatteryMonitorShared
import Foundation

public struct MenuBarSnapshotSummaryModel: Equatable, Sendable {
    public var lastUpdatedText: String
    public var deviceCount: Int
    public var isEmpty: Bool

    public init(snapshot: BatterySnapshot, timeText: String? = nil) {
        let resolvedTimeText = timeText ?? snapshot.updatedAt.formatted(date: .omitted, time: .standard)
        lastUpdatedText = L10n.format(.lastUpdatedAt, resolvedTimeText)
        deviceCount = snapshot.devices.count
        isEmpty = snapshot.devices.isEmpty
    }
}
