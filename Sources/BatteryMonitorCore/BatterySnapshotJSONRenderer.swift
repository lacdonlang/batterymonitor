import BatteryMonitorShared
import Foundation

public enum BatterySnapshotJSONRenderer {
    public static func render(_ snapshot: BatterySnapshot) throws -> String {
        let data = try encoder.encode(snapshot)
        return String(decoding: data, as: UTF8.self)
    }

    public static func renderData(_ snapshot: BatterySnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
