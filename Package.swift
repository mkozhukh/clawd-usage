// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawdUsage",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClawdUsage", targets: ["ClawdUsage"])],
    targets: [
        .target(name: "ClawdCore"),
        .executableTarget(name: "ClawdUsage", dependencies: ["ClawdCore"]),
        .target(name: "ClawdCoreChecks", dependencies: ["ClawdCore"], path: "Tests/Support"),
        .executableTarget(name: "ClawdChecks", dependencies: ["ClawdCoreChecks"], path: "Checks"),
        .executableTarget(name: "ClawdIcon", dependencies: ["ClawdCore"], path: "Tools/ClawdIcon"),
        .testTarget(name: "ClawdCoreTests", dependencies: ["ClawdCoreChecks"])
    ]
)
