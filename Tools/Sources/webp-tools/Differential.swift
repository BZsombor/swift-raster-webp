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

/// Builds random animations with libwebp's tools and compares every frame with `WebPAnimDecoder`.
func runAnimationDifferentialTest(iterations: Int, seed: UInt64) throws {
    var generator = SplitMix64(state: seed)
    var mismatchCount = 0
    var frameCount = 0

    try withTemporaryDirectory { work in
        let oracle = try buildAnimationOracle(in: work)
        let animation = work.appendingPathComponent("animation.webp")

        for iteration in 0..<iterations {
            let arguments =
                generator.next(upTo: 4) == 0
                ? try randomEncodedAnimation(&generator, in: work)
                : try randomMuxedAnimation(&generator, in: work)
            try requireTool(arguments[0], Array(arguments.dropFirst()) + ["-o", animation.path])

            let expected = try renderAnimation(animation, oracle: oracle)
            var decoder = try WebPAnimationDecoder([UInt8](try Data(contentsOf: animation)))
            var frames: [OracleFrame] = []
            while let frame = try decoder.nextFrame() {
                let hash = frame.image.pixels.withUnsafeBytes(fnv1a)
                frames.append(OracleFrame(endTime: frame.timestamp + frame.duration, hash: hash))
            }
            frameCount += expected.count

            let agrees =
                frames.count == expected.count
                && zip(frames, expected).allSatisfy { $0.hash == $1.hash && $0.endTime == $1.endTime }
            if !agrees {
                mismatchCount += 1
                print("mismatch at iteration \(iteration): \(arguments.joined(separator: " "))")
            }
        }
    }

    print("Compared \(iterations) animations with \(frameCount) frames, found \(mismatchCount) mismatches")
    if mismatchCount > 0 {
        throw ToolFailure(description: "The animation decoder disagrees with WebPAnimDecoder")
    }
}

/// Returns the `webpmux` command for random frames, placements, blending and disposal.
private func randomMuxedAnimation(_ generator: inout SplitMix64, in work: URL) throws -> [String] {
    let canvasWidth = 1 + generator.next(upTo: generator.next(upTo: 4) == 0 ? 300 : 48)
    let canvasHeight = 1 + generator.next(upTo: generator.next(upTo: 4) == 0 ? 300 : 48)
    var arguments = ["webpmux"]

    for index in 0..<(2 + generator.next(upTo: 7)) {
        // Every frame covers the whole canvas now and then, which exercises the direct path.
        let isFull = generator.next(upTo: 4) == 0
        let width = isFull ? canvasWidth : 1 + generator.next(upTo: canvasWidth)
        let height = isFull ? canvasHeight : 1 + generator.next(upTo: canvasHeight)
        let x = isFull ? 0 : generator.next(upTo: (canvasWidth - width) / 2 + 1) * 2
        let y = isFull ? 0 : generator.next(upTo: (canvasHeight - height) / 2 + 1) * 2

        let source = work.appendingPathComponent("frame\(index).pam")
        let frame = work.appendingPathComponent("frame\(index).webp")
        try randomFrameImage(width: width, height: height, &generator).writePAM(to: source)
        let options =
            generator.next(upTo: 2) == 0
            ? ["-lossless", "-exact", "-z", String(generator.next(upTo: 10))]
            : [
                "-q", String(generator.next(upTo: 101)), "-alpha_filter",
                ["none", "fast", "best"][generator.next(upTo: 3)],
            ]
        try requireTool("cwebp", ["-quiet"] + options + [source.path, "-o", frame.path])

        let dispose = generator.next(upTo: 3) == 0 ? 1 : 0
        let blend = generator.next(upTo: 3) == 0 ? "-b" : "+b"
        arguments += ["-frame", frame.path, "+\(generator.next(upTo: 200))+\(x)+\(y)+\(dispose)\(blend)"]
    }
    return arguments + ["-loop", String(generator.next(upTo: 4))]
}

/// Returns the `img2webp` command for a random sequence that the encoder optimizes itself.
private func randomEncodedAnimation(_ generator: inout SplitMix64, in work: URL) throws -> [String] {
    let width = 1 + generator.next(upTo: 96)
    let height = 1 + generator.next(upTo: 96)
    var arguments = ["img2webp", "-loop", "0", ["-lossy", "-lossless", "-mixed"][generator.next(upTo: 3)]]
    if generator.next(upTo: 2) == 0 {
        let maximum = 1 + generator.next(upTo: 8)
        arguments += ["-kmin", String(generator.next(upTo: maximum)), "-kmax", String(maximum)]
    }

    var image = randomFrameImage(width: width, height: height, &generator)
    for index in 0..<(2 + generator.next(upTo: 7)) {
        // Consecutive frames share most pixels, so the encoder uses sub-rectangles and blending.
        for _ in 0..<(1 + generator.next(upTo: 40)) {
            let pixel = generator.next(upTo: width * height) * 4
            for channel in 0..<4 {
                image.pixels[pixel + channel] = generator.byte()
            }
        }
        let source = work.appendingPathComponent("step\(index).pam")
        try image.writePAM(to: source)
        arguments += [
            "-d", String(1 + generator.next(upTo: 200)), "-q", String(generator.next(upTo: 101)), source.path,
        ]
    }
    return arguments
}

private func randomFrameImage(width: Int, height: Int, _ generator: inout SplitMix64) -> TestImage {
    switch generator.next(upTo: 3) {
    case 0:
        return .gradient(width: width, height: height, translucent: generator.next(upTo: 2) == 0)
    case 1:
        return .noise(width: width, height: height, generator: &generator, translucent: true)
    default:
        return .palette(width: width, height: height, colorCount: 1 + generator.next(upTo: 8), generator: &generator)
    }
}
