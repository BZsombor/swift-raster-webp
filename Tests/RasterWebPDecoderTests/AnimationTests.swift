import RasterWebP
import Testing

/// Animations produced by libwebp, generated with `webp-tools animation-fixtures`.
private let animations: [(name: String, bytes: [UInt8])] = [
    ("anim_background.webp", PackageResources.anim_background_webp),
    ("anim_compose.webp", PackageResources.anim_compose_webp),
    ("anim_edges.webp", PackageResources.anim_edges_webp),
    ("anim_encoder.webp", PackageResources.anim_encoder_webp),
    ("anim_lossy_alpha.webp", PackageResources.anim_lossy_alpha_webp),
    ("anim_metadata.webp", PackageResources.anim_metadata_webp),
    ("anim_single.webp", PackageResources.anim_single_webp),
]

/// One frame as libwebp's `WebPAnimDecoder` renders it.
private struct GoldenFrame {
    let endTime: Int
    let hash: UInt64
}

/// The frames of every animation, generated with `webp-tools animation-golden`.
private let goldenFrames: [String: [GoldenFrame]] = {
    var frames: [String: [GoldenFrame]] = [:]
    for line in String(decoding: PackageResources.animations_tsv, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(separator: "\t").map(String.init)
        guard fields.count == 4, !fields[0].hasPrefix("#"), let endTime = Int(fields[2]),
            let hash = UInt64(fields[3], radix: 16)
        else {
            continue
        }
        frames[fields[0], default: []].append(GoldenFrame(endTime: endTime, hash: hash))
    }
    return frames
}()

/// Decodes every frame of an animation.
private func decodeAll(_ bytes: [UInt8], options: WebPDecodingOptions = WebPDecodingOptions()) throws
    -> [WebPAnimationFrame]
{
    var decoder = try WebPAnimationDecoder(bytes, options: options)
    var frames: [WebPAnimationFrame] = []
    while let frame = try decoder.nextFrame() {
        frames.append(frame)
    }
    return frames
}

/// Converts straight RGBA pixels into another format, as an independent reference.
private func convert(_ rgba: [UInt8], to format: WebPPixelFormat, premultiplied: Bool) -> [UInt8] {
    var output: [UInt8] = []
    for start in stride(from: 0, to: rgba.count, by: 4) {
        let alpha = Int(rgba[start + 3])
        var color = (0..<3).map { Int(rgba[start + $0]) }
        if premultiplied {
            color = color.map { ($0 * alpha + 127) / 255 }
        }
        switch format {
        case .rgba8: output += color.map(UInt8.init) + [UInt8(alpha)]
        case .bgra8: output += color.reversed().map(UInt8.init) + [UInt8(alpha)]
        case .rgb8: output += color.map(UInt8.init)
        default: output += color.reversed().map(UInt8.init)
        }
    }
    return output
}

@Suite("Animation")
struct AnimationTests {
    @Test func everyFrameMatchesLibwebp() throws {
        #expect(goldenFrames.count == animations.count)

        for animation in animations {
            let expected = try #require(goldenFrames[animation.name])
            let frames = try decodeAll(animation.bytes)

            #expect(frames.count == expected.count, "\(animation.name)")
            for (frame, golden) in zip(frames, expected) {
                #expect(fnv1a(frame.image.pixels) == golden.hash, "\(animation.name) frame \(frame.index)")
                #expect(frame.timestamp + frame.duration == golden.endTime, "\(animation.name) frame \(frame.index)")
            }
        }
    }

    @Test func framesDescribeTheFile() throws {
        let decoder = try WebPAnimationDecoder(PackageResources.anim_compose_webp)
        let frames = decoder.frames

        #expect(frames.count == decoder.info.animation?.frameCount)
        #expect(frames[0] == frames[0])
        #expect(frames[0].blending == .overwrite)
        #expect(frames[1].blending == .alphaBlend && frames[1].disposal == .none)
        #expect(frames[2].disposal == .background)
        #expect(frames[1].x == 4 && frames[1].y == 2 && frames[1].width == 20 && frames[1].height == 16)
        #expect(frames.last?.duration == 50)
        #expect(frames.allSatisfy { $0.compression == .lossless })
    }

    @Test func everyFormatAndAlphaModeHoldsTheSameCanvas() throws {
        let bytes = PackageResources.anim_lossy_alpha_webp
        let straight = try decodeAll(bytes)

        for format in [WebPPixelFormat.rgba8, .bgra8, .rgb8, .bgr8] {
            for alphaMode in [WebPAlphaMode.straight, .premultiplied] {
                let options = WebPDecodingOptions(pixelFormat: format, alphaMode: alphaMode)
                let frames = try decodeAll(bytes, options: options)
                #expect(frames.count == straight.count)
                for (frame, reference) in zip(frames, straight) {
                    let expected = convert(
                        reference.image.pixels,
                        to: format,
                        premultiplied: alphaMode == .premultiplied
                    )
                    #expect(frame.image.pixels == expected, "\(format) \(alphaMode) frame \(frame.index)")
                    #expect(frame.image.bytesPerRow == frame.image.width * format.bytesPerPixel)
                }
            }
        }
    }

