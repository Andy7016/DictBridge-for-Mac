// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DictBridge",
    platforms: [.macOS(.v13)],
    products: [
        // The SwiftUI app. `scripts/build-app.sh` wraps this binary into DictBridge.app.
        .executable(name: "DictBridgeApp", targets: ["DictBridgeApp"]),
        // Command-line front end (also bundled inside the app).
        .executable(name: "dictbridge", targets: ["dictbridge"]),
        .library(name: "DictBridgeCore", targets: ["DictBridgeCore"]),
        .library(name: "MDictKit", targets: ["MDictKit"]),
    ],
    targets: [
        // Pure-Swift reader for MDict .mdx / .mdd files.
        .target(name: "MDictKit"),
        // Conversion pipeline, Apple Dictionary Development Kit driver and dictionary library.
        .target(name: "DictBridgeCore", dependencies: ["MDictKit"]),
        .executableTarget(name: "DictBridgeApp", dependencies: ["DictBridgeCore"]),
        .executableTarget(name: "dictbridge", dependencies: ["DictBridgeCore"]),
        .testTarget(
            name: "MDictKitTests",
            dependencies: ["MDictKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "DictBridgeCoreTests", dependencies: ["DictBridgeCore", "MDictKit"]),
    ]
)
