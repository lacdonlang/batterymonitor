import Foundation
import BatteryMonitorShared
import ServiceManagement

public enum LoginItemError: Error, CustomStringConvertible, Sendable {
    case unsupportedRuntime(String)

    public var description: String {
        switch self {
        case let .unsupportedRuntime(message):
            return message
        }
    }
}

public protocol LoginItemManaging: Sendable {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

public protocol LoginItemControlling {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

public final class MainAppLoginItemService: LoginItemManaging, @unchecked Sendable {
    private let loginItem: any LoginItemControlling

    public convenience init() {
        self.init(loginItem: SMAppService.mainApp)
    }

    public init(loginItem: any LoginItemControlling) {
        self.loginItem = loginItem
    }

    public func isEnabled() -> Bool {
        loginItem.isEnabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard loginItem.isEnabled != enabled else {
            return
        }

        if enabled {
            try loginItem.register()
        } else {
            try loginItem.unregister()
        }
    }
}

public final class SettingsBackedLoginItemService: LoginItemManaging, @unchecked Sendable {
    private let loginItemService: any LoginItemManaging
    private let settingsStore: SettingsStore

    public init(loginItemService: any LoginItemManaging, settingsStore: SettingsStore) {
        self.loginItemService = loginItemService
        self.settingsStore = settingsStore
    }

    public func isEnabled() -> Bool {
        loginItemService.isEnabled()
    }

    public func setEnabled(_ enabled: Bool) throws {
        try loginItemService.setEnabled(enabled)
        try persistLaunchAtLogin(isEnabled())
    }

    @discardableResult
    public func synchronizeFromSystem() throws -> Bool {
        let enabled = isEnabled()
        try persistLaunchAtLogin(enabled)
        return enabled
    }

    private func persistLaunchAtLogin(_ enabled: Bool) throws {
        var settings = settingsStore.load()
        guard settings.launchAtLogin != enabled else {
            return
        }

        settings.launchAtLogin = enabled
        try settingsStore.save(settings)
    }
}

extension SMAppService: LoginItemControlling {
    public var isEnabled: Bool {
        status == .enabled
    }
}
