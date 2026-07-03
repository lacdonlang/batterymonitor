// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "BatteryMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BatteryMonitorShared",
            targets: ["BatteryMonitorShared"]
        ),
        .library(
            name: "BatteryMonitorCore",
            targets: ["BatteryMonitorCore"]
        ),
        .executable(
            name: "BatteryMonitorCLI",
            targets: ["BatteryMonitorCLI"]
        ),
        .executable(
            name: "BatteryMonitorApp",
            targets: ["BatteryMonitorApp"]
        ),
        .executable(
            name: "BatteryMonitorWidget",
            targets: ["BatteryMonitorWidget"]
        ),
        .executable(
            name: "BatteryMonitorTestHarness",
            targets: ["BatteryMonitorTestHarness"]
        )
    ],
    targets: [
        .target(
            name: "BatteryMonitorShared"
        ),
        .target(
            name: "BatteryMonitorCore",
            dependencies: ["BatteryMonitorShared"],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "BatteryMonitorCLI",
            dependencies: ["BatteryMonitorCore", "BatteryMonitorShared"]
        ),
        .executableTarget(
            name: "BatteryMonitorApp",
            dependencies: ["BatteryMonitorCore", "BatteryMonitorShared"]
        ),
        .executableTarget(
            name: "BatteryMonitorWidget",
            dependencies: ["BatteryMonitorShared"]
        ),
        .executableTarget(
            name: "BatteryMonitorTestHarness",
            dependencies: ["BatteryMonitorCore", "BatteryMonitorShared"]
        )
    ],
    swiftLanguageModes: [.v6]
)
