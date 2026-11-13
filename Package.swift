// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LocalBench",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "LocalBenchCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "LocalBenchApp",
            dependencies: ["LocalBenchCore"]
        ),
        .executableTarget(
            name: "localbench",
            dependencies: ["LocalBenchCore"]
        ),
        .executableTarget(
            name: "Spike",
            path: "Sources/Spike"
        ),
        .testTarget(
            name: "LocalBenchCoreTests",
            dependencies: ["LocalBenchCore"]
        ),
    ]
)
