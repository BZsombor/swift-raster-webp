import Foundation
import RasterWebP

private let runCount = 7

/// Compares the single-threaded decoding speed of this package with `dwebp`.
func measureSpeed(files: [URL]) throws {
    let clock = ContinuousClock()

    for file in files {
        let bytes = [UInt8](try Data(contentsOf: file))
        let info = try WebPImageInfo(parsing: bytes)
        let megapixels = Double(info.width * info.height) / 1_000_000

        var bestTime = Double.infinity
        for _ in 0..<runCount {
            let start = clock.now
            let image = try WebPDecoder.decode(bytes)
            let elapsed = start.duration(to: clock.now).components
            precondition(!image.pixels.isEmpty)
            bestTime = min(bestTime, Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18)
        }

        var referenceTime = Double.infinity
        for _ in 0..<runCount {
            let result = try runTool("dwebp", ["-pam", "-v", file.path, "-o", "/dev/null"])
            for line in result.output.split(separator: "\n") where line.hasPrefix("Time to decode picture: ") {
                let value = line.dropFirst("Time to decode picture: ".count).dropLast()
                referenceTime = min(referenceTime, Double(value) ?? .infinity)
            }
        }

        let speed = megapixels / bestTime
        let referenceSpeed = megapixels / referenceTime
        let ratio = Int((speed / referenceSpeed * 100).rounded())
        print(
            "\(file.lastPathComponent): \(Int(speed.rounded())) Mpx/s, "
                + "dwebp \(Int(referenceSpeed.rounded())) Mpx/s, \(ratio)%"
        )
    }
}

/// Compares the single-threaded speed of decoding every frame of animations with libwebp's
/// `WebPAnimDecoder`.
func measureAnimationSpeed(files: [URL]) throws {
    let clock = ContinuousClock()

    try withTemporaryDirectory { work in
        let oracle = try buildAnimationOracle(in: work)
        for file in files {
            let bytes = [UInt8](try Data(contentsOf: file))
            var decoder = try WebPAnimationDecoder(bytes)
            let frameCount = decoder.frames.count
            let megapixels = Double(decoder.info.width * decoder.info.height * frameCount) / 1_000_000
            var output = [UInt8](repeating: 0, count: decoder.info.width * decoder.info.height * 4)

            var bestTime = Double.infinity
            for _ in 0..<runCount {
                let start = clock.now
                var decoded = 0
                try output.withUnsafeMutableBufferPointer { buffer in
                    var span = buffer.mutableSpan
                    while try decoder.nextFrame(into: &span, bytesPerRow: decoder.info.width * 4) != nil {
                        decoded += 1
                    }
                }
                let elapsed = start.duration(to: clock.now).components
                precondition(decoded == frameCount)
                bestTime = min(bestTime, Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18)
                decoder.reset()
            }

            let result = try runTool(oracle.path, ["-speed", String(runCount), file.path])
            guard result.succeeded,
                let milliseconds = Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                throw ToolFailure(description: "anim-oracle could not measure \(file.lastPathComponent)")
            }

            let speed = megapixels / bestTime
            let referenceSpeed = megapixels / (milliseconds / 1000)
            let ratio = Int((speed / referenceSpeed * 100).rounded())
            print(
                "\(file.lastPathComponent): \(frameCount) frames, \(Int(speed.rounded())) Mpx/s, "
                    + "WebPAnimDecoder \(Int(referenceSpeed.rounded())) Mpx/s, \(ratio)%"
            )
        }
    }
}
