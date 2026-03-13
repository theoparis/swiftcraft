// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "LCE",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "LCE",
            targets: ["LCE"]
        )
    ],
    targets: [
        .executableTarget(
            name: "LCE",
            resources: [
                .copy("Shaders.metal"),
                .copy("../../res/terrain.png")
            ]
        )
    ]
)
