import AppKit
import BatteryMonitorCore
import BatteryMonitorShared
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications
import WidgetKit

@main
struct BatteryMonitorMenuBarApp: App {
    @StateObject private var model = BatteryMonitorViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
                .frame(width: 340)
                .padding(12)
        } label: {
            Label {
                Text(BatteryMonitorConstants.appName)
            } icon: {
                Image("MenuBarIcon")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 560, height: 640)
        }
    }
}

@MainActor
final class BatteryMonitorViewModel: ObservableObject {
    @Published var snapshot: BatterySnapshot = .empty()
    @Published var settings: MonitorSettings = .default
    @Published var authorizationStatus: NotificationPermissionStatus = .unknown
    @Published var bluetoothPermissionStatus: BluetoothPermissionStatus = .unknown
    @Published var lastError: String?
    @Published var usedDevelopmentStoreFallback = false
    @Published var loginItemEnabled = false

    private let store: SharedBatteryStore
    private let settingsStore: SettingsStore
    private let notificationService: any BatteryAlertNotifying
    private let bluetoothPermissionService: any BluetoothPermissionProviding
    private let loginItemService: SettingsBackedLoginItemService
    private let notificationResponseDelegate: LowBatteryNotificationResponseDelegate
    private let engine: MonitorEngine
    private let settingsWindowPresenter = SettingsWindowPresenter()
    private let qaOpenSettingsOnLaunch: Bool
    private let qaTriggerRefreshOnLaunch: Bool
    private let qaWriteMenuStateOnLaunch: Bool
    private let qaNotificationStatusOverride: NotificationPermissionStatus?

    var notificationPermissionDisplay: NotificationPermissionDisplayModel {
        NotificationPermissionDisplayModel(status: authorizationStatus)
    }

    var bluetoothPermissionDisplay: BluetoothPermissionDisplayModel {
        BluetoothPermissionDisplayModel(status: bluetoothPermissionStatus)
    }

    var snapshotSummary: MenuBarSnapshotSummaryModel {
        MenuBarSnapshotSummaryModel(snapshot: snapshot)
    }

    var ignoredDeviceList: IgnoredDeviceListModel {
        IgnoredDeviceListModel(settings: settings, visibleDevices: snapshot.devices)
    }

