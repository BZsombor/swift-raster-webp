import Benchmark
import Foundation
import RasterWebP

private func fixture(_ name: String) -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/RasterWebPCoreTests/Fixtures/\(name).webp")
    guard let data = try? Data(contentsOf: url) else {
        fatalError("Missing fixture \(name)")
    }
    return [UInt8](data)
}

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .instructions, .throughput],
        maxDuration: .seconds(1),
        maxIterations: 1_000_000
    )

    for name in ["lossy", "lossless", "metadata", "animated_mixed"] {
        let bytes = fixture(name)
        Benchmark("WebPImageInfo.parsing/\(name)") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(try WebPImageInfo(parsing: bytes))
            }
        }
    }
}
