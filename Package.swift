// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Fleetlight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FleetlightCore", targets: ["FleetlightCore"]),
        .executable(name: "Fleetlight", targets: ["Fleetlight"]),
        .executable(name: "FleetlightSelfTest", targets: ["FleetlightSelfTest"]),
    ],
    targets: [
        .target(name: "FleetlightCore"),
        .executableTarget(
            name: "Fleetlight",
            dependencies: ["FleetlightCore"]
        ),
        .executableTarget(
            name: "FleetlightSelfTest",
            dependencies: ["FleetlightCore"]
        ),
    ]
)
