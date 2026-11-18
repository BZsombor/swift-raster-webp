// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "raster-webp-benchmarks",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ContainerBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "RasterWebP", package: "swift-raster-webp"),
            ],
            path: "Benchmarks/ContainerBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        )
    ]
)
