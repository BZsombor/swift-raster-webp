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
        .library(name: "RasterWebP", targets: ["RasterWebP"]),
        .library(name: "RasterWebPDecoder", targets: ["RasterWebPDecoder"]),
    ],
    targets: [
        .target(
            name: "RasterWebP",
            dependencies: ["RasterWebPCore", "RasterWebPDecoder"],
            swiftSettings: librarySettings
        ),
        .target(
            name: "RasterWebPCore",
            swiftSettings: librarySettings
        ),
        .target(
            name: "RasterWebPDecoder",
            dependencies: ["RasterWebPCore"],
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
            name: "RasterWebPDecoderTests",
            dependencies: ["RasterWebP", "RasterWebPDecoder"],
            resources: [
                .embedInCode("Fixtures/extended.webp"),
                .embedInCode("Fixtures/gradient.webp"),
                .embedInCode("Fixtures/gradient_alpha.webp"),
                .embedInCode("Fixtures/mixed.webp"),
                .embedInCode("Fixtures/near_lossless.webp"),
                .embedInCode("Fixtures/noise.webp"),
                .embedInCode("Fixtures/palette_16.webp"),
                .embedInCode("Fixtures/palette_2.webp"),
                .embedInCode("Fixtures/palette_256.webp"),
                .embedInCode("Fixtures/palette_4.webp"),
                .embedInCode("Golden/fixtures.tsv"),
            ]
        ),
        .testTarget(
            name: "ConformanceTests",
            dependencies: ["RasterWebP", "RasterWebPCore", "RasterWebPDecoder"],
            resources: [
                .embedInCode("Golden/libwebp-test-data.tsv")
            ]
        ),
    ]
)
