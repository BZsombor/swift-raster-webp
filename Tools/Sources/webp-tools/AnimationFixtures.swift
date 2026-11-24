import Foundation

/// Compiles `Tools/Oracle/anim-oracle.c` against the installed libwebp and returns the program.
func buildAnimationOracle(in work: URL) throws -> URL {
    let flags = try runTool("pkg-config", ["--cflags", "--libs", "libwebpdemux"])
    guard flags.succeeded else {
        throw ToolFailure(description: "pkg-config cannot find libwebpdemux: \(flags.output)")
    }
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Oracle/anim-oracle.c")
    let program = work.appendingPathComponent("anim-oracle")
    let arguments = flags.output.split(whereSeparator: \.isWhitespace).map(String.init)
    try requireTool("clang", ["-O2", "-o", program.path, source.path] + arguments)
    return program
}

/// One frame as `WebPAnimDecoder` renders it.
struct OracleFrame {
    /// The time at which the frame ends, in milliseconds.
    let endTime: Int
    let hash: UInt64
}

/// Runs the oracle on a file and returns its frames.
func renderAnimation(_ file: URL, oracle: URL) throws -> [OracleFrame] {
    let result = try runTool(oracle.path, [file.path])
    guard result.succeeded else {
        throw ToolFailure(description: "anim-oracle rejected \(file.lastPathComponent)")
    }
    return try result.output.split(separator: "\n").map { line in
        let fields = line.split(separator: "\t")
        guard fields.count == 2, let endTime = Int(fields[0]), let hash = UInt64(fields[1], radix: 16) else {
            throw ToolFailure(description: "Unexpected oracle output: \(line)")
        }
        return OracleFrame(endTime: endTime, hash: hash)
    }
}

/// A frame of an animation that `webpmux` assembles.
private struct MuxFrame {
    let file: URL
    var duration = 100
    var x = 0
    var y = 0
    var disposeToBackground = false
    var blends = true

    var argument: String {
        "+\(duration)+\(x)+\(y)+\(disposeToBackground ? 1 : 0)\(blends ? "+b" : "-b")"
    }
}

