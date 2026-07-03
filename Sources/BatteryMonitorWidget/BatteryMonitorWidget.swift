import BatteryMonitorShared
import OSLog
import SwiftUI
import WidgetKit

let widgetLogger = Logger(subsystem: "com.lacdon.batterymonitor.widget", category: "provider")

/// Applies the language persisted by the app. Called at process start (so
/// gallery text is localized) and again per provider callback (so a change
/// made in the app is picked up without restarting the widget process).
private func applySharedLanguagePreference(from store: SharedBatteryStore?) {
    guard let store else {
        return
    }
    L10n.apply(SettingsStore(directoryURL: store.directoryURL).load().language)
}

struct BatteryEntry: TimelineEntry {
    let date: Date
    let displayModel: WidgetBatteryDisplayModel
    var failureReason: String?

    init(
        date: Date,
        snapshot: BatterySnapshot?,
        lowBatteryThreshold: Int = MonitorSettings.default.lowBatteryThreshold,
        failureReason: String? = nil
    ) {
        self.date = date
        self.displayModel = WidgetBatteryDisplayModel(
            snapshot: snapshot,
            fallbackDate: date,
            lowBatteryThreshold: lowBatteryThreshold
        )
        self.failureReason = failureReason
    }
}

struct BatteryProvider: TimelineProvider {
    private func makeEntry() -> BatteryEntry {
        let store: SharedBatteryStore?
        var failureReason: String?
        do {
            store = try SharedBatteryStore.appGroup()
        } catch {
            store = nil
            failureReason = "store: \(error)"
        }

        applySharedLanguagePreference(from: store)
        let settings = store.map { SettingsStore(directoryURL: $0.directoryURL).load() } ?? .default

        var snapshot: BatterySnapshot?
        if let store {
            let result = WidgetSnapshotReader.readDetailed(from: store)
            snapshot = result.snapshot
            failureReason = result.failureReason
        }

        return BatteryEntry(
            date: Date(),
            snapshot: snapshot,
            lowBatteryThreshold: settings.lowBatteryThreshold,
            failureReason: failureReason
        )
    }

    func placeholder(in context: Context) -> BatteryEntry {
        BatteryEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        let entry = makeEntry()
        if entry.displayModel.hasSnapshot {
            completion(entry)
        } else {
            completion(BatteryEntry(date: Date(), snapshot: .preview))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        let entry = makeEntry()
        widgetLogger.error("getTimeline devices=\(entry.displayModel.devices.count, privacy: .public) failure=\(entry.failureReason ?? "none", privacy: .public)")
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

// MARK: - Shared styling

/// Frosted glass surface: nothing but the thinnest system material, so the
/// wallpaper blurs through and the system's Liquid Glass treatment isn't
/// painted over. A hairline sheen at the very top hints at a glass edge.
struct WidgetGlassBackground: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.10), location: 0),
                        .init(color: .clear, location: 0.25)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

/// Header shared by the medium and large widgets: recessive chrome, the data
/// rows carry the visual weight.
struct WidgetHeader: View {
    var freshnessText: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.text(.widgetTitle))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(freshnessText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Device row whose background doubles as a battery meter.
struct WidgetDeviceRow: View {
    var device: BatteryDevice
    var model: WidgetBatteryDisplayModel

    var body: some View {
        let accent = BatteryLevelStyle.accent(
            isCharging: device.isActivelyCharging,
            isLowBattery: model.isLowBattery(device)
        )
        let meterColor = accent ?? .secondary
        let emphasized = accent != nil

        HStack(spacing: 8) {
            Image(systemName: DeviceSymbol.name(for: device))
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent ?? Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(meterColor.opacity(emphasized ? 0.18 : 0.10))
                )

            Text(device.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 6)

            HStack(spacing: 3) {
                if device.isActivelyCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                }
                Text("\(device.percentage)%")
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(accent ?? .primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            BatteryLevelMeter(
                fraction: Double(device.percentage) / 100,
                cornerRadius: 9,
                track: AnyShapeStyle(Color.primary.opacity(0.05)),
                fill: AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            meterColor.opacity(emphasized ? 0.32 : 0.16),
                            meterColor.opacity(emphasized ? 0.15 : 0.06)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
        )
    }
}

/// Standalone thin meter used by the small widget.
struct BatteryMeterBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
    }
}

struct WidgetEmptyState: View {
    var failureReason: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "battery.0")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(L10n.text(.widgetNoData))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failureReason {
                Text(failureReason)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Families

struct BatteryMonitorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: BatteryEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                SmallBatteryWidgetView(entry: entry)
            case .systemLarge:
                LargeBatteryWidgetView(entry: entry)
            default:
                MediumBatteryWidgetView(entry: entry)
            }
        }
        .containerBackground(for: .widget) {
            WidgetGlassBackground()
        }
    }
}

