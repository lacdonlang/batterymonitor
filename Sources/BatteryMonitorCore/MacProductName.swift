import Foundation
import IOKit

/// Resolves a user-facing name for this Mac (e.g. "MacBook Pro") so the
/// internal battery doesn't show up as "InternalBattery-0".
public enum MacProductName {
    public static let displayName: String = resolve()

    static func resolve() -> String {
        if let productName = deviceTreeProductName() {
            return trimmedMarketingName(productName)
        }
        if let model = sysctlString("hw.model"), let mapped = marketingName(forModelIdentifier: model) {
            return mapped
        }
        return "Mac"
    }

    /// Apple Silicon Macs expose the marketing name in the device tree,
    /// e.g. "MacBook Pro (14-inch, Nov 2023)".
    private static func deviceTreeProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else {
            return nil
        }
        defer { IOObjectRelease(entry) }

        guard let value = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else {
            return nil
        }

        let name = String(decoding: value, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        return name.isEmpty ? nil : name
    }

    /// "MacBook Pro (14-inch, Nov 2023)" → "MacBook Pro"
    public static func trimmedMarketingName(_ name: String) -> String {
        guard let parenthesisIndex = name.firstIndex(of: "(") else {
            return name.trimmingCharacters(in: .whitespaces)
        }
        let trimmed = String(name[..<parenthesisIndex]).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    /// Intel Macs only report identifiers such as "MacBookPro16,1".
    public static func marketingName(forModelIdentifier identifier: String) -> String? {
        let prefixes: [(String, String)] = [
            ("MacBookPro", "MacBook Pro"),
            ("MacBookAir", "MacBook Air"),
            ("MacBook", "MacBook"),
            ("Macmini", "Mac mini"),
            ("MacPro", "Mac Pro"),
            ("MacStudio", "Mac Studio"),
            ("iMacPro", "iMac Pro"),
            ("iMac", "iMac")
        ]
        return prefixes.first { identifier.hasPrefix($0.0) }?.1
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}
