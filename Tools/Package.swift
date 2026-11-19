// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "raster-webp-tools",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "webp-tools",
            dependencies: [
                .product(name: "RasterWebP", package: "swift-raster-webp")
            ]
        )
    ]
)
