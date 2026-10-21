// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ADOPulse",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ADOPulseCore"),
        .testTarget(
            name: "ADOPulseCoreTests",
            dependencies: ["ADOPulseCore"]
        ),
    ]
)
