import BatteryMonitorShared
import Foundation
@preconcurrency import CoreBluetooth

public enum BluetoothPermissionStatus: String, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
    case unknown
}

public struct BluetoothPermissionDisplayModel: Equatable, Sendable {
    public var statusText: String
    public var warningText: String?
    public var settingsActionTitle: String?
    public var settingsURL: URL?
    public var symbolName: String
    public var isBluetoothBatteryLimited: Bool

    public init(status: BluetoothPermissionStatus) {
        switch status {
        case .notDetermined:
            statusText = L10n.text(.permissionNotRequested)
            warningText = nil
            settingsActionTitle = nil
            settingsURL = nil
            symbolName = "antenna.radiowaves.left.and.right"
            isBluetoothBatteryLimited = false
        case .denied:
            statusText = L10n.text(.permissionDenied)
            warningText = L10n.text(.bluetoothDeniedWarning)
            settingsActionTitle = L10n.text(.openSystemSettings)
            settingsURL = SystemSettingsDestination.bluetooth
            symbolName = "antenna.radiowaves.left.and.right.slash"
            isBluetoothBatteryLimited = true
        case .restricted:
            statusText = L10n.text(.permissionRestricted)
            warningText = L10n.text(.bluetoothRestrictedWarning)
            settingsActionTitle = L10n.text(.openSystemSettings)
            settingsURL = SystemSettingsDestination.bluetooth
            symbolName = "antenna.radiowaves.left.and.right.slash"
            isBluetoothBatteryLimited = true
        case .authorized:
            statusText = L10n.text(.permissionAuthorized)
            warningText = nil
            settingsActionTitle = nil
            settingsURL = nil
            symbolName = "antenna.radiowaves.left.and.right"
            isBluetoothBatteryLimited = false
        case .unknown:
            statusText = L10n.text(.permissionUnknown)
            warningText = L10n.text(.bluetoothUnknownWarning)
            settingsActionTitle = L10n.text(.openSystemSettings)
            settingsURL = SystemSettingsDestination.bluetooth
            symbolName = "questionmark.circle"
            isBluetoothBatteryLimited = false
        }
    }
}

public protocol BluetoothPermissionProviding: Sendable {
    func authorizationStatus() -> BluetoothPermissionStatus
}

public struct SystemBluetoothPermissionService: BluetoothPermissionProviding {
    public init() {}

    public func authorizationStatus() -> BluetoothPermissionStatus {
        switch CBCentralManager.authorization {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .allowedAlways:
            return .authorized
        @unknown default:
            return .unknown
        }
    }
}
