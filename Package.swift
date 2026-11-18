// swift-tools-version: 6.3

import PackageDescription

let librarySettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "swift-raster-webp",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "RasterWebP", targets: ["RasterWebP"])
    ],
    targets: [
        .target(
            name: "RasterWebP",
            dependencies: ["RasterWebPCore"],
            swiftSettings: librarySettings
        ),
        .target(
            name: "RasterWebPCore",
            swiftSettings: librarySettings
        ),
        .testTarget(
            name: "RasterWebPCoreTests",
            dependencies: ["RasterWebP"],
            resources: [
                .embedInCode("Fixtures/animated_mixed.webp"),
                .embedInCode("Fixtures/lossless.webp"),
                .embedInCode("Fixtures/lossless_alpha.webp"),
                .embedInCode("Fixtures/lossy.webp"),
                .embedInCode("Fixtures/lossy_alpha.webp"),
                .embedInCode("Fixtures/metadata.webp"),
            ]
        ),
        .testTarget(
            name: "ConformanceTests",
            dependencies: ["RasterWebP"],
            resources: [
                .embedInCode("Golden/libwebp-test-data.tsv")
            ]
        ),
    ]
)
