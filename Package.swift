// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SubmaxxingBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LimitsCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "SubmaxxingBar", dependencies: ["LimitsCore"]),
        .testTarget(name: "LimitsCoreTests", dependencies: ["LimitsCore"]),
    ]
)
