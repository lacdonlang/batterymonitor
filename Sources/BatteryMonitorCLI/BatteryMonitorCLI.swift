import BatteryMonitorCore
import BatteryMonitorShared
import Foundation

@main
struct BatteryMonitorCLI {
    static func main() async {
        do {
            let arguments = CLIArguments(arguments: CommandLine.arguments)
            let now = Date()
            if let widgetSnapshotPath = arguments.widgetReportSnapshotPath {
                let snapshot = try Self.readSnapshot(from: widgetSnapshotPath)
                print(WidgetDisplayReportRenderer.render(snapshot: snapshot, renderedAt: now))
                return
            }

            if let notificationSnapshotPath = arguments.notificationReportSnapshotPath {
                let snapshot = try Self.readSnapshot(from: notificationSnapshotPath)
                print(LowBatteryNotificationReportRenderer.render(
                    snapshot: snapshot,
                    threshold: arguments.notificationReportThreshold,
                    renderedAt: now
                ))
                return
            }

            if let settingsReportPath = arguments.settingsReportPath {
                let settings = SettingsStore(fileURL: URL(fileURLWithPath: settingsReportPath)).load()
                let snapshot = try arguments.settingsReportSnapshotPath.map { try Self.readSnapshot(from: $0) }
                print(SettingsReportRenderer.render(settings: settings, snapshot: snapshot, renderedAt: now))
                return
            }

            if arguments.diagnoseBatterySources {
                let diagnostics = try IORegistryBatteryReader().readDiagnostics()
                print(BatterySourceDiagnosticsRenderer.render(ioRegistry: diagnostics))
                return
            }

            let reader = DefaultBatteryReader()
            let devices = try reader.readDevices(now: now)
            let snapshot = BatterySnapshot(devices: devices, updatedAt: now)

            if arguments.printJSON {
                print(try BatterySnapshotJSONRenderer.render(snapshot))
            } else {
                print(DeviceTableRenderer.render(devices: snapshot.devices))
            }

            if let reportPath = arguments.reportPath {
                let reportURL = URL(fileURLWithPath: reportPath)
                let existingReport = try? String(contentsOf: reportURL, encoding: .utf8)
                let historicalDevices = existingReport.map(DeviceCompatibilityReportRenderer.historicalDevices) ?? []
                let bluetoothIdentities = (try? SystemProfilerBluetoothDeviceResolver().readBluetoothDeviceIdentities()) ?? []
                let ioRegistryDiagnostics = (try? IORegistryBatteryReader().readDiagnostics()) ?? []
                let report = DeviceCompatibilityReportRenderer.render(
                    snapshot: snapshot,
                    generatedAt: now,
                    historicalDevices: historicalDevices,
                    bluetoothIdentities: bluetoothIdentities,
                    ioRegistryDiagnostics: ioRegistryDiagnostics
                )
                try FileManager.default.createDirectory(
                    at: reportURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try report.write(to: reportURL, atomically: true, encoding: .utf8)
                print("Wrote compatibility report: \(reportURL.path)")
            }
        } catch {
            FileHandle.standardError.write(Data("BatteryMonitorCLI failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func readSnapshot(from path: String) throws -> BatterySnapshot {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BatterySnapshot.self, from: data)
    }
}

private struct CLIArguments {
    var reportPath: String?
    var widgetReportSnapshotPath: String?
    var notificationReportSnapshotPath: String?
    var notificationReportThreshold = MonitorSettings.default.lowBatteryThreshold
    var settingsReportPath: String?
    var settingsReportSnapshotPath: String?
    var diagnoseBatterySources = false
    var printJSON = false

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--report":
                reportPath = iterator.next()
            case "--widget-report":
                widgetReportSnapshotPath = iterator.next()
            case "--notification-report":
                notificationReportSnapshotPath = iterator.next()
            case "--threshold":
                if let rawThreshold = iterator.next(), let threshold = Int(rawThreshold) {
                    notificationReportThreshold = threshold
                }
            case "--settings-report":
                settingsReportPath = iterator.next()
            case "--settings-report-snapshot":
                settingsReportSnapshotPath = iterator.next()
            case "--diagnose-battery-sources":
                diagnoseBatterySources = true
            case "--json":
                printJSON = true
            case "--help", "-h":
                print(Self.help)
                Foundation.exit(0)
            default:
                break
            }
        }
    }

    static let help = """
    Usage:
      BatteryMonitorCLI [--json] [--report <path>] [--widget-report <snapshot-json>] [--notification-report <snapshot-json> --threshold <percent>] [--settings-report <settings-json> [--settings-report-snapshot <snapshot-json>]] [--diagnose-battery-sources]

    Examples:
      swift run BatteryMonitorCLI
      swift run BatteryMonitorCLI --report docs/device-compatibility-report.md
      swift run BatteryMonitorCLI --json
      swift run BatteryMonitorCLI --widget-report /path/to/battery-snapshot.json
      swift run BatteryMonitorCLI --notification-report /path/to/battery-snapshot.json --threshold 100
      swift run BatteryMonitorCLI --settings-report /path/to/settings.json --settings-report-snapshot /path/to/battery-snapshot.json
      swift run BatteryMonitorCLI --diagnose-battery-sources
    """
}
