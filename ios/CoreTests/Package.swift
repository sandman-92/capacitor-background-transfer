// swift-tools-version: 5.9
import PackageDescription

// Runs the plugin's Foundation-only core tests on a Mac (`swift test`), away from the
// plugin package, whose Capacitor binaries are iOS-only. The sources are symlinks to
// ios/Sources/BackgroundTransferCore and ios/Tests/BackgroundTransferCoreTests.
let package = Package(
    name: "BackgroundTransferCoreTests",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "BackgroundTransferCore", path: "Sources/BackgroundTransferCore"),
        .testTarget(name: "BackgroundTransferCoreTests", dependencies: ["BackgroundTransferCore"],
                    path: "Tests/BackgroundTransferCoreTests")
    ]
)