    init() {
        let environment = ProcessInfo.processInfo.environment
        let storeResult: (store: SharedBatteryStore, usedFallback: Bool)
        do {
            if let storeDirectory = environment["BATTERY_MONITOR_STORE_DIR"], !storeDirectory.isEmpty {
                storeResult = (
                    try SharedBatteryStore(directoryURL: URL(fileURLWithPath: storeDirectory, isDirectory: true)),
                    true
                )
            } else if environment["BATTERY_MONITOR_REQUIRE_APP_GROUP"] == "1" {
                storeResult = (try SharedBatteryStore.appGroup(), false)
            } else {
                storeResult = try SharedBatteryStore.appGroupOrDevelopmentFallback()
            }
        } catch {
            fatalError("Unable to create shared store: \(error)")
        }

        store = storeResult.store
        qaOpenSettingsOnLaunch = environment["BATTERY_MONITOR_QA_OPEN_SETTINGS"] == "1"
        qaTriggerRefreshOnLaunch = environment["BATTERY_MONITOR_QA_TRIGGER_REFRESH"] == "1"
        qaWriteMenuStateOnLaunch = environment["BATTERY_MONITOR_QA_WRITE_MENU_STATE"] == "1"
        if let rawStatus = environment["BATTERY_MONITOR_QA_NOTIFICATION_STATUS"], !rawStatus.isEmpty {
            guard let status = NotificationPermissionStatus(rawValue: rawStatus) else {
                fatalError("Unsupported BATTERY_MONITOR_QA_NOTIFICATION_STATUS: \(rawStatus)")
            }
            qaNotificationStatusOverride = status
        } else {
            qaNotificationStatusOverride = nil
        }
        usedDevelopmentStoreFallback = storeResult.usedFallback
        settingsStore = SettingsStore(directoryURL: store.directoryURL)
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
        L10n.apply(loadedSettings.language)
        if let qaNotificationStatusOverride {
            notificationService = FixedNotificationPermissionService(status: qaNotificationStatusOverride)
        } else if environment["BATTERY_MONITOR_DISABLE_NOTIFICATIONS"] == "1" {
            notificationService = NoopNotificationService()
        } else {
            notificationService = UserNotificationService()
        }
        bluetoothPermissionService = SystemBluetoothPermissionService()
        bluetoothPermissionStatus = bluetoothPermissionService.authorizationStatus()
        loginItemService = SettingsBackedLoginItemService(
            loginItemService: MainAppLoginItemService(),
            settingsStore: settingsStore
        )
        do {
            loginItemEnabled = try loginItemService.synchronizeFromSystem()
        } catch {
            loginItemEnabled = loginItemService.isEnabled()
            lastError = String(describing: error)
        }
        notificationResponseDelegate = LowBatteryNotificationResponseDelegate(
            handler: LowBatteryNotificationActionHandler(settingsStore: settingsStore)
        )
        UNUserNotificationCenter.current().delegate = notificationResponseDelegate
        engine = MonitorEngine(
            store: store,
            settingsStore: settingsStore,
            notifier: notificationService,
            widgetReloader: WidgetCenterReloader()
        )

        engine.onRefresh = { [weak self] result in
            Task { @MainActor in
                self?.snapshot = result.snapshot
                self?.lastError = result.notificationErrorDescription.map { L10n.format(.notificationSendFailed, $0) }
            }
        }

        engine.onError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = String(describing: error)
            }
        }

        if let cachedSnapshot = try? store.readSnapshot() {
            snapshot = cachedSnapshot
        }

        Task {
            await bootstrap()
        }
    }

    func bootstrap() async {
        notificationService.registerNotificationActions()
        _ = await notificationService.requestAuthorization()
        authorizationStatus = await notificationService.authorizationStatus()
        bluetoothPermissionStatus = bluetoothPermissionService.authorizationStatus()
        await refresh()
        openSettingsWindowForQAIfNeeded()
        await triggerRefreshForQAIfNeeded()
        writeNotificationStatusForQAIfNeeded()
        writeMenuStateForQAIfNeeded()
        engine.start()
    }

    func refresh() async {
        do {
            _ = try await engine.refresh()
            authorizationStatus = await notificationService.authorizationStatus()
            bluetoothPermissionStatus = bluetoothPermissionService.authorizationStatus()
        } catch {
            bluetoothPermissionStatus = bluetoothPermissionService.authorizationStatus()
            lastError = String(describing: error)
        }
    }

    func saveSettings() {
        do {
            try settingsStore.save(settings)
            lastError = nil
            Task {
                await refresh()
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    func setIgnored(device: BatteryDevice, ignored: Bool) {
        let fingerprint = MonitorSettings.deviceFingerprint(for: device)
        if ignored {
            settings.ignoredDeviceIDs.insert(device.id)
            settings.ignoredDeviceFingerprints.insert(fingerprint)
        } else {
            settings.ignoredDeviceIDs.remove(device.id)
            settings.ignoredDeviceFingerprints.remove(fingerprint)
        }
        saveSettings()
    }

    func removeUnavailableIgnoredDevice(_ item: IgnoredDeviceListItem) {
        switch item.source {
        case .deviceID:
            settings.ignoredDeviceIDs.remove(item.value)
        case .deviceFingerprint:
            settings.ignoredDeviceFingerprints.remove(item.value)
        }
        saveSettings()
    }

    func setLanguage(_ preference: LanguagePreference) {
        settings.language = preference
        L10n.apply(preference)
        saveSettings()
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            try loginItemService.setEnabled(enabled)
            loginItemEnabled = loginItemService.isEnabled()
            lastError = nil
        } catch {
            lastError = String(describing: error)
            loginItemEnabled = loginItemService.isEnabled()
        }
    }

    func openSystemSettings(_ url: URL? = nil) {
        NSWorkspace.shared.open(url ?? SystemSettingsDestination.app)
    }

    func openSettingsWindow() {
        settingsWindowPresenter.show(model: self)
    }

    private func openSettingsWindowForQAIfNeeded() {
        guard qaOpenSettingsOnLaunch else {
            return
        }

        openSettingsWindow()
        let markerURL = store.directoryURL.appendingPathComponent("qa-settings-window-opened.txt", isDirectory: false)
        let marker = "settings window opened\n"
        do {
            try marker.write(to: markerURL, atomically: true, encoding: .utf8)
        } catch {
            lastError = String(describing: error)
        }
    }

    private func triggerRefreshForQAIfNeeded() async {
        guard qaTriggerRefreshOnLaunch else {
            return
        }

        await refresh()
        let markerURL = store.directoryURL.appendingPathComponent("qa-manual-refresh.txt", isDirectory: false)
        let marker = "manual refresh invoked\n"
        do {
            try marker.write(to: markerURL, atomically: true, encoding: .utf8)
        } catch {
            lastError = String(describing: error)
        }
    }

    private func writeNotificationStatusForQAIfNeeded() {
        guard qaNotificationStatusOverride != nil else {
            return
        }

        let markerURL = store.directoryURL.appendingPathComponent("qa-notification-status.txt", isDirectory: false)
        let display = notificationPermissionDisplay
        let marker = """
        notificationStatus=\(authorizationStatus.rawValue)
        warningText=\(display.warningText ?? "")
        alertingDisabled=\(display.isAlertingDisabled)

        """
        do {
            try marker.write(to: markerURL, atomically: true, encoding: .utf8)
        } catch {
            lastError = String(describing: error)
        }
    }

    private func writeMenuStateForQAIfNeeded() {
        guard qaWriteMenuStateOnLaunch else {
            return
        }

        let markerURL = store.directoryURL.appendingPathComponent("qa-menu-state.json", isDirectory: false)
        // Mirror exactly what the menu renders: connected devices only, with
        // the fields DeviceRowView actually shows.
        let visibleDevices = snapshot.connectedDevices
        let rows = visibleDevices.map { device in
            let rowModel = MenuBarDeviceRowModel(device: device, threshold: settings.lowBatteryThreshold)
            return QAMenuDeviceRowMarker(
                name: rowModel.name,
                percentageText: rowModel.percentageText,
                statusText: rowModel.statusText,
                symbolName: rowModel.symbolName,
                isLowBattery: rowModel.isLowBattery
            )
        }
        let marker = QAMenuStateMarker(
            lastUpdatedText: snapshotSummary.lastUpdatedText,
            notificationStatus: authorizationStatus.rawValue,
            bluetoothPermissionStatus: bluetoothPermissionStatus.rawValue,
            lowBatteryThreshold: settings.lowBatteryThreshold,
            deviceCount: visibleDevices.count,
            rows: rows
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(marker)
            try data.write(to: markerURL, options: .atomic)
        } catch {
            lastError = String(describing: error)
        }
    }
}

private struct QAMenuStateMarker: Encodable {
    var lastUpdatedText: String
    var notificationStatus: String
    var bluetoothPermissionStatus: String
    var lowBatteryThreshold: Int
    var deviceCount: Int
    var rows: [QAMenuDeviceRowMarker]
}

private struct QAMenuDeviceRowMarker: Encodable {
    var name: String
    var percentageText: String
    var statusText: String
    var symbolName: String
    var isLowBattery: Bool
}

private struct FixedNotificationPermissionService: BatteryAlertNotifying {
    var status: NotificationPermissionStatus

    func requestAuthorization() async -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .unknown:
            return false
        }
    }

    func authorizationStatus() async -> NotificationPermissionStatus {
        status
    }

    func sendLowBatteryAlert(_ alert: LowBatteryAlert) async throws {}
}

