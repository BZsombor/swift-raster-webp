import RasterWebP
import Testing

private struct GoldenEntry {
    let width: Int
    let height: Int
    let pixelHash: UInt64
}

/// What libwebp reports for each fixture, generated with `webp-tools golden`.
private let golden: [String: GoldenEntry] = {
    var entries: [String: GoldenEntry] = [:]
    for line in String(decoding: PackageResources.fixtures_tsv, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(separator: "\t").map(String.init)
        guard fields.count == 8, fields[1] == "ok" else {
            continue
        }
        let name = String(fields[0].dropLast(".webp".count))
        entries[name] = GoldenEntry(
            width: Int(fields[2]) ?? 0,
            height: Int(fields[3]) ?? 0,
            pixelHash: UInt64(fields[7], radix: 16) ?? 0
        )
    }
    return entries
}()

@Suite("Decoding")
struct WebPDecoderTests {
    @Test func everyFixtureMatchesLibwebp() throws {
        #expect(golden.count == Fixtures.all.count)

        for fixture in Fixtures.all {
            let entry = try #require(golden[fixture.name])
            let image = try WebPDecoder.decode(fixture.bytes)

            #expect(image.width == entry.width, "\(fixture.name)")
            #expect(image.height == entry.height, "\(fixture.name)")
            #expect(image.bytesPerRow == entry.width * 4, "\(fixture.name)")
            #expect(fnv1a(image.pixels) == entry.pixelHash, "\(fixture.name)")
        }
    }

    @Test func spanAndArrayInputsAgree() throws {
        let bytes = PackageResources.gradient_alpha_webp
        let fromArray = try WebPDecoder.decode(bytes)
        let fromSpan = try bytes.withUnsafeBufferPointer { try WebPDecoder.decode($0.span) }

        #expect(fromArray == fromSpan)
    }

    @Test func everyPixelFormatHoldsTheSameColors() throws {
        let bytes = PackageResources.gradient_alpha_webp
        let rgba = try WebPDecoder.decode(bytes).pixels

        func decoded(_ format: WebPPixelFormat) throws -> WebPImage {
            try WebPDecoder.decode(bytes, options: WebPDecodingOptions(pixelFormat: format))
        }

        let bgra = try decoded(.bgra8)
        let rgb = try decoded(.rgb8)
        let bgr = try decoded(.bgr8)

        #expect(bgra.bytesPerRow == bgra.width * 4)
        #expect(rgb.bytesPerRow == rgb.width * 3)
        #expect(rgb.pixels.count == rgb.width * rgb.height * 3)
        #expect(bgr.pixels.count == bgr.width * bgr.height * 3)

        for pixel in 0..<(rgba.count / 4) {
            let (r, g, b, a) = (rgba[pixel * 4], rgba[pixel * 4 + 1], rgba[pixel * 4 + 2], rgba[pixel * 4 + 3])
            #expect(Array(bgra.pixels[(pixel * 4)..<(pixel * 4 + 4)]) == [b, g, r, a])
            #expect(Array(rgb.pixels[(pixel * 3)..<(pixel * 3 + 3)]) == [r, g, b])
            #expect(Array(bgr.pixels[(pixel * 3)..<(pixel * 3 + 3)]) == [b, g, r])
        }
    }

    @Test func premultipliedAlphaScalesColors() throws {
        let bytes = PackageResources.gradient_alpha_webp
        let straight = try WebPDecoder.decode(bytes).pixels
        let options = WebPDecodingOptions(alphaMode: .premultiplied)
        let image = try WebPDecoder.decode(bytes, options: options)

        #expect(image.alphaMode == .premultiplied)
        for pixel in 0..<(straight.count / 4) {
            let alpha = Int(straight[pixel * 4 + 3])
            #expect(image.pixels[pixel * 4 + 3] == straight[pixel * 4 + 3])
            for channel in 0..<3 {
                let expected = (Int(straight[pixel * 4 + channel]) * alpha * 2 + 255) / 510
                #expect(Int(image.pixels[pixel * 4 + channel]) == expected)
            }
        }
    }

    @Test(arguments: [WebPPixelFormat.rgba8, .bgra8, .rgb8, .bgr8])
    func decodingIntoCallerMemoryMatchesTheImage(format: WebPPixelFormat) throws {
        let bytes = PackageResources.mixed_webp
        let options = WebPDecodingOptions(pixelFormat: format)
        let expected = try WebPDecoder.decode(bytes, options: options)
        let rowSize = expected.bytesPerRow

        // Exercise tight rows, padded rows and memory that is not aligned for four-byte access.
        for (padding, offset) in [(0, 0), (7, 0), (0, 1), (5, 3)] {
            let bytesPerRow = rowSize + padding
            let byteCount = offset + bytesPerRow * expected.height
            var output = [UInt8](repeating: 0xAB, count: byteCount)

            let info = try bytes.withUnsafeBufferPointer { input in
                try output.withUnsafeMutableBufferPointer { buffer in
                    let target = UnsafeMutableBufferPointer(rebasing: buffer[offset...])
                    return try WebPDecoder.decode(
                        input.span,
                        into: target.mutableSpan,
                        bytesPerRow: bytesPerRow,
                        options: options
                    )
                }
            }

            #expect(info.width == expected.width)
            for row in 0..<expected.height {
                let start = offset + row * bytesPerRow
                let actualRow = Array(output[start..<(start + rowSize)])
                let expectedRow = Array(expected.pixels[(row * rowSize)..<((row + 1) * rowSize)])
                #expect(actualRow == expectedRow)
                if row < expected.height - 1, padding > 0 {
                    #expect(output[start + rowSize] == 0xAB)
                }
            }
        }
    }

