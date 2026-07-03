import Foundation

public struct SettingsStore {
    public let fileURL: URL
    public let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.init(
            fileURL: directoryURL.appendingPathComponent(BatteryMonitorConstants.settingsFileName),
            fileManager: fileManager
        )
    }

    public func load() -> MonitorSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .default
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONCoding.decoder.decode(MonitorSettings.self, from: data)
        } catch {
            return .default
        }
    }

    public func save(_ settings: MonitorSettings) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder.encode(settings)
        let temporaryURL = directoryURL.appendingPathComponent(".\(BatteryMonitorConstants.settingsFileName).tmp")
        try data.write(to: temporaryURL, options: [.atomic])

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }
}
