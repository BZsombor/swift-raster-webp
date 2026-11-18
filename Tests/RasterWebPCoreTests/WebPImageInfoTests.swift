import RasterWebP
import Testing

private typealias Builder = WebPFileBuilder

@Suite("Valid files")
struct ValidFileTests {
    @Test func simpleLossy() throws {
        let info = try WebPImageInfo(parsing: Builder.file(Builder.vp8(width: 640, height: 480)))

        #expect(info.width == 640)
        #expect(info.height == 480)
        #expect(info.compression == .lossy)
        #expect(!info.hasAlpha)
        #expect(!info.isAnimated)
    }

    @Test func lossyDimensionsIgnoreScalingBits() throws {
        let info = try WebPImageInfo(
            parsing: Builder.file(Builder.vp8(width: 0x4000 | 100, height: 0xC000 | 200))
        )

        #expect(info.width == 100)
        #expect(info.height == 200)
    }

    @Test(arguments: [false, true])
    func simpleLossless(alpha: Bool) throws {
        let info = try WebPImageInfo(
            parsing: Builder.file(Builder.vp8l(width: 16384, height: 1, alpha: alpha))
        )

        #expect(info.width == 16384)
        #expect(info.height == 1)
        #expect(info.compression == .lossless)
        #expect(info.hasAlpha == alpha)
    }

    @Test func extendedStillWithAlphaChunkAndMetadata() throws {
        let file = Builder.file(
            Builder.vp8x(width: 10, height: 20),
            Builder.chunk("ICCP", [1, 2, 3]),
            Builder.chunk("ALPH", [0]),
            Builder.vp8(width: 10, height: 20),
            Builder.chunk("EXIF", [4]),
            Builder.chunk("XMP ", [5, 6])
        )

        let info = try WebPImageInfo(parsing: file)

        #expect(info.compression == .lossy)
        #expect(info.hasAlpha)
        #expect(info.hasICCProfile)
        #expect(info.hasEXIF)
        #expect(info.hasXMP)
    }

    @Test func extendedStillDeclaringAlpha() throws {
        let file = Builder.file(
            Builder.vp8x(width: 10, height: 20, flags: VP8XFlags.alpha),
            Builder.vp8(width: 10, height: 20)
        )

        #expect(try WebPImageInfo(parsing: file).hasAlpha)
    }

    @Test func unknownChunksAreSkipped() throws {
        let file = Builder.file(
            Builder.vp8x(width: 10, height: 20),
            Builder.chunk("JUNK", [1, 2, 3, 4, 5]),
            Builder.vp8l(width: 10, height: 20)
        )

        #expect(try WebPImageInfo(parsing: file).compression == .lossless)
    }

    @Test func missingFinalPaddingByteIsTolerated() throws {
        var file = Builder.file(
            Builder.vp8x(width: 10, height: 20),
            Builder.vp8l(width: 10, height: 20),
            Builder.chunk("EXIF", [1])
        )
        file.removeLast()
        file[4] -= 1

        #expect(try WebPImageInfo(parsing: file).hasEXIF)
    }

    @Test func dataAfterTheRIFFSizeIsIgnored() throws {
        let file = Builder.file(Builder.vp8(width: 10, height: 20)) + [0xFF, 0xFF, 0xFF]

        #expect(try WebPImageInfo(parsing: file).width == 10)
    }

    @Test func damageAfterTheImageKeepsTheStillImage() throws {
        let file = Builder.file(
            Builder.vp8x(width: 10, height: 20),
            Builder.vp8(width: 10, height: 20),
            [0x45, 0x58]
        )

        #expect(try WebPImageInfo(parsing: file).width == 10)
    }