    private func decodeIntoBuffer(byteCount: Int, bytesPerRow: Int) throws(WebPError) {
        var output = [UInt8](repeating: 0, count: byteCount)
        var failure: WebPError?
        PackageResources.gradient_webp.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { buffer in
                do throws(WebPError) {
                    try WebPDecoder.decode(input.span, into: buffer.mutableSpan, bytesPerRow: bytesPerRow)
                } catch {
                    failure = error
                }
            }
        }
        if let failure {
            throw failure
        }
    }

    @Test func outputBufferIsValidated() throws {
        let rowSize = 64 * 4

        #expect(throws: WebPError.self) { try decodeIntoBuffer(byteCount: rowSize * 48, bytesPerRow: rowSize - 1) }
        #expect(throws: WebPError.self) { try decodeIntoBuffer(byteCount: rowSize * 48 - 1, bytesPerRow: rowSize) }
        try decodeIntoBuffer(byteCount: rowSize * 48, bytesPerRow: rowSize)

        // The last row does not need trailing padding.
        try decodeIntoBuffer(byteCount: (rowSize + 9) * 47 + rowSize, bytesPerRow: rowSize + 9)
    }

    @Test func pixelLimitIsEnforced() {
        var options = WebPDecodingOptions()
        options.limits.maximumPixelCount = 64 * 48 - 1

        do {
            _ = try WebPDecoder.decode(PackageResources.gradient_webp, options: options)
            Issue.record("Expected a failure")
        } catch {
            #expect(error.kind == .limitExceeded)
        }
    }

    @Test func memoryLimitIsEnforced() {
        var options = WebPDecodingOptions()
        options.limits.maximumMemoryByteCount = 64 * 48 * 4

        do {
            _ = try WebPDecoder.decode(PackageResources.mixed_webp, options: options)
            Issue.record("Expected a failure")
        } catch {
            #expect(error.kind == .limitExceeded)
        }
    }

    @Test func lossyImagesAreReportedAsUnsupported() {
        let payload: [UInt8] = [0x30, 0x00, 0x00, 0x9D, 0x01, 0x2A, 0x01, 0x00, 0x01, 0x00]
        let file =
            Array("RIFF".utf8) + [22, 0, 0, 0] + Array("WEBPVP8 ".utf8) + [10, 0, 0, 0] + payload

        do {
            _ = try WebPDecoder.decode(file)
            Issue.record("Expected a failure")
        } catch {
            #expect(error.kind == .unsupportedFeature)
        }
    }
}

@Suite("Decoder robustness")
struct DecoderRobustnessTests {
    /// Keeps damaged headers from requesting very large images during the tests.
    private static let options: WebPDecodingOptions = {
        var options = WebPDecodingOptions()
        options.limits.maximumPixelCount = 1 << 18
        options.limits.maximumMemoryByteCount = 1 << 24
        return options
    }()

    private func decodeAndCheck(_ bytes: [UInt8]) {
        guard let image = try? WebPDecoder.decode(bytes, options: Self.options) else {
            return
        }
        #expect(image.pixels.count == image.width * image.height * 4)
    }

    @Test func everyTruncationIsReported() {
        for fixture in Fixtures.all where fixture.bytes.count < 4_000 {
            for length in 0..<fixture.bytes.count {
                #expect(throws: WebPError.self, "\(fixture.name) cut at \(length)") {
                    try WebPDecoder.decode(Array(fixture.bytes[..<length]), options: Self.options)
                }
            }
        }
    }

    @Test func everySingleBitFlipIsHandled() {
        for fixture in Fixtures.all where fixture.bytes.count < 1_000 {
            var bytes = fixture.bytes
            for index in bytes.indices {
                for bit in 0..<8 {
                    bytes[index] ^= 1 << UInt8(bit)
                    decodeAndCheck(bytes)
                    bytes[index] ^= 1 << UInt8(bit)
                }
            }
        }
    }

    @Test func randomMutationsAreHandled() {
        var generator = SplitMix64(state: 0x4D55_5441)
        for fixture in Fixtures.all {
            for _ in 0..<400 {
                var bytes = fixture.bytes
                for _ in 0..<(1 + generator.next(below: 12)) {
                    let index = generator.next(below: bytes.count)
                    bytes[index] = UInt8(truncatingIfNeeded: generator.next())
                }
                decodeAndCheck(bytes)
            }
        }
    }

    @Test func randomBitstreamsAreHandled() {
        var generator = SplitMix64(state: 0x4E4F_4953)
        for _ in 0..<3_000 {
            let width = 1 + generator.next(below: 64)
            let height = 1 + generator.next(below: 64)
            let byteCount = generator.next(below: 512)
            let file = VP8LFile.make(width: width, height: height) { writer in
                for _ in 0..<byteCount {
                    writer.write(UInt32(truncatingIfNeeded: generator.next()), bits: 8)
                }
            }
            decodeAndCheck(file)
        }
    }
}
