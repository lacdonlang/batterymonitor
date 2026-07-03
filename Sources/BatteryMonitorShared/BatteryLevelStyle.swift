import SwiftUI

/// The one place the battery state → color decision lives. Both the menu bar
/// list and the widget derive their tinting from here.
public enum BatteryLevelStyle {
    /// Status accent for a device: green while charging, red when low,
    /// nil for the neutral state so call sites pick their own neutral ink.
    public static func accent(isCharging: Bool, isLowBattery: Bool) -> Color? {
        if isCharging {
            return .green
        }
        if isLowBattery {
            return .red
        }
        return nil
    }
}

/// Leading-anchored proportional fill inside a rounded rectangle — the meter
/// drawn behind each device row.
public struct BatteryLevelMeter: View {
    public var fraction: Double
    public var cornerRadius: CGFloat
    public var track: AnyShapeStyle
    public var fill: AnyShapeStyle

    public init(fraction: Double, cornerRadius: CGFloat, track: AnyShapeStyle, fill: AnyShapeStyle) {
        self.fraction = fraction
        self.cornerRadius = cornerRadius
        self.track = track
        self.fill = fill
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(track)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