struct SmallBatteryWidgetView: View {
    var entry: BatteryEntry

    var body: some View {
        let model = entry.displayModel

        if let device = model.lowestDevice {
            let accent = BatteryLevelStyle.accent(
                isCharging: device.isActivelyCharging,
                isLowBattery: model.isLowBattery(device)
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: DeviceSymbol.name(for: device))
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(accent ?? Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill((accent ?? .secondary).opacity(0.14))
                        )
                    Spacer()
                    if device.isActivelyCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }

                Spacer(minLength: 4)

                Text("\(device.percentage)%")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent ?? .primary)

                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                BatteryMeterBar(
                    fraction: Double(device.percentage) / 100,
                    color: accent ?? .primary
                )
                .frame(height: 5)

                Text(model.freshnessText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(13)
        } else {
            WidgetEmptyState(failureReason: entry.failureReason)
                .padding(13)
        }
    }
}

struct MediumBatteryWidgetView: View {
    var entry: BatteryEntry

    var body: some View {
        let model = entry.displayModel

        VStack(alignment: .leading, spacing: 7) {
            WidgetHeader(freshnessText: model.freshnessText)

            if model.devices.isEmpty {
                WidgetEmptyState(failureReason: entry.failureReason)
            } else {
                VStack(spacing: 5) {
                    ForEach(model.mediumDevices) { device in
                        WidgetDeviceRow(device: device, model: model)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(12)
    }
}

struct LargeBatteryWidgetView: View {
    var entry: BatteryEntry

    var body: some View {
        let model = entry.displayModel

        VStack(alignment: .leading, spacing: 9) {
            WidgetHeader(freshnessText: model.freshnessText)

            if model.devices.isEmpty {
                WidgetEmptyState(failureReason: entry.failureReason)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.largeDevices) { device in
                        WidgetDeviceRow(device: device, model: model)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(14)
    }
}

struct BatteryStatusWidget: Widget {
    let kind = "BatteryMonitorStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BatteryProvider()) { entry in
            BatteryMonitorWidgetView(entry: entry)
        }
        .configurationDisplayName("Battery Monitor")
        .description(Text(L10n.text(.widgetDescription)))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct BatteryMonitorWidgetBundle: WidgetBundle {
    init() {
        applySharedLanguagePreference(from: try? SharedBatteryStore.appGroup())
    }

    var body: some Widget {
        BatteryStatusWidget()
    }
}

private extension BatterySnapshot {
    static var preview: BatterySnapshot {
        BatterySnapshot(
            devices: [
                BatteryDevice(
                    id: "preview:mac",
                    name: "MacBook Battery",
                    kind: .internalBattery,
                    percentage: 78,
                    isCharging: true,
                    isConnected: true,
                    source: "Preview",
                    updatedAt: Date()
                ),
                BatteryDevice(
                    id: "preview:mouse",
                    name: "Magic Mouse",
                    kind: .peripheral,
                    percentage: 14,
                    isCharging: false,
                    isConnected: true,
                    source: "Preview",
                    updatedAt: Date()
                )
            ],
            updatedAt: Date()
        )
    }
}
