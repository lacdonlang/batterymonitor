import Foundation

public enum BatteryPercentage {
    public static func calculate(current: Int, max: Int) -> Int {
        guard max > 0 else {
            return 0
        }
        let rawValue = (Double(current) / Double(max)) * 100
        return clamp(Int(rawValue.rounded()))
    }

    public static func clamp(_ value: Int) -> Int {
        min(100, max(0, value))
    }
}
