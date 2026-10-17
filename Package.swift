// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DanteSwitcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dante-sync", targets: ["dante-sync"]),
        .library(name: "DanteSyncCore", targets: ["DanteSyncCore"]),
    ],
    targets: [
        .target(name: "DanteSyncCore"),
        .executableTarget(name: "dante-sync", dependencies: ["DanteSyncCore"]),
        .testTarget(name: "DanteSyncCoreTests", dependencies: ["DanteSyncCore"]),
    ]
)