/// Regenerates the animations that are embedded in the decoder tests.
func generateAnimationFixtures(in output: URL) throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var generator = SplitMix64(state: 0x414E_494D)

    func fixture(_ name: String) -> String {
        output.appendingPathComponent("\(name).webp").path
    }

    try withTemporaryDirectory { work in
        var frameIndex = 0
        func encode(_ image: TestImage, _ arguments: [String]) throws -> URL {
            frameIndex += 1
            let source = work.appendingPathComponent("frame\(frameIndex).pam")
            let encoded = work.appendingPathComponent("frame\(frameIndex).webp")
            try image.writePAM(to: source)
            try requireTool("cwebp", ["-quiet"] + arguments + [source.path, "-o", encoded.path])
            return encoded
        }
        func lossless(_ image: TestImage) throws -> URL {
            try encode(image, ["-lossless", "-exact"])
        }
        func lossy(_ image: TestImage, quality: Int = 70) throws -> URL {
            try encode(image, ["-q", String(quality)])
        }
        func mux(_ frames: [MuxFrame], _ name: String, extra: [String] = []) throws {
            let arguments = frames.flatMap { ["-frame", $0.file.path, $0.argument] }
            try requireTool("webpmux", arguments + extra + ["-o", fixture(name)])
        }
        func noise(_ width: Int, _ height: Int, translucent: Bool = true) -> TestImage {
            .noise(width: width, height: height, generator: &generator, translucent: translucent)
        }

        // Every combination of blending and disposal, over a translucent first frame.
        let base = try lossless(.gradient(width: 48, height: 40, translucent: true))
        var compose = [MuxFrame(file: base, blends: false)]
        for (index, (dispose, blend)) in [(false, true), (true, true), (false, false), (true, false)].enumerated() {
            let frame = try lossless(noise(20, 16))
            compose.append(
                MuxFrame(file: frame, x: 4 + index * 6, y: 2 + index * 6, disposeToBackground: dispose, blends: blend)
            )
        }
        compose.append(MuxFrame(file: try lossless(noise(48, 40)), duration: 50))
        try mux(compose, "anim_compose", extra: ["-loop", "0"])

        // Lossy frames with alpha, each with a different alpha compression and filter.
        let alphaOptions: [[String]] = [
            ["-alpha_method", "0"], ["-alpha_filter", "none"], ["-alpha_filter", "fast"],
            ["-alpha_filter", "best", "-alpha_q", "50"],
        ]
        var lossyFrames = [
            MuxFrame(file: try lossy(.mixed(width: 64, height: 48, generator: &generator)), blends: false)
        ]
        for (index, options) in alphaOptions.enumerated() {
            let image = TestImage.gradient(width: 32, height: 24, translucent: true)
            let frame = try encode(image, ["-q", "60"] + options)
            lossyFrames.append(MuxFrame(file: frame, x: index * 10, y: index * 8, disposeToBackground: index == 1))
        }
        try mux(lossyFrames, "anim_lossy_alpha")

        // Lossy and lossless frames of odd sizes, on the canvas edges, down to a single pixel.
        let edges = [
            MuxFrame(file: try lossy(.mixed(width: 33, height: 17, generator: &generator)), blends: false),
            MuxFrame(file: try lossless(noise(1, 1)), x: 32, y: 16),
            MuxFrame(file: try lossless(noise(33, 1)), y: 16, disposeToBackground: true),
            MuxFrame(file: try lossy(noise(13, 7, translucent: false), quality: 30), x: 20, y: 10, blends: false),
            MuxFrame(file: try lossless(noise(1, 17)), x: 0, disposeToBackground: true, blends: false),
            MuxFrame(file: try lossless(noise(7, 3)), x: 26, y: 14),
        ]
        try mux(edges, "anim_edges")

        // An opaque background color, which compositing must ignore, unusual durations and loops.
        let background = [
            MuxFrame(file: try lossless(noise(16, 16)), duration: 0, disposeToBackground: true),
            MuxFrame(file: try lossless(noise(16, 16)), duration: 16_777_215, x: 16, disposeToBackground: true),
            MuxFrame(file: try lossless(noise(16, 16)), duration: 1, x: 8, y: 8),
        ]
        try mux(background, "anim_background", extra: ["-bgcolor", "255,255,0,0", "-loop", "3"])

        // webpmux turns a single frame into a still image, so the first frame of a two-frame
        // animation is kept instead.
        let pair = work.appendingPathComponent("pair.webp")
        try requireTool(
            "webpmux",
            ["-frame", try lossless(noise(24, 18)).path, "+70+0+0+0+b", "-frame", base.path, "+70+0+0+0+b"]
                + ["-loop", "1", "-o", pair.path]
        )
        try keepingFirstFrame(of: pair).write(to: URL(fileURLWithPath: fixture("anim_single")))

        // An encoder-made animation, with keyframes, sub-rectangles and both compressions.
        var arguments = ["-loop", "0", "-mixed", "-kmin", "2", "-kmax", "4"]
        for step in 0..<8 {
            let image = TestImage(width: 64, height: 48) { x, y in
                let moving = (x - step * 6) * (x - step * 6) + (y - 24) * (y - 24) < 100
                let alpha: UInt8 = moving ? 255 : UInt8((x * 4) % 256)
                return (UInt8((x * 3 + step * 20) % 256), UInt8((y * 5) % 256), moving ? 40 : 200, alpha)
            }
            let source = work.appendingPathComponent("step\(step).pam")
            try image.writePAM(to: source)
            arguments += ["-d", String(40 + step * 10), source.path]
        }
        try requireTool("img2webp", arguments + ["-o", fixture("anim_encoder")])

        // Metadata around an animation. The generator checks that webpmux reads it back unchanged.
        let payloads = [
            ("icc", "raster-webp test ICC profile"), ("exif", "MM\0*\0\0\0\u{8}raster"),
            ("xmp", "<x:xmpmeta xmlns:x='adobe:ns:meta/'/>"),
        ]
        var current = fixture("anim_edges")
        for (index, (kind, text)) in payloads.enumerated() {
            let payload = work.appendingPathComponent("payload.\(kind)")
            try Data(text.utf8).write(to: payload)
            let next =
                index == payloads.count - 1
                ? fixture("anim_metadata") : work.appendingPathComponent("m\(index).webp").path
            try requireTool("webpmux", ["-set", kind, payload.path, current, "-o", next])
            current = next
        }
        for (kind, text) in payloads {
            let readBack = work.appendingPathComponent("read.\(kind)")
            try requireTool("webpmux", ["-get", kind, current, "-o", readBack.path])
            guard try Data(contentsOf: readBack) == Data(text.utf8) else {
                throw ToolFailure(description: "webpmux returned different \(kind) data")
            }
        }
    }
}

/// Returns an animation that keeps only the first `ANMF` chunk of the given one.
private func keepingFirstFrame(of file: URL) throws -> Data {
    let bytes = [UInt8](try Data(contentsOf: file))
    var body = Array("WEBP".utf8)
    var offset = 12
    var keptFrame = false
    while offset + 8 <= bytes.count {
        let size = (0..<4).reduce(0) { $0 | Int(bytes[offset + 4 + $1]) << ($1 * 8) }
        let end = offset + 8 + size + (size & 1)
        let fourCC = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
        if fourCC != "ANMF" || !keptFrame {
            body += bytes[offset..<end]
            keptFrame = keptFrame || fourCC == "ANMF"
        }
        offset = end
    }
    let size = UInt32(body.count)
    return Data(Array("RIFF".utf8) + (0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) } + body)
}

/// Records how `WebPAnimDecoder` renders every animation in a directory.
///
/// Each line holds: file, frame index, the time at which the frame ends, and the hash of the
/// straight RGBA canvas.
func generateAnimationGolden(fixtures: URL, output: URL) throws {
    let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("anim_") && $0.pathExtension == "webp" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var lines = ["# file\tframe\tend-ms\tcanvas-fnv1a64"]
    try withTemporaryDirectory { work in
        let oracle = try buildAnimationOracle(in: work)
        for file in files {
            for (index, frame) in try renderAnimation(file, oracle: oracle).enumerated() {
                lines.append("\(file.lastPathComponent)\t\(index)\t\(frame.endTime)\t\(String(frame.hash, radix: 16))")
            }
        }
    }
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: output)
    print("Recorded \(lines.count - 1) frames of \(files.count) animations in \(output.path)")
}
