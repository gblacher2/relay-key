// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelayKey",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RelayKeyCore", targets: ["RelayKeyCore"]),
        .executable(name: "RelayKey", targets: ["RelayKey"]),
    ],
    targets: [
        .target(
            name: "RelayKeyCore",
            path: "Sources/RelayKeyCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "RelayKey",
            dependencies: ["RelayKeyCore"],
            path: "Sources/RelayKey",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RelayKeyCoreTests",
            dependencies: ["RelayKeyCore"],
            path: "Tests/RelayKeyCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
