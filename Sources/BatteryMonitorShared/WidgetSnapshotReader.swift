import Foundation

public enum WidgetSnapshotReader {
    public static func read(from store: SharedBatteryStore) -> BatterySnapshot? {
        try? store.readSnapshot()
    }

    public static func readFromAppGroup(
        identifier: String = BatteryMonitorConstants.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> BatterySnapshot? {
        readFromAppGroupDetailed(identifier: identifier, fileManager: fileManager).snapshot
    }

    /// Same as `readFromAppGroup`, but reports why reading failed so the
    /// widget's empty state can say more than "no data".
    public static func readFromAppGroupDetailed(
        identifier: String = BatteryMonitorConstants.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> (snapshot: BatterySnapshot?, failureReason: String?) {
        let store: SharedBatteryStore
        do {
            store = try SharedBatteryStore.appGroup(
                identifier: identifier,
                fileManager: fileManager
            )
        } catch {
            return (nil, "store: \(error)")
        }

        return readDetailed(from: store)
    }

    public static func readDetailed(from store: SharedBatteryStore) -> (snapshot: BatterySnapshot?, failureReason: String?) {
        do {
            guard let snapshot = try store.readSnapshot() else {
                return (nil, "no snapshot at \(store.snapshotFileURL().path)")
            }
            return (snapshot, nil)
        } catch {
            return (nil, "read: \(error)")
        }
    }
}
