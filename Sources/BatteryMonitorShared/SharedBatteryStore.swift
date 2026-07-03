import Foundation

public enum SharedBatteryStoreError: Error, CustomStringConvertible, Sendable {
    case appGroupContainerUnavailable(String)
    case cannotCreateDirectory(URL)

    public var description: String {
        switch self {
        case let .appGroupContainerUnavailable(identifier):
            return "App Group container is unavailable for \(identifier)."
        case let .cannotCreateDirectory(url):
            return "Unable to create store directory at \(url.path)."
        }
    }
}

public struct SharedBatteryStore {
    public let directoryURL: URL
    public let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) throws {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        try createDirectoryIfNeeded(directoryURL)
    }

    public static func appGroup(
        identifier: String = BatteryMonitorConstants.appGroupIdentifier,
        fileManager: FileManager = .default
    ) throws -> SharedBatteryStore {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            throw SharedBatteryStoreError.appGroupContainerUnavailable(identifier)
        }

        return try SharedBatteryStore(directoryURL: containerURL, fileManager: fileManager)
    }

    public static func developmentFallbackDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent(BatteryMonitorConstants.appName, isDirectory: true)
            .appendingPathComponent("Shared", isDirectory: true)
    }

    public static func appGroupOrDevelopmentFallback(
        identifier: String = BatteryMonitorConstants.appGroupIdentifier,
        fileManager: FileManager = .default
    ) throws -> (store: SharedBatteryStore, usedFallback: Bool) {
        do {
            return (try appGroup(identifier: identifier, fileManager: fileManager), false)
        } catch {
            let fallbackURL = try developmentFallbackDirectory(fileManager: fileManager)
            return (try SharedBatteryStore(directoryURL: fallbackURL, fileManager: fileManager), true)
        }
    }

    public func readSnapshot() throws -> BatterySnapshot? {
        try read(BatterySnapshot.self, fileName: BatteryMonitorConstants.snapshotFileName)
    }

    public func writeSnapshot(_ snapshot: BatterySnapshot) throws {
        try write(snapshot, fileName: BatteryMonitorConstants.snapshotFileName)
    }

    public func readNotificationStates() throws -> [String: DeviceNotificationState] {
        try read([String: DeviceNotificationState].self, fileName: BatteryMonitorConstants.notificationStateFileName) ?? [:]
    }

    public func writeNotificationStates(_ states: [String: DeviceNotificationState]) throws {
        try write(states, fileName: BatteryMonitorConstants.notificationStateFileName)
    }

    public func snapshotFileURL() -> URL {
        directoryURL.appendingPathComponent(BatteryMonitorConstants.snapshotFileName, isDirectory: false)
    }

    public func notificationStateFileURL() -> URL {
        directoryURL.appendingPathComponent(BatteryMonitorConstants.notificationStateFileName, isDirectory: false)
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw SharedBatteryStoreError.cannotCreateDirectory(url)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, fileName: String) throws -> T? {
        let fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONCoding.decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, fileName: String) throws {
        let fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let temporaryURL = directoryURL.appendingPathComponent(".\(fileName).tmp", isDirectory: false)
        let data = try JSONCoding.encoder.encode(value)
        try data.write(to: temporaryURL, options: [.atomic])

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
