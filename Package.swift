// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ADOPulse",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ADOPulse", targets: ["ADOPulse"]),
    ],
    targets: [
        .target(name: "ADOPulseCore"),
        .executableTarget(
            name: "ADOPulse",
            dependencies: ["ADOPulseCore"]
        ),
        .testTarget(
            name: "ADOPulseCoreTests",
            dependencies: ["ADOPulseCore"]
        ),
    ]
)
