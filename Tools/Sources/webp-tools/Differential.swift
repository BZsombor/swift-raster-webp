import Foundation
import RasterWebP

/// Encodes random images with `cwebp` and compares this package's output with `dwebp`.
func runDifferentialTest(iterations: Int, seed: UInt64) throws {
    var generator = SplitMix64(state: seed)
    var mismatchCount = 0

    try withTemporaryDirectory { work in
        let source = work.appendingPathComponent("source.pam")
        let encoded = work.appendingPathComponent("encoded.webp")
        let decoded = work.appendingPathComponent("decoded.pam")

        for iteration in 0..<iterations {
            let image = randomImage(&generator)
            try image.writePAM(to: source)

            let options = randomEncoderOptions(&generator)
            try requireTool("cwebp", ["-quiet", "-lossless"] + options + [source.path, "-o", encoded.path])
            try requireTool("dwebp", ["-quiet", "-pam", encoded.path, "-o", decoded.path])

            let bytes = [UInt8](try Data(contentsOf: encoded))
            let result = try WebPDecoder.decode(bytes)
            let hash = result.pixels.withUnsafeBytes(fnv1a)

            if hash != (try pixelHash(ofPAM: decoded)) {
                mismatchCount += 1
                print("mismatch at iteration \(iteration): \(image.width)x\(image.height) \(options)")
            }
        }
    }

    print("Compared \(iterations) images, found \(mismatchCount) mismatches")
    if mismatchCount > 0 {
        throw ToolFailure(description: "The decoder disagrees with dwebp")
    }
}

private func randomImage(_ generator: inout SplitMix64) -> TestImage {
    let width = 1 + generator.next(upTo: generator.next(upTo: 4) == 0 ? 600 : 64)
    let height = 1 + generator.next(upTo: generator.next(upTo: 4) == 0 ? 600 : 64)

    switch generator.next(upTo: 5) {
    case 0:
        return .gradient(width: width, height: height, translucent: generator.next(upTo: 2) == 0)
    case 1:
        return .noise(width: width, height: height, generator: &generator, translucent: generator.next(upTo: 2) == 0)
    case 2:
        let colorCount = 1 + generator.next(upTo: 256)
        return .palette(width: width, height: height, colorCount: colorCount, generator: &generator)
    case 3:
        let colorCount = 1 + generator.next(upTo: 16)
        return .palette(width: width, height: height, colorCount: colorCount, generator: &generator)
    default:
        return .mixed(width: width, height: height, generator: &generator)
    }
}

private func randomEncoderOptions(_ generator: inout SplitMix64) -> [String] {
    var options = ["-z", String(generator.next(upTo: 10))]
    if generator.next(upTo: 2) == 0 {
        options.append("-exact")
    }
    if generator.next(upTo: 4) == 0 {
        options += ["-near_lossless", String(generator.next(upTo: 100))]
    }
    return options
}