    @Test func decodingIntoCallerMemoryMatches() throws {
        let bytes = PackageResources.anim_compose_webp
        let reference = try decodeAll(bytes)
        let width = reference[0].image.width
        let height = reference[0].image.height

        // A tightly packed four-byte buffer, and a padded three-byte one.
        for (format, padding) in [(WebPPixelFormat.bgra8, 0), (.rgb8, 5)] {
            let options = WebPDecodingOptions(pixelFormat: format, alphaMode: .premultiplied)
            let bytesPerRow = width * format.bytesPerPixel + padding
            var decoder = try WebPAnimationDecoder(bytes, options: options)
            var output = [UInt8](repeating: 0xAA, count: bytesPerRow * height)

            for frame in reference {
                let timing = try output.withUnsafeMutableBufferPointer { buffer in
                    var span = buffer.mutableSpan
                    return try decoder.nextFrame(into: &span, bytesPerRow: bytesPerRow)
                }
                #expect(timing?.index == frame.index)
                #expect(timing?.timestamp == frame.timestamp)
                #expect(timing?.duration == frame.duration)

                let expected = convert(frame.image.pixels, to: format, premultiplied: true)
                let rowSize = width * format.bytesPerPixel
                for row in 0..<height {
                    let written = output[(row * bytesPerRow)..<(row * bytesPerRow + rowSize)]
                    #expect(Array(written) == Array(expected[(row * rowSize)..<((row + 1) * rowSize)]))
                    #expect(
                        output[(row * bytesPerRow + rowSize)..<(row * bytesPerRow + bytesPerRow)].allSatisfy {
                            $0 == 0xAA
                        }
                    )
                }
            }
            let end = try output.withUnsafeMutableBufferPointer { buffer in
                var span = buffer.mutableSpan
                return try decoder.nextFrame(into: &span, bytesPerRow: bytesPerRow)
            }
            #expect(end == nil)
        }
    }

    @Test func resetPlaysTheAnimationAgain() throws {
        var decoder = try WebPAnimationDecoder(PackageResources.anim_encoder_webp)
        var first: [WebPAnimationFrame] = []
        while let frame = try decoder.nextFrame() {
            first.append(frame)
        }
        #expect(try decoder.nextFrame() == nil)

        decoder.reset()
        var second: [WebPAnimationFrame] = []
        while let frame = try decoder.nextFrame() {
            second.append(frame)
        }
        #expect(first == second)
    }

    @Test func stillDecoderReturnsTheFirstFrame() throws {
        for animation in animations {
            let first = try #require(try decodeAll(animation.bytes).first)
            #expect(try WebPDecoder.decode(animation.bytes) == first.image, "\(animation.name)")
        }
    }

    @Test func stillImageIsAnAnimationOfOneFrame() throws {
        for fixture in Fixtures.all {
            var decoder = try WebPAnimationDecoder(fixture.bytes)
            let frame = try #require(try decoder.nextFrame())

            #expect(frame.image == (try WebPDecoder.decode(fixture.bytes)), "\(fixture.name)")
            #expect(frame.index == 0 && frame.timestamp == 0 && frame.duration == 0)
            #expect(try decoder.nextFrame() == nil)
            #expect(decoder.frames == [decoder.frames[0]])
            #expect(decoder.frames[0].width == frame.image.width)
        }
    }

    @Test func unknownChunksInFramesAreIgnored() throws {
        let bytes = PackageResources.anim_compose_webp
        let reference = try decodeAll(bytes)
        let extended = insertingUnknownChunkIntoFrames(bytes)

        #expect(extended.count > bytes.count)
        #expect(try decodeAll(extended) == reference)
    }

    @Test func damagedFrameStopsTheAnimationUntilReset() throws {
        let bytes = PackageResources.anim_compose_webp
        let reference = try decodeAll(bytes)

        // Clearing the bitstream of the last frame, after its VP8L header, makes it invalid.
        var damaged = bytes
        let lastFrame = try #require(chunkOffsets(in: bytes).last { $0.fourCC == "ANMF" })
        for index in (lastFrame.payload.lowerBound + 16 + 8 + 5)..<lastFrame.payload.upperBound {
            damaged[index] = 0xFF
        }

        var decoder = try WebPAnimationDecoder(damaged)
        for frame in reference.dropLast() {
            #expect(try decoder.nextFrame() == frame)
        }
        let first = #expect(throws: WebPError.self) { try decoder.nextFrame() }
        let second = #expect(throws: WebPError.self) { try decoder.nextFrame() }
        #expect(first == second)

        decoder.reset()
        #expect(try decoder.nextFrame() == reference[0])
    }

    @Test func limitsApplyBeforeDecoding() throws {
        let bytes = PackageResources.anim_compose_webp

        var options = WebPDecodingOptions()
        options.limits.maximumFrameCount = 5
        let frameError = #expect(throws: WebPError.self) { try WebPAnimationDecoder(bytes, options: options) }
        #expect(frameError?.kind == .limitExceeded)

        options = WebPDecodingOptions()
        options.limits.maximumAnimationPixelCount = 48 * 40 * 2
        let pixelError = #expect(throws: WebPError.self) { try WebPAnimationDecoder(bytes, options: options) }
        #expect(pixelError?.kind == .limitExceeded)

        options = WebPDecodingOptions()
        options.limits.maximumPixelCount = 48 * 40 - 1
        let canvasError = #expect(throws: WebPError.self) { try WebPAnimationDecoder(bytes, options: options) }
        #expect(canvasError?.kind == .limitExceeded)

        // The canvas fits, but not the canvas together with the frame being decoded.
        options = WebPDecodingOptions()
        options.limits.maximumMemoryByteCount = 48 * 40 * 4 + 100
        var decoder = try WebPAnimationDecoder(bytes, options: options)
        let memoryError = #expect(throws: WebPError.self) {
            while try decoder.nextFrame() != nil {}
        }
        #expect(memoryError?.kind == .limitExceeded)
    }

    @Test func everyTruncationIsReported() {
        for animation in animations where animation.bytes.count < 4_000 {
            for length in 0..<animation.bytes.count {
                #expect(throws: WebPError.self, "\(animation.name) cut at \(length)") {
                    try WebPAnimationDecoder(Array(animation.bytes[..<length]))
                }
            }
        }
    }

    @Test func damagedAnimationsAreHandled() {
        var options = WebPDecodingOptions()
        options.limits.maximumPixelCount = 1 << 13
        options.limits.maximumMemoryByteCount = 1 << 24
        options.limits.maximumAnimationPixelCount = 1 << 16

        func decodeAndCheck(_ bytes: [UInt8]) {
            guard var decoder = try? WebPAnimationDecoder(bytes, options: options) else {
                return
            }
            let frameCount = decoder.frames.count
            var index = 0
            while let frame = try? decoder.nextFrame() {
                #expect(frame.index == index && index < frameCount)
                #expect(frame.image.pixels.count == decoder.info.width * decoder.info.height * 4)
                index += 1
            }
        }

        // Every bit of the headers, and one bit of every later byte.
        for animation in animations where animation.bytes.count < 1_100 {
            var bytes = animation.bytes
            for index in bytes.indices {
                for bit in 0..<8 where index < 64 || bit == index % 8 {
                    bytes[index] ^= 1 << UInt8(bit)
                    decodeAndCheck(bytes)
                    bytes[index] ^= 1 << UInt8(bit)
                }
            }
        }

        var generator = SplitMix64(state: 0x414E_494D)
        for animation in animations {
            for _ in 0..<60 {
                var bytes = animation.bytes
                for _ in 0..<(1 + generator.next(below: 12)) {
                    bytes[generator.next(below: bytes.count)] = UInt8(truncatingIfNeeded: generator.next())
                }
                decodeAndCheck(bytes)
            }
        }
    }

    @Test func metadataOfAnAnimation() throws {
        let metadata = try WebPMetadata(parsing: PackageResources.anim_metadata_webp)

        #expect(metadata.iccProfile == Array("raster-webp test ICC profile".utf8))
        #expect(metadata.exif == Array("MM\0*\0\0\0\u{8}raster".utf8))
        #expect(metadata.xmp == Array("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>".utf8))
        #expect(try WebPMetadata(parsing: PackageResources.anim_compose_webp) == WebPMetadata.none)
    }
}

