/// The properties stored at the start of a VP8 or VP8L bitstream.
struct BitstreamHeader {
    let width: Int
    let height: Int
    let compression: WebPCompression
    let hasAlpha: Bool

    /// Reads the header of a `VP8 ` or `VP8L` chunk.
    init(chunk: RIFFChunk, bytes: Span<UInt8>) throws(WebPError) {
        if chunk.fourCC == .vp8 {
            self = try Self.parseLossy(payload: chunk.payload, bytes: bytes)
        } else {
            self = try Self.parseLossless(payload: chunk.payload, bytes: bytes)
        }
    }

    private init(width: Int, height: Int, compression: WebPCompression, hasAlpha: Bool) {
        self.width = width
        self.height = height
        self.compression = compression
        self.hasAlpha = hasAlpha
    }

    /// Parses the VP8 frame header described in RFC 6386, section 9.1.
    private static func parseLossy(
        payload: Range<Int>,
        bytes: Span<UInt8>
    ) throws(WebPError) -> BitstreamHeader {
        guard payload.count >= 10 else {
            throw WebPError(.vp8HeaderTooShort)
        }

        let start = payload.lowerBound
        let frameTag = bytes.littleEndianUInt24(at: start)

        guard frameTag & 1 == 0 else {
            throw WebPError(.vp8NotKeyFrame)
        }
        guard (frameTag >> 1) & 0b111 <= 3 else {
            throw WebPError(.vp8UnknownProfile)
        }
        guard (frameTag >> 4) & 1 == 1 else {
            throw WebPError(.vp8NotDisplayable)
        }
        guard Int(frameTag >> 5) < payload.count else {
            throw WebPError(.vp8PartitionExceedsChunk)
        }
        guard bytes[start + 3] == 0x9D, bytes[start + 4] == 0x01, bytes[start + 5] == 0x2A else {
            throw WebPError(.vp8MissingStartCode)
        }

        // The upper two bits of each dimension hold an upscaling hint.
        let width = Int(bytes.littleEndianUInt16(at: start + 6) & 0x3FFF)
        let height = Int(bytes.littleEndianUInt16(at: start + 8) & 0x3FFF)

        guard width > 0, height > 0 else {
            throw WebPError(.vp8EmptyDimension)
        }

        return BitstreamHeader(width: width, height: height, compression: .lossy, hasAlpha: false)
    }

    /// Parses the VP8L header described in RFC 9649, section 3.4.
    private static func parseLossless(
        payload: Range<Int>,
        bytes: Span<UInt8>
    ) throws(WebPError) -> BitstreamHeader {
        guard payload.count >= 5 else {
            throw WebPError(.vp8lHeaderTooShort)
        }

        let start = payload.lowerBound
        guard bytes[start] == 0x2F else {
            throw WebPError(.vp8lMissingSignature)
        }

        let fields = bytes.littleEndianUInt32(at: start + 1)
        guard fields >> 29 == 0 else {
            throw WebPError(.vp8lUnknownVersion)
        }

        return BitstreamHeader(
            width: Int(fields & 0x3FFF) + 1,
            height: Int((fields >> 14) & 0x3FFF) + 1,
            compression: .lossless,
            hasAlpha: (fields >> 28) & 1 == 1
        )
    }
}