private struct WidgetCenterReloader: WidgetTimelineReloading {
    func reloadAllTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}

@MainActor
private final class SettingsWindowPresenter {
    static let contentSize = NSSize(width: 560, height: 640)

    private var window: SettingsPanel?

    func show(model: BatteryMonitorViewModel) {
        if window == nil {
            let rootView = SettingsView(model: model)
                .frame(
                    width: Self.contentSize.width,
                    height: Self.contentSize.height
                )
            let hostingController = NSHostingController(rootView: rootView)
            let settingsWindow = SettingsPanel(
                contentRect: NSRect(origin: .zero, size: Self.contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            settingsWindow.title = L10n.text(.settings)
            settingsWindow.identifier = NSUserInterfaceItemIdentifier("BatteryMonitorSettingsWindow")
            settingsWindow.contentViewController = hostingController
            settingsWindow.setContentSize(Self.contentSize)
            settingsWindow.titlebarAppearsTransparent = true
            settingsWindow.isMovableByWindowBackground = true
            settingsWindow.hidesOnDeactivate = false
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.level = .normal
            settingsWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            settingsWindow.center()
            window = settingsWindow
        }

        window?.title = L10n.text(.settings)
        if NSApplication.shared.activationPolicy() == .prohibited {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(NSApplication.shared)
        DispatchQueue.main.async { [weak self] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(NSApplication.shared)
        }
    }
}

private final class SettingsPanel: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

/// Behind-window blur that gives the settings dialog its glass look. On
/// macOS 26 the system material renders in the Liquid Glass style.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct MenuBarContentView: View {
    @ObservedObject var model: BatteryMonitorViewModel

    private var connectedDevices: [BatteryDevice] {
        model.snapshot.connectedDevices
    }

    var body: some View {
        let notificationDisplay = model.notificationPermissionDisplay
        let bluetoothDisplay = model.bluetoothPermissionDisplay

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Battery Monitor")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        await model.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.text(.refresh))
            }

            if connectedDevices.isEmpty {
                ContentUnavailableView { Label(L10n.text(.noBatteryData), systemImage: "battery.0") }
            } else {
                VStack(spacing: 6) {
                    ForEach(connectedDevices) { device in
                        DeviceRowView(device: device, threshold: model.settings.lowBatteryThreshold)
                    }
                }
            }

            Text(model.snapshotSummary.lastUpdatedText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.usedDevelopmentStoreFallback {
                Label(L10n.text(.devFallbackWarning), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let warningText = notificationDisplay.warningText {
                Label(warningText, systemImage: notificationDisplay.symbolName)
                    .font(.caption)
                    .foregroundStyle(notificationDisplay.isAlertingDisabled ? .red : .orange)
            }

            if let settingsActionTitle = notificationDisplay.settingsActionTitle {
                Button {
                    model.openSystemSettings(notificationDisplay.settingsURL)
                } label: {
                    Label(settingsActionTitle, systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
            }

            if let bluetoothWarningText = bluetoothDisplay.warningText {
                Label(bluetoothWarningText, systemImage: bluetoothDisplay.symbolName)
                    .font(.caption)
                    .foregroundStyle(bluetoothDisplay.isBluetoothBatteryLimited ? .orange : .secondary)
            }

            if let bluetoothSettingsActionTitle = bluetoothDisplay.settingsActionTitle {
                Button {
                    model.openSystemSettings(bluetoothDisplay.settingsURL)
                } label: {
                    Label(bluetoothSettingsActionTitle, systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Divider()

            HStack {
                Button {
                    model.openSettingsWindow()
                } label: {
                    Label(L10n.text(.settings), systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label(L10n.text(.quit), systemImage: "power")
                }
            }
        }
    }
}

struct DeviceRowView: View {
    var device: BatteryDevice
    var threshold: Int

    var body: some View {
        let rowModel = MenuBarDeviceRowModel(device: device, threshold: threshold)
        let accent = BatteryLevelStyle.accent(isCharging: rowModel.isCharging, isLowBattery: rowModel.isLowBattery)

        HStack(spacing: 10) {
            Image(systemName: rowModel.symbolName)
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent ?? .primary)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(rowModel.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(rowModel.statusText)
                    .font(.caption)
                    .foregroundStyle(rowModel.isCharging ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            }

            Spacer()

            HStack(spacing: 3) {
                if rowModel.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                }
                Text(rowModel.percentageText)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .foregroundStyle(accent ?? .primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            BatteryLevelMeter(
                fraction: Double(device.percentage) / 100,
                cornerRadius: 9,
                track: AnyShapeStyle(Color.primary.opacity(0.055)),
                fill: AnyShapeStyle((accent ?? .secondary).opacity(accent == nil ? 0.16 : 0.22))
            )
        )
    }
}

struct SettingsView: View {
    @ObservedObject var model: BatteryMonitorViewModel

    var body: some View {
        Form {
            Section(L10n.text(.sectionAlerts)) {
                Stepper(
                    L10n.format(.lowBatteryThresholdLabel, model.settings.lowBatteryThreshold),
                    value: Binding(
                        get: { model.settings.lowBatteryThreshold },
                        set: {
                            model.settings.lowBatteryThreshold = $0
                            model.saveSettings()
                        }
                    ),
                    in: 1...99
                )

                Stepper(
                    L10n.format(.recoveryMarginLabel, model.settings.recoveryMargin, model.settings.recoveryThreshold),
                    value: Binding(
                        get: { model.settings.recoveryMargin },
                        set: {
                            model.settings.recoveryMargin = $0
                            model.saveSettings()
                        }
                    ),
                    in: 1...30
                )

                Stepper(
                    L10n.format(.pollingIntervalLabel, Int(model.settings.pollingInterval / 60)),
                    value: Binding(
                        get: { Int(model.settings.pollingInterval / 60) },
                        set: {
                            model.settings.pollingInterval = TimeInterval($0 * 60)
                            model.saveSettings()
                        }
                    ),
                    in: 1...60
                )

                Stepper(
                    L10n.format(.reminderCooldownLabel, Int(model.settings.reminderCooldown / 3600)),
                    value: Binding(
                        get: { Int(model.settings.reminderCooldown / 3600) },
                        set: {
                            model.settings.reminderCooldown = TimeInterval($0 * 3600)
                            model.saveSettings()
                        }
                    ),
                    in: 1...24
                )
            }

            Section(L10n.text(.sectionDevices)) {
                if model.snapshot.devices.isEmpty {
                    Text(L10n.text(.noDevices))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot.devices) { device in
                        Toggle(
                            L10n.format(.ignoreDeviceToggle, device.name),
                            isOn: Binding(
                                get: { model.settings.isIgnored(device) },
                                set: { model.setIgnored(device: device, ignored: $0) }
                            )
                        )
                    }
                }

                if !model.ignoredDeviceList.unavailableItems.isEmpty {
                    Divider()
                    Text(L10n.text(.unavailableIgnoredDevices))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(model.ignoredDeviceList.unavailableItems) { item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.detailText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                model.removeUnavailableIgnoredDevice(item)
                            } label: {
                                Label(L10n.text(.remove), systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }

            Section(L10n.text(.sectionSystem)) {
                Picker(
                    L10n.text(.languageLabel),
                    selection: Binding(
                        get: { model.settings.language },
                        set: { model.setLanguage($0) }
                    )
                ) {
                    ForEach(LanguagePreference.allCases, id: \.self) { preference in
                        Text(L10n.text(preference.displayNameKey)).tag(preference)
                    }
                }
                Toggle(
                    L10n.text(.launchAtLogin),
                    isOn: Binding(
                        get: { model.loginItemEnabled },
                        set: { model.setLoginItemEnabled($0) }
                    )
                )
                LabeledContent(L10n.text(.notificationPermissionLabel), value: model.notificationPermissionDisplay.statusText)
                if let warningText = model.notificationPermissionDisplay.warningText {
                    Label(warningText, systemImage: model.notificationPermissionDisplay.symbolName)
                        .foregroundStyle(model.notificationPermissionDisplay.isAlertingDisabled ? .red : .orange)
                }
                if let settingsActionTitle = model.notificationPermissionDisplay.settingsActionTitle {
                    Button {
                        model.openSystemSettings(model.notificationPermissionDisplay.settingsURL)
                    } label: {
                        Label(settingsActionTitle, systemImage: "gearshape")
                    }
                }
                LabeledContent(L10n.text(.bluetoothPermissionLabel), value: model.bluetoothPermissionDisplay.statusText)
                if let bluetoothWarningText = model.bluetoothPermissionDisplay.warningText {
                    Label(bluetoothWarningText, systemImage: model.bluetoothPermissionDisplay.symbolName)
                        .foregroundStyle(model.bluetoothPermissionDisplay.isBluetoothBatteryLimited ? .orange : .secondary)
                }
                if let bluetoothSettingsActionTitle = model.bluetoothPermissionDisplay.settingsActionTitle {
                    Button {
                        model.openSystemSettings(model.bluetoothPermissionDisplay.settingsURL)
                    } label: {
                        Label(bluetoothSettingsActionTitle, systemImage: "gearshape")
                    }
                }
                LabeledContent("App Group", value: BatteryMonitorConstants.appGroupIdentifier)
                LabeledContent("Bundle ID", value: BatteryMonitorConstants.bundleIdentifier)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(VisualEffectBackground().ignoresSafeArea())
    }
}
