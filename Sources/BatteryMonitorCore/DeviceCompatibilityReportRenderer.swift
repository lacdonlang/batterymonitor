import BatteryMonitorShared
import Darwin
import Foundation

public struct HistoricalCompatibilityDevice: Equatable {
    public var name: String
    public var deviceType: String
    public var percentage: String
    public var chargingStatus: String
    public var source: String

    public init(
        name: String,
        deviceType: String,
        percentage: String,
        chargingStatus: String,
        source: String
    ) {
        self.name = name
        self.deviceType = deviceType
        self.percentage = percentage
        self.chargingStatus = chargingStatus
        self.source = source
    }
}

public enum DeviceCompatibilityReportRenderer {
    private static let knownAccessories = [
        ("Magic Mouse", "外设"),
        ("Magic Keyboard", "外设"),
        ("Magic Trackpad", "外设")
    ]

    public static func render(
        snapshot: BatterySnapshot,
        generatedAt: Date,
        hardwareModel: String? = nil,
        operatingSystemVersion: String? = nil,
        historicalDevices: [HistoricalCompatibilityDevice] = [],
        bluetoothIdentities: [BluetoothDeviceIdentity] = [],
        ioRegistryDiagnostics: [IORegistryBatteryDiagnostic] = []
    ) -> String {
        let hardwareModel = hardwareModel ?? currentHardwareModel()
        let operatingSystemVersion = operatingSystemVersion ?? ProcessInfo.processInfo.operatingSystemVersionString
        let historicalUnavailableDevices = historicalDevices.filter { historicalDevice in
            !snapshot.devices.contains { sameDeviceName($0.name, historicalDevice.name) }
        }
        let rows = reportRows(devices: snapshot.devices, historicalDevices: historicalUnavailableDevices)
        let supportedDevices = (
            snapshot.devices.map { "- \($0.name)（\($0.percentage)%）" }
                + historicalUnavailableDevices.map {
                    "- \($0.name)（\($0.percentage)，历史已验证；当前未检测到）"
                }
        )
            .joined(separator: "\n")
        let fallbackDevices = knownAccessories
            .filter { accessory in
                !snapshot.devices.contains { $0.name.localizedCaseInsensitiveContains(accessory.0) }
                    && !historicalUnavailableDevices.contains {
                        $0.name.localizedCaseInsensitiveContains(accessory.0)
                    }
            }
            .map {
                "- \($0.0)：当前未检测到；接入后运行 `./scripts/verify_device_visible.sh --name \"\($0.0)\" --kind peripheral` 并重跑 M0 CLI 报告"
            }
            .joined(separator: "\n")
        let bluetoothDiagnostics = bluetoothCandidateRows(
            devices: snapshot.devices,
            identities: bluetoothIdentities
        )
        let ioRegistryDiagnosticText = ioRegistryDiagnosticRows(ioRegistryDiagnostics)
        let historicalConclusion = historicalUnavailableDevices.isEmpty
            ? ""
            : "\n- 另有 \(historicalUnavailableDevices.count) 个历史已验证设备当前未检测到；保留在 MVP 支持范围，接入或唤醒后应再次验证可见。"

        return """
        # Device Compatibility Report

        日期：\(ISO8601DateFormatter().string(from: generatedAt))  
        机器型号：\(hardwareModel)  
        macOS 版本：\(operatingSystemVersion)  
        验证方式：M0 默认组合 CLI（IOKit Power Sources + IORegistry HID BatteryPercent + IOBluetooth runtime battery + CoreBluetooth BLE Battery Service）

        ## 结论

        - 默认组合 reader 当前可见 \(snapshot.devices.count) 个电池设备。\(historicalConclusion)
        - 后续 M1-M3 的必须支持范围以本报告中 `组合 reader 是否可见` 以 `是` 开头的设备为准。
        - 未连接或未检测到的外设不进入当前 MVP 必须支持范围；接入真实设备后可先用 `scripts/verify_device_visible.sh` 校验，再重跑本报告。

        ## 设备清单

        | 设备名称 | 设备类型 | 组合 reader 是否可见 | 电量 | 充电状态 | 备注 |
        | --- | --- | --- | --- | --- | --- |
        \(rows)

        ## MVP 必须支持范围

        \(supportedDevices.isEmpty ? "- 当前没有可见设备" : supportedDevices)

        ## 需要后续 fallback 的设备

        \(fallbackDevices.isEmpty ? "- 当前没有发现必须提前引入 fallback 的设备" : fallbackDevices)

        ## 蓝牙候选设备诊断

        \(bluetoothDiagnostics)

        ## IORegistry 电池字段诊断

        \(ioRegistryDiagnosticText)
        """
    }