    @Test func animationWithMixedFrames() throws {
        let file = Builder.file(
            Builder.vp8x(width: 20, height: 20, flags: VP8XFlags.animation),
            Builder.anim(loopCount: 7),
            Builder.anmf(width: 10, height: 10, image: Builder.vp8(width: 10, height: 10)),
            Builder.anmf(x: 10, y: 10, width: 10, height: 10, image: Builder.vp8l(width: 10, height: 10, alpha: true))
        )

        let info = try WebPImageInfo(parsing: file)
        let animation = try #require(info.animation)

        #expect(info.compression == .mixed)
        #expect(info.hasAlpha)
        #expect(animation.frameCount == 2)
        #expect(animation.loopCount == 7)
        #expect(animation.backgroundColor.blue == 1)
        #expect(animation.backgroundColor.green == 2)
        #expect(animation.backgroundColor.red == 3)
        #expect(animation.backgroundColor.alpha == 4)
    }

    @Test func spanAndArrayInputsAgree() throws {
        let file = Builder.file(Builder.vp8(width: 12, height: 34))

        let fromArray = try WebPImageInfo(parsing: file)
        let fromSpan = try file.withUnsafeBufferPointer { try WebPImageInfo(parsing: $0.span) }

        #expect(fromArray == fromSpan)
    }
}

