/// A validated `ANMF` chunk and the location of its image data.
package struct AnimationFrame {
    private static var headerSize: Int { 16 }

    /// The properties of the frame.
    package let info: WebPFrameInfo

    /// The payload of the frame's `VP8 ` or `VP8L` chunk.
    package let imagePayload: Range<Int>

    /// The payload of the `ALPH` chunk of a lossy frame, if there is one.
    package let alphaPayload: Range<Int>?

    /// Reads an `ANMF` chunk, described in RFC 9649, section 2.7.1.1.
    init(chunk: RIFFChunk, canvasWidth: Int, canvasHeight: Int, bytes: Span<UInt8>) throws(WebPError) {
        guard chunk.payload.count >= Self.headerSize else {
            throw WebPError(.anmfTooShort)
        }

        let start = chunk.payload.lowerBound
        let x = Int(bytes.littleEndianUInt24(at: start)) * 2
        let y = Int(bytes.littleEndianUInt24(at: start + 3)) * 2
        let width = Int(bytes.littleEndianUInt24(at: start + 6)) + 1
        let height = Int(bytes.littleEndianUInt24(at: start + 9)) + 1
        let duration = Int(bytes.littleEndianUInt24(at: start + 12))
        let flags = bytes[start + 15]

        guard x + width <= canvasWidth, y + height <= canvasHeight else {
            throw WebPError(.frameExceedsCanvas)
        }

        // The frame holds an optional ALPH chunk, the image chunk and optional unknown chunks.
        var frameChunks = RIFFChunkReader(range: (start + Self.headerSize)..<chunk.payload.upperBound)
        var alphaPayload: Range<Int>?
        var image: BitstreamHeader?
        var imagePayload: Range<Int>?

        while image == nil, let frameChunk = try frameChunks.next(in: bytes) {
            switch frameChunk.fourCC {
            case .vp8, .vp8l:
                image = try BitstreamHeader(chunk: frameChunk, bytes: bytes)
                imagePayload = frameChunk.payload
            case .alph:
                alphaPayload = alphaPayload ?? frameChunk.payload
            default:
                break
            }
        }

        guard let image, let imagePayload else {
            throw WebPError(.frameMissingImageData)
        }
        guard image.width == width, image.height == height else {
            throw WebPError(.frameSizeMismatch)
        }

        // A lossless frame carries its own alpha, so an ALPH chunk next to it is ignored.
        let lossyAlpha = image.compression == .lossy ? alphaPayload : nil
        info = WebPFrameInfo(
            x: x,
            y: y,
            width: width,
            height: height,
            duration: duration,
            blending: flags & 0x02 == 0 ? .alphaBlend : .overwrite,
            disposal: flags & 0x01 == 0 ? .none : .background,
            compression: image.compression,
            hasAlpha: lossyAlpha != nil || image.hasAlpha
        )
        self.imagePayload = imagePayload
        self.alphaPayload = lossyAlpha
    }
}

/// Walks the frames of a validated animation, skipping the other chunks.
package struct AnimationFrameReader {
    private var chunks: RIFFChunkReader
    private let canvasWidth: Int
    private let canvasHeight: Int

    init(chunks: RIFFChunkReader, canvasWidth: Int, canvasHeight: Int) {
        self.chunks = chunks
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    /// Returns the next frame, or `nil` after the last one.
    package mutating func next(in bytes: Span<UInt8>) throws(WebPError) -> AnimationFrame? {
        while let chunk = try chunks.next(in: bytes) {
            if chunk.fourCC == .anmf {
                return try AnimationFrame(
                    chunk: chunk,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                    bytes: bytes
                )
            }
        }
        return nil
    }
}