    public static func historicalDevices(from report: String) -> [HistoricalCompatibilityDevice] {
        report.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|"), line.hasSuffix("|") else {
                return nil
            }

            let columns = line
                .dropFirst()
                .dropLast()
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count == 6,
                  columns[0] != "设备名称",
                  !columns[0].contains("---"),
                  columns[2].hasPrefix("是") else {
                return nil
            }

            return HistoricalCompatibilityDevice(
                name: columns[0],
                deviceType: columns[1],
                percentage: columns[3],
                chargingStatus: columns[4],
                source: baseSourceText(columns[5])
            )
        }
    }

    private static func reportRows(
        devices: [BatteryDevice],
        historicalDevices: [HistoricalCompatibilityDevice]
    ) -> String {
        var rows = devices.map { device in
            "| \(device.name) | \(typeText(device.kind)) | 是 | \(device.percentage)% | \(chargingText(device.isCharging)) | \(device.source) |"
        }

        rows.append(contentsOf: historicalDevices.map { device in
            "| \(device.name) | \(device.deviceType) | 是（历史验证，当前未检测到） | \(device.percentage) | \(device.chargingStatus) | \(device.source)；接入或唤醒后重跑 M0 CLI |"
        })

        for accessory in knownAccessories {
            guard !devices.contains(where: { $0.name.localizedCaseInsensitiveContains(accessory.0) }),
                  !historicalDevices.contains(where: { $0.name.localizedCaseInsensitiveContains(accessory.0) }) else {
                continue
            }
            rows.append("| \(accessory.0) | \(accessory.1) | 否（当前未检测到） | 不适用 | 未知 | 接入后运行设备可见性校验并重跑 M0 CLI 报告 |")
        }

        return rows.joined(separator: "\n")
    }

    private static func bluetoothCandidateRows(
        devices: [BatteryDevice],
        identities: [BluetoothDeviceIdentity]
    ) -> String {
        let candidates = identities
            .filter(isBatteryCandidate)
            .filter { identity in
                !devices.contains { sameVisibleDevice($0, identity: identity) }
            }

        guard !candidates.isEmpty else {
            return "- 当前没有发现系统已记录但默认组合 reader 未显示的蓝牙电池候选设备。"
        }

        let rows = candidates.map { identity in
            let state = connectionStateText(identity.isConnected)
            let type = identity.minorType?.trimmingCharacters(in: .whitespacesAndNewlines)
            let typeText = (type?.isEmpty == false) ? type! : "未知"
            let reason: String
            let action: String
            switch identity.isConnected {
            case .some(true):
                reason = "已连接但未读取到电量"
                action = "检查蓝牙权限后重跑 CLI；如仍缺失需补充 fallback"
            case .some(false):
                reason = "未连接，当前无法读取实时电量"
                action = "连接或唤醒设备后运行设备可见性校验"
            case .none:
                reason = "连接状态未知，当前未读取到电量"
                action = "确认连接状态后重跑 CLI"
            }

            return "| \(identity.name) | \(state) | \(typeText) | \(reason) | \(action) |"
        }

        return """
        | 设备名称 | 连接状态 | 类型 | 默认组合 reader 状态 | 建议 |
        | --- | --- | --- | --- | --- |
        \(rows.joined(separator: "\n"))
        """
    }

    private static func ioRegistryDiagnosticRows(_ diagnostics: [IORegistryBatteryDiagnostic]) -> String {
        guard !diagnostics.isEmpty else {
            return "- 当前没有 IORegistry BatteryPercent 外设记录。"
        }

        let rows = diagnostics.map { diagnostic in
            let chargingFields = diagnostic.chargingFields.isEmpty
                ? "未上报（缺少 IsCharging/Is Charging/Charging/FullyCharged 字段）"
                : diagnostic.chargingFields.joined(separator: ", ")
            let flags = diagnostic.batteryStatusFlags ?? "未上报"
            let decodedCharging = chargingText(diagnostic.inferredChargingState)
            let supportsExtended = diagnostic.supportsExtendedBatteryState ?? "未上报"
            let address = diagnostic.address.isEmpty ? "未上报" : diagnostic.address
            return "| \(diagnostic.name) | \(diagnostic.percentage)% | \(chargingFields) | \(flags) | \(decodedCharging) | \(supportsExtended) | \(address) |"
        }

        return """
        | 设备名称 | 电量 | 显式充电字段 | BatteryStatusFlags | flags 解码充电状态 | SupportsExtendedBatteryState | 地址 |
        | --- | --- | --- | --- | --- | --- | --- |
        \(rows.joined(separator: "\n"))
        """
    }

    private static func isBatteryCandidate(_ identity: BluetoothDeviceIdentity) -> Bool {
        let name = normalizedName(identity.name)
        let minorType = normalizedName(identity.minorType ?? "")
        let candidateTerms = [
            "airpods",
            "headphone",
            "keyboard",
            "magic-keyboard",
            "magic-mouse",
            "magic-trackpad",
            "mouse",
            "mx-master",
            "trackpad"
        ]
        return candidateTerms.contains { term in
            name.contains(term) || minorType.contains(term)
        }
    }

    private static func sameVisibleDevice(_ device: BatteryDevice, identity: BluetoothDeviceIdentity) -> Bool {
        let identityAddress = normalizedAddress(identity.address)
        if identityAddress.count >= 12,
           let deviceIDToken = device.id.split(separator: ":", maxSplits: 1).last,
           normalizedAddress(String(deviceIDToken)) == identityAddress {
            return true
        }

        let deviceName = normalizedName(device.name)
        let identityName = normalizedName(identity.name)
        return !deviceName.isEmpty
            && !identityName.isEmpty
            && (deviceName.contains(identityName) || identityName.contains(deviceName))
    }

    private static func connectionStateText(_ isConnected: Bool?) -> String {
        switch isConnected {
        case .some(true):
            return "已连接"
        case .some(false):
            return "未连接"
        case .none:
            return "未知"
        }
    }

    private static func typeText(_ kind: DeviceKind) -> String {
        switch kind {
        case .internalBattery:
            return "本机电池"
        case .peripheral:
            return "外设"
        case .ups:
            return "UPS"
        case .unknown:
            return "未知"
        }
    }

    private static func chargingText(_ isCharging: Bool?) -> String {
        switch isCharging {
        case .some(true):
            return "充电中"
        case .some(false):
            return "未充电"
        case .none:
            return "未上报"
        }
    }

    private static func sameDeviceName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" {
                    return
                }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func normalizedAddress(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { scalar in
            CharacterSet(charactersIn: "0123456789abcdef").contains(scalar)
        })
    }

    private static func baseSourceText(_ source: String) -> String {
        source.split(separator: "；", maxSplits: 1).first.map(String.init) ?? source
    }

    private static func currentHardwareModel() -> String {
        MacProductName.sysctlString("hw.model") ?? ""
    }
}