@Suite("Invalid files")
struct InvalidFileTests {
    private func expectFailure(
        _ kind: WebPError.Kind,
        _ file: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let info = try WebPImageInfo(parsing: file)
            Issue.record("Expected a failure, got \(info)", sourceLocation: sourceLocation)
        } catch {
            #expect(error.kind == kind, sourceLocation: sourceLocation)
            #expect(!error.description.isEmpty, sourceLocation: sourceLocation)
        }
    }

    @Test func emptyDataIsTruncated() {
        expectFailure(.truncated, [])
    }

    @Test func otherFormatsAreNotWebP() {
        expectFailure(.notWebP, Array("GIF89a".utf8))
        expectFailure(.notWebP, Array("RIFF\0\0\0\0WAVEfmt ".utf8))
    }

    @Test func missingBytesAreTruncated() {
        let file = Builder.file(Builder.vp8(width: 10, height: 20))
        expectFailure(.truncated, Array(file.dropLast()))
    }

    @Test func tooSmallRIFFSizeIsRejected() {
        var file = Builder.file(Builder.vp8(width: 10, height: 20))
        file.replaceSubrange(4..<8, with: Builder.littleEndian(4, byteCount: 4))
        expectFailure(.malformedContainer, file)
    }

    @Test func maximumChunkSizeDoesNotOverflow() {
        let file = Builder.file(Array("VP8 ".utf8) + [0xFF, 0xFF, 0xFF, 0xFF])
        expectFailure(.malformedContainer, file)
    }

    @Test func chunkEndingJustPastItsContainerIsRejected() {
        let payload = Builder.vp8lPayload(width: 10, height: 10) + [0]
        let oversized = Array("VP8L".utf8) + Builder.littleEndian(UInt32(payload.count + 1), byteCount: 4) + payload

        expectFailure(.malformedContainer, Builder.file(oversized))
    }

    @Test func maximumRIFFSizeIsTruncated() {
        var file = Builder.file(Builder.vp8(width: 10, height: 20))
        file.replaceSubrange(4..<8, with: Builder.littleEndian(0xFFFF_FFF6, byteCount: 4))
        expectFailure(.truncated, file)
    }

    @Test func fileWithoutChunksIsRejected() {
        expectFailure(.malformedContainer, Builder.file([]))
    }

    @Test func unknownFirstChunkIsRejected() {
        expectFailure(.malformedContainer, Builder.file(Builder.chunk("JUNK", [1, 2])))
    }

    @Test func vp8xWithInvalidSizeIsRejected() {
        expectFailure(.malformedContainer, Builder.file(Builder.chunk("VP8X", [0, 0, 0, 0])))
    }

    @Test func oversizedCanvasIsRejected() {
        let file = Builder.file(
            Builder.vp8x(width: 1 << 24, height: 1 << 24),
            Builder.vp8(width: 10, height: 20)
        )
        expectFailure(.malformedContainer, file)
    }

    @Test func extendedFileWithoutImageIsRejected() {
        expectFailure(.malformedContainer, Builder.file(Builder.vp8x(width: 10, height: 20)))
    }

    @Test func canvasMismatchIsRejected() {
        let file = Builder.file(Builder.vp8x(width: 11, height: 20), Builder.vp8(width: 10, height: 20))
        expectFailure(.malformedContainer, file)
    }

    @Test func animationStructureIsValidated() {
        let vp8x = Builder.vp8x(width: 10, height: 10, flags: VP8XFlags.animation)
        let frame = Builder.anmf(width: 10, height: 10, image: Builder.vp8(width: 10, height: 10))

        expectFailure(.malformedContainer, Builder.file(vp8x, frame))
        expectFailure(.malformedContainer, Builder.file(vp8x, Builder.anim()))
        expectFailure(.malformedContainer, Builder.file(vp8x))
        expectFailure(.malformedContainer, Builder.file(vp8x, Builder.anim(), Builder.anim(), frame))
        expectFailure(.malformedContainer, Builder.file(vp8x, Builder.chunk("ANIM", [0]), frame))
        expectFailure(.malformedContainer, Builder.file(vp8x, Builder.anim(), Builder.chunk("ANMF", [0, 0])))
    }

    @Test func animationFramesAreValidated() {
        let vp8x = Builder.vp8x(width: 10, height: 10, flags: VP8XFlags.animation)
        let image = Builder.vp8(width: 10, height: 10)

        let outside = Builder.anmf(x: 2, width: 10, height: 10, image: image)
        let mismatched = Builder.anmf(width: 8, height: 8, image: image)
        let empty = Builder.anmf(width: 10, height: 10, image: Builder.chunk("JUNK", [1]))

        expectFailure(.malformedContainer, Builder.file(vp8x, Builder.anim(), outside))
        expectFailure(.malformedContainer, Builder.file(vp8x, Builder.anim(), mismatched))
        expectFailure(.malformedContainer, Builder.file(vp8x, Builder.anim(), empty))
    }

    @Test(arguments: [
        UInt32(1) | 1 << 4 | 1 << 5,  // Not a key frame.
        UInt32(4) << 1 | 1 << 4 | 1 << 5,  // Unknown profile.
        UInt32(1) << 5,  // Not displayable.
        UInt32(1) << 4 | 10 << 5,  // Partition exceeds the chunk.
    ])
    func invalidVP8FrameTags(frameTag: UInt32) {
        let payload = Builder.vp8Payload(width: 10, height: 10, frameTag: frameTag)
        expectFailure(.malformedBitstream, Builder.file(Builder.chunk("VP8 ", payload)))
    }

    @Test func invalidVP8HeadersAreRejected() {
        var missingStartCode = Builder.vp8Payload(width: 10, height: 10)
        missingStartCode[3] = 0

        expectFailure(.malformedBitstream, Builder.file(Builder.chunk("VP8 ", [0, 0])))
        expectFailure(.malformedBitstream, Builder.file(Builder.chunk("VP8 ", missingStartCode)))
        expectFailure(.malformedBitstream, Builder.file(Builder.vp8(width: 0, height: 10)))
        expectFailure(.malformedBitstream, Builder.file(Builder.vp8(width: 10, height: 0)))
    }

    @Test func invalidVP8LHeadersAreRejected() {
        var missingSignature = Builder.vp8lPayload(width: 10, height: 10)
        missingSignature[0] = 0
        let unknownVersion = Builder.vp8lPayload(width: 10, height: 10, version: 1)

        expectFailure(.malformedBitstream, Builder.file(Builder.chunk("VP8L", [0x2F])))
        expectFailure(.malformedBitstream, Builder.file(Builder.chunk("VP8L", missingSignature)))
        expectFailure(.malformedBitstream, Builder.file(Builder.chunk("VP8L", unknownVersion)))
    }
}
