// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "raster-webp-tools",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "webp-tools")
    ]
)
