import Foundation
import BatteryMonitorShared

public protocol WidgetTimelineReloading: Sendable {
    func reloadAllTimelines()
}

public struct NoopWidgetTimelineReloader: WidgetTimelineReloading {
    public init() {}

    public func reloadAllTimelines() {}
}

public struct MonitorRefreshResult: Equatable, Sendable {
    public var snapshot: BatterySnapshot
    public var alerts: [LowBatteryAlert]
    public var notificationStates: [String: DeviceNotificationState]
    public var notificationErrorDescription: String?

    public init(
        snapshot: BatterySnapshot,
        alerts: [LowBatteryAlert],
        notificationStates: [String: DeviceNotificationState],
        notificationErrorDescription: String? = nil
    ) {
        self.snapshot = snapshot
        self.alerts = alerts
        self.notificationStates = notificationStates
        self.notificationErrorDescription = notificationErrorDescription
    }
}

public typealias PowerSourceChangeObserverFactory = @Sendable (@escaping @Sendable () -> Void) -> any PowerSourceChangeObserving

public final class MonitorEngine: @unchecked Sendable {
    public var onRefresh: (@Sendable (MonitorRefreshResult) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    private let reader: any BatteryReading
    private let store: SharedBatteryStore
    private let settingsStore: SettingsStore
    private let notifier: any BatteryAlertNotifying
    private let widgetReloader: any WidgetTimelineReloading
    private let powerSourceObserverFactory: PowerSourceChangeObserverFactory?
    private var monitorTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var powerSourceObserver: (any PowerSourceChangeObserving)?

    public init(
        reader: any BatteryReading = DefaultBatteryReader(),
        store: SharedBatteryStore,
        settingsStore: SettingsStore,
        notifier: any BatteryAlertNotifying = UserNotificationService(),
        widgetReloader: any WidgetTimelineReloading = NoopWidgetTimelineReloader(),
        powerSourceObserverFactory: PowerSourceChangeObserverFactory? = { onChange in
            PowerSourceChangeObserver(onChange: onChange)
        }
    ) {
        self.reader = reader
        self.store = store
        self.settingsStore = settingsStore
        self.notifier = notifier
        self.widgetReloader = widgetReloader
        self.powerSourceObserverFactory = powerSourceObserverFactory
    }

    deinit {
        stop()
    }

    @discardableResult
    public func refresh(now: Date = Date()) async throws -> MonitorRefreshResult {
        let devices = try reader.readDevices(now: now)
        let snapshot = Self.snapshotRetainingRecentlySeenDevices(
            currentDevices: devices,
            previousSnapshot: try? store.readSnapshot(),
            now: now
        )
        try store.writeSnapshot(snapshot)

        let settings = settingsStore.load()
        let states = try store.readNotificationStates()
        let evaluation = RuleEngine(settings: settings).evaluate(
            snapshot: snapshot,
            states: states,
            now: now
        )

        var statesToPersist = evaluation.updatedStates
        var notificationErrorDescription: String?
        do {
            try await notifier.sendLowBatteryAlerts(evaluation.alerts)
        } catch {
            notificationErrorDescription = String(describing: error)
            // Sending failed, so roll back lastNotifiedAt for alerted devices;
            // the next poll re-evaluates them and retries the notification.
            for alert in evaluation.alerts {
                statesToPersist[alert.device.id]?.lastNotifiedAt = states[alert.device.id]?.lastNotifiedAt
            }
        }

        try store.writeNotificationStates(statesToPersist)
        widgetReloader.reloadAllTimelines()

        let result = MonitorRefreshResult(
            snapshot: snapshot,
            alerts: evaluation.alerts,
            notificationStates: statesToPersist,
            notificationErrorDescription: notificationErrorDescription
        )
        onRefresh?(result)
        return result
    }

    /// Devices such as AirPods disappear from every reader the moment they
    /// disconnect. Keep them in the snapshot as disconnected entries with their
    /// last known percentage until they have been unseen for the retention window.
    public static let disconnectedDeviceRetentionInterval: TimeInterval = 7 * 24 * 3600

    public static func snapshotRetainingRecentlySeenDevices(
        currentDevices: [BatteryDevice],
        previousSnapshot: BatterySnapshot?,
        now: Date,
        retentionInterval: TimeInterval = disconnectedDeviceRetentionInterval
    ) -> BatterySnapshot {
        guard let previousSnapshot else {
            return BatterySnapshot(devices: currentDevices, updatedAt: now)
        }

        let retained = previousSnapshot.devices
            .filter { device in
                let unseenInterval = now.timeIntervalSince(device.updatedAt)
                return unseenInterval >= 0 && unseenInterval <= retentionInterval
            }
            .map { device in
                var disconnected = device
                disconnected.isConnected = false
                disconnected.isCharging = nil
                return disconnected
            }

        let merged = CompositeBatteryReader.deduplicated(currentDevices + retained)
        return BatterySnapshot(devices: merged, updatedAt: now)
    }

    public func start() {
        guard monitorTask == nil else {
            return
        }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                do {
                    try await self.refresh()
                } catch {
                    self.onError?(error)
                }

                let settings = self.settingsStore.load()
                let sleepInterval = UInt64(settings.pollingInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepInterval)
            }
        }

        if powerSourceObserver == nil, let powerSourceObserverFactory {
            let observer = powerSourceObserverFactory { [weak self] in
                self?.refreshFromPowerSourceChange()
            }
            powerSourceObserver = observer
            observer.start()
        }
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        powerSourceObserver?.stop()
        powerSourceObserver = nil
    }

    private func refreshFromPowerSourceChange() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.refresh()
            } catch {
                self.onError?(error)
            }
        }
    }
}
