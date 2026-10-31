// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorBackgroundTransfer",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CapacitorBackgroundTransfer",
            targets: ["BackgroundTransferPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "7.0.0")
    ],
    targets: [
        // Foundation only: records, the store, the remainder copy and the download's part file.
        .target(
            name: "BackgroundTransferCore",
            path: "ios/Sources/BackgroundTransferCore"),
        .target(
            name: "BackgroundTransferPlugin",
            dependencies: [
                "BackgroundTransferCore",
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/BackgroundTransferPlugin")
        // The core's tests are in ios/CoreTests, a package of their own that builds on a Mac
        // without Capacitor's iOS-only binaries: `npm run test:ios`.
    ]
)
