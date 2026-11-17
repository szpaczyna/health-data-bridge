// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WHOOPHealthSync",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WHOOPHealthSyncCore",
            targets: ["WHOOPHealthSyncCore"]
        )
    ],
    targets: [
        .target(
            name: "WHOOPHealthSyncCore"
        ),
        .testTarget(name: "WHOOPHealthSyncCoreTests", dependencies: ["WHOOPHealthSyncCore"])
    ]
)