extension WebPMetadata {
    fileprivate static var none: WebPMetadata {
        get throws { try WebPMetadata(parsing: PackageResources.gradient_webp) }
    }
}

/// A top-level chunk of a file.
private struct ChunkLocation {
    let fourCC: String
    let header: Int
    let payload: Range<Int>
}

private func chunkOffsets(in bytes: [UInt8]) -> [ChunkLocation] {
    var chunks: [ChunkLocation] = []
    var offset = 12
    while offset + 8 <= bytes.count {
        let size = (0..<4).reduce(0) { $0 | Int(bytes[offset + 4 + $1]) << ($1 * 8) }
        let fourCC = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
        chunks.append(ChunkLocation(fourCC: fourCC, header: offset, payload: (offset + 8)..<(offset + 8 + size)))
        offset += 8 + size + (size & 1)
    }
    return chunks
}

private func littleEndian(_ value: Int) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

/// Appends an unknown chunk to the end of every `ANMF` chunk, which readers must ignore.
private func insertingUnknownChunkIntoFrames(_ bytes: [UInt8]) -> [UInt8] {
    let unknown = Array("ABCD".utf8) + littleEndian(3) + [1, 2, 3, 0]
    var body = Array("WEBP".utf8)
    for chunk in chunkOffsets(in: bytes) {
        let padded = chunk.payload.count + (chunk.payload.count & 1)
        let payload = Array(bytes[chunk.payload.lowerBound..<(chunk.payload.lowerBound + padded)])
        if chunk.fourCC == "ANMF" {
            body += Array("ANMF".utf8) + littleEndian(padded + unknown.count) + payload + unknown
        } else {
            body += Array(bytes[chunk.header..<chunk.payload.lowerBound]) + payload
        }
    }
    return Array("RIFF".utf8) + littleEndian(body.count) + body
}
