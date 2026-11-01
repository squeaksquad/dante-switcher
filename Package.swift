// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DanteSwitcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dante-sync", targets: ["dante-sync"]),
        .executable(name: "DanteSwitcher", targets: ["DanteSwitcher"]),
        .library(name: "DanteSyncCore", targets: ["DanteSyncCore"]),
    ],
    targets: [
        .target(name: "DanteSyncCore"),
        .executableTarget(name: "dante-sync", dependencies: ["DanteSyncCore"]),
        // Bundled into DanteSwitcher.app by scripts/build_app.sh (Info.plist, signing).
        .executableTarget(name: "DanteSwitcher", dependencies: ["DanteSyncCore"]),
        .testTarget(name: "DanteSyncCoreTests", dependencies: ["DanteSyncCore"]),
    ]
)
