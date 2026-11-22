// swift-tools-version: 6.2

import PackageDescription

// Measuring programs for Scripts/compare-decoders.sh. The repository must be checked out in a
// directory named swift-raster-webp, which gives the dependency its package identity.
let package = Package(
    name: "comparison-swift",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../..")],
    targets: [
        .target(name: "BenchSupport"),
        .executableTarget(
            name: "raster-bench",
            dependencies: ["BenchSupport", .product(name: "RasterWebP", package: "swift-raster-webp")]
        ),
        .executableTarget(name: "imageio-bench", dependencies: ["BenchSupport"]),
        .executableTarget(name: "size-empty"),
        .executableTarget(
            name: "size-decode",
            dependencies: [.product(name: "RasterWebP", package: "swift-raster-webp")]
        ),
    ]
)
