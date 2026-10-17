// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawdMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClawdMac", targets: ["ClawdMac"])],
    targets: [
        .target(name: "ClawdCore"),
        .executableTarget(name: "ClawdMac", dependencies: ["ClawdCore"]),
        .target(name: "ClawdCoreChecks", dependencies: ["ClawdCore"], path: "Tests/Support"),
        .executableTarget(name: "ClawdChecks", dependencies: ["ClawdCoreChecks"], path: "Checks"),
        .testTarget(name: "ClawdCoreTests", dependencies: ["ClawdCoreChecks"])
    ]
)
