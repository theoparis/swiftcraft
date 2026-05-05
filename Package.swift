// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftCraft",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "SwiftCraft",
            targets: ["SwiftCraft"]
        )
    ],
    targets: [
        .executableTarget(
            name: "SwiftCraft",
            resources: [
                .copy("Shaders.metal"),
                .copy("../../res/terrain.png"),
            ]
        )
    ]
)
