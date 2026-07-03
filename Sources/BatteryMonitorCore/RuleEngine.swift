import Foundation
import BatteryMonitorShared

public struct RuleEvaluation: Equatable, Sendable {
    public var alerts: [LowBatteryAlert]
    public var updatedStates: [String: DeviceNotificationState]

    public init(alerts: [LowBatteryAlert], updatedStates: [String: DeviceNotificationState]) {
        self.alerts = alerts
        self.updatedStates = updatedStates
    }
}

public struct RuleEngine: Sendable {
    public var settings: MonitorSettings

    public init(settings: MonitorSettings) {
        self.settings = settings
    }

    /// Notification states for devices that have not been seen for this long
    /// are dropped so the state file does not accumulate stale entries.
    public static let staleStateRetentionInterval: TimeInterval = 30 * 24 * 3600

    public func evaluate(
        snapshot: BatterySnapshot,
        states existingStates: [String: DeviceNotificationState],
        now: Date
    ) -> RuleEvaluation {
        var updatedStates = existingStates.filter { _, state in
            now.timeIntervalSince(state.updatedAt) <= Self.staleStateRetentionInterval
        }
        var alerts: [LowBatteryAlert] = []
        let visibleDeviceIDs = Set(snapshot.devices.map(\.id))

        for device in snapshot.connectedDevices {
            let migratedState = stateForDevice(device, in: updatedStates, visibleDeviceIDs: visibleDeviceIDs)
            if let migratedState, migratedState.key != device.id {
                updatedStates.removeValue(forKey: migratedState.key)
            }

            var state = migratedState?.state ?? DeviceNotificationState(
                deviceID: device.id,
                lastNotifiedAt: nil,
                wasLowBattery: false,
                lastSeenPercentage: nil,
                updatedAt: now
            )

            state.deviceID = device.id
            state.lastSeenPercentage = device.percentage
            state.updatedAt = now
            state.deviceName = device.name
            state.deviceKind = device.kind
            state.deviceSource = device.source

            if settings.isIgnored(device) {
                updatedStates[device.id] = state
                continue
            }

            if device.percentage >= settings.recoveryThreshold {
                state.wasLowBattery = false
                updatedStates[device.id] = state
                continue
            }

            guard device.percentage < settings.lowBatteryThreshold else {
                updatedStates[device.id] = state
                continue
            }

            let wasLowBatteryBeforeUpdate = state.wasLowBattery
            state.wasLowBattery = true

            guard device.isLowBatteryRelevantWhileCharging else {
                updatedStates[device.id] = state
                continue
            }

            if shouldNotify(wasLowBatteryBeforeUpdate: wasLowBatteryBeforeUpdate, state: state, now: now) {
                alerts.append(LowBatteryAlert(device: device, threshold: settings.lowBatteryThreshold))
                state.lastNotifiedAt = now
            }

            updatedStates[device.id] = state
        }

        return RuleEvaluation(alerts: alerts, updatedStates: updatedStates)
    }

    private func shouldNotify(
        wasLowBatteryBeforeUpdate: Bool,
        state: DeviceNotificationState,
        now: Date
    ) -> Bool {
        if !wasLowBatteryBeforeUpdate {
            return true
        }

        guard let lastNotifiedAt = state.lastNotifiedAt else {
            return true
        }

        return now.timeIntervalSince(lastNotifiedAt) >= settings.reminderCooldown
    }

    private func stateForDevice(
        _ device: BatteryDevice,
        in states: [String: DeviceNotificationState],
        visibleDeviceIDs: Set<String>
    ) -> (key: String, state: DeviceNotificationState)? {
        if let state = states[device.id] {
            return (device.id, state)
        }

        // Fingerprint migration must never steal state from a device that is
        // still visible under its own ID, and must give up when several
        // orphaned states share the same fingerprint (two same-named devices).
        let candidates = states.filter { key, state in
            !visibleDeviceIDs.contains(key)
                && state.deviceName?.caseInsensitiveCompare(device.name) == .orderedSame
                && state.deviceKind == device.kind
                && state.deviceSource == device.source
        }

        guard candidates.count == 1, let match = candidates.first else {
            return nil
        }

        return (match.key, match.value)
    }
}
