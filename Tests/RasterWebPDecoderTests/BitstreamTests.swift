import RasterWebP
import Testing

/// Handwritten bitstreams for behavior that encoders rarely produce.
@Suite("VP8L bitstreams")
struct BitstreamTests {
    private func expectFailure(
        _ kind: WebPError.Kind,
        _ file: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try WebPDecoder.decode(file)
            Issue.record("Expected a failure", sourceLocation: sourceLocation)
        } catch {
            #expect(error.kind == kind, sourceLocation: sourceLocation)
        }
    }

    @Test func singleSymbolCodesProduceASolidImage() throws {
        let file = VP8LFile.make(width: 2, height: 2) { writer in
            writer.writePlainImageHeader()
            writer.writeSingleSymbolCode(20)
            writer.writeConstantCodes(red: 10, blue: 30, alpha: 40)
        }

        let image = try WebPDecoder.decode(file)

        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(image.pixels == Array(repeating: [10, 20, 30, 40], count: 4).flatMap { $0 })
    }

    @Test func twoSymbolCodesConsumeOneBitPerPixel() throws {
        let file = VP8LFile.make(width: 3, height: 1) { writer in
            writer.writePlainImageHeader()
            writer.writeTwoSymbolCode(5, 200)
            writer.writeConstantCodes()
            writer.write(0b101, bits: 3)
        }

        let image = try WebPDecoder.decode(file)

        #expect(image.pixels == [0, 200, 0, 255, 0, 5, 0, 255, 0, 200, 0, 255])
    }

    /// Writes a three-pixel row: a literal, then backward references with the given symbol.
    private func backwardReferenceFile(lengthSymbol: Int, distance: UInt32, width: Int = 3) -> [UInt8] {
        VP8LFile.make(width: width, height: 1) { writer in
            writer.writePlainImageHeader()
            writer.writeUniformCode(symbols: [7, lengthSymbol], length: 1, alphabetSize: 280)
            writer.writeConstantCodes(distance: distance)
            writer.write(0, bits: 1)
            writer.write(1, bits: 1)
            writer.write(1, bits: 1)
        }
    }

    @Test func backwardReferencesRepeatEarlierPixels() throws {
        // Length symbol 256 copies one pixel. Distance prefix 1 is distance code 2, one pixel back.
        let image = try WebPDecoder.decode(backwardReferenceFile(lengthSymbol: 256, distance: 1))

        #expect(image.pixels == Array(repeating: [0, 7, 0, 255], count: 3).flatMap { $0 })
    }

    @Test func backwardReferenceBeforeTheImageIsRejected() {
        // Distance code 1 refers to the row above, which does not exist.
        expectFailure(.malformedBitstream, backwardReferenceFile(lengthSymbol: 256, distance: 0))
    }

    @Test func backwardReferencePastTheImageIsRejected() {
        // Length symbol 259 copies four pixels into a three-pixel image.
        expectFailure(.malformedBitstream, backwardReferenceFile(lengthSymbol: 259, distance: 1))
    }

    @Test func distancesBelowOneAreRaisedToOne() throws {
        // In a one-pixel-wide image, distance code 4 is (-1, 1), which maps to a distance of 0.
        let file = VP8LFile.make(width: 1, height: 3) { writer in
            writer.writePlainImageHeader()
            writer.writeUniformCode(symbols: [7, 256], length: 1, alphabetSize: 280)
            writer.writeConstantCodes(distance: 3)
            writer.write(0b110, bits: 3)
        }

        let image = try WebPDecoder.decode(file)

        #expect(image.pixels == Array(repeating: [0, 7, 0, 255], count: 3).flatMap { $0 })
    }

    @Test func entropyImageSelectsGroupsWithSixteenBitIndexes() throws {
        let file = VP8LFile.make(width: 1, height: 1) { writer in
            writer.write(0, bits: 1)
            writer.write(0, bits: 1)

            // An entropy image with one pixel that selects group 256 through its red channel.
            writer.write(1, bits: 1)
            writer.write(0, bits: 3)
            writer.write(0, bits: 1)
            writer.writeSingleSymbolCode(0)
            writer.writeConstantCodes(red: 1)

            for group in 0...256 {
                writer.writeSingleSymbolCode(group == 256 ? 77 : 1)
                writer.writeConstantCodes()
            }
        }

        let image = try WebPDecoder.decode(file)

        #expect(image.pixels == [0, 77, 0, 255])
    }

    @Test func prefixTablesCountTowardTheMemoryLimit() throws {
        let file = VP8LFile.make(width: 1, height: 1) { writer in
            writer.writePlainImageHeader()
            writer.writeUniformCode(symbols: Set(0..<256), length: 8, alphabetSize: 280)
            for _ in 0..<3 {
                writer.writeUniformCode(symbols: Set(0..<256), length: 8, alphabetSize: 256)
            }
            writer.writeSingleSymbolCode(0)
            writer.write(0, bits: 32)
        }

        #expect(try WebPDecoder.decode(file).width == 1)

        var options = WebPDecodingOptions()
        options.limits.maximumMemoryByteCount = 1024
        do {
            _ = try WebPDecoder.decode(file, options: options)
            Issue.record("Expected a failure")
        } catch {
            #expect(error.kind == .limitExceeded)
        }
    }

    @Test(arguments: [UInt32(0), 12, 15])
    func invalidColorCacheSizesAreRejected(bits: UInt32) {
        let file = VP8LFile.make(width: 1, height: 1) { writer in
            writer.write(0, bits: 1)
            writer.write(1, bits: 1)
            writer.write(bits, bits: 4)
        }
        expectFailure(.malformedBitstream, file)
    }

    @Test func repeatedTransformIsRejected() {
        let file = VP8LFile.make(width: 1, height: 1) { writer in
            for _ in 0..<2 {
                writer.write(1, bits: 1)
                writer.write(2, bits: 2)
            }
        }
        expectFailure(.malformedBitstream, file)
    }

    @Test func oversubscribedPrefixCodeIsRejected() {
        let file = VP8LFile.make(width: 1, height: 1) { writer in
            writer.writePlainImageHeader()
            writer.writeUniformCode(symbols: [1, 2, 3], length: 1, alphabetSize: 280)
        }
        expectFailure(.malformedBitstream, file)
    }

    @Test func incompletePrefixCodeIsRejected() {
        let file = VP8LFile.make(width: 1, height: 1) { writer in
            writer.writePlainImageHeader()
            writer.writeUniformCode(symbols: [1, 2, 3], length: 2, alphabetSize: 280)
        }
        expectFailure(.malformedBitstream, file)
    }

    @Test func distanceSymbolOutsideItsAlphabetIsRejected() {
        let file = VP8LFile.make(width: 1, height: 1) { writer in
            writer.writePlainImageHeader()
            writer.writeSingleSymbolCode(0)
            writer.writeConstantCodes(distance: 40)
        }
        expectFailure(.malformedBitstream, file)
    }

    @Test func colorIndexBeyondTheTableIsTransparentBlack() throws {
        let file = VP8LFile.make(width: 2, height: 1) { writer in
            // A color indexing transform with 17 colors, which disables pixel bundling.
            writer.write(1, bits: 1)
            writer.write(3, bits: 2)
            writer.write(16, bits: 8)

            // Every color table delta adds 1 to green and 255 to alpha on the first entry only.
            writer.write(0, bits: 1)
            writer.writeSingleSymbolCode(1)
            writer.writeConstantCodes(alpha: 0)

            writer.write(0, bits: 1)
            writer.write(0, bits: 1)
            writer.write(0, bits: 1)
            writer.writeTwoSymbolCode(2, 200)
            writer.writeConstantCodes()
            writer.write(0b10, bits: 2)
        }

        let image = try WebPDecoder.decode(file)

        #expect(image.pixels == [0, 3, 0, 0, 0, 0, 0, 0])
    }

    @Test func missingPixelDataIsTruncated() {
        let file = VP8LFile.make(width: 1000, height: 1000) { writer in
            writer.writePlainImageHeader()
            writer.writeTwoSymbolCode(1, 2)
            writer.writeConstantCodes()
        }
        expectFailure(.truncated, file)
    }

    @Test func missingCodesAreTruncated() {
        let file = VP8LFile.make(width: 16, height: 16) { writer in
            writer.writePlainImageHeader()
        }
        expectFailure(.truncated, file)
    }
}
