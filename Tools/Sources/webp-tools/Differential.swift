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

            // Half of the images are lossy, which exercises VP8 and the alpha chunk.
            let options =
                generator.next(upTo: 2) == 0
                ? ["-lossless"] + randomLosslessOptions(&generator) : randomLossyOptions(&generator)
            try requireTool("cwebp", ["-quiet"] + options + [source.path, "-o", encoded.path])
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

private func randomLosslessOptions(_ generator: inout SplitMix64) -> [String] {
    var options = ["-z", String(generator.next(upTo: 10))]
    if generator.next(upTo: 2) == 0 {
        options.append("-exact")
    }
    if generator.next(upTo: 4) == 0 {
        options += ["-near_lossless", String(generator.next(upTo: 100))]
    }
    return options
}

private func randomLossyOptions(_ generator: inout SplitMix64) -> [String] {
    var options = [
        "-q", String(generator.next(upTo: 101)),
        "-m", String(generator.next(upTo: 7)),
        "-sns", String(generator.next(upTo: 101)),
        "-f", String(generator.next(upTo: 101)),
        "-sharpness", String(generator.next(upTo: 8)),
        "-segments", String(1 + generator.next(upTo: 4)),
        generator.next(upTo: 2) == 0 ? "-strong" : "-nostrong",
    ]
    if generator.next(upTo: 4) == 0 {
        options += ["-pass", String(1 + generator.next(upTo: 10))]
    }
    if generator.next(upTo: 4) == 0 {
        options.append("-sharp_yuv")
    }
    if generator.next(upTo: 4) == 0 {
        options.append("-af")
    }

    // These only matter for translucent images, which the other options leave alone.
    options += ["-alpha_method", String(generator.next(upTo: 2))]
    options += ["-alpha_filter", ["none", "fast", "best"][generator.next(upTo: 3)]]
    options += ["-alpha_q", String(generator.next(upTo: 101))]
    if generator.next(upTo: 2) == 0 {
        options.append("-exact")
    }
    return options
}
