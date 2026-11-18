extension WebPImageInfo {
    /// Reads the properties of a complete WebP file without decoding its pixels.
    ///
    /// - Parameter bytes: The contents of the file.
    /// - Throws: A ``WebPError`` if the data is not a valid WebP file.
    public init(parsing bytes: [UInt8]) throws(WebPError) {
        let parse: (UnsafeBufferPointer<UInt8>) throws(WebPError) -> WebPImageInfo = { buffer throws(WebPError) in
            try unsafe WebPImageInfo(parsing: buffer.span)
        }

        // Swift 6.3 requires this marker here, while Swift 6.4 reports it as unnecessary.
        #if compiler(>=6.4)
            self = try bytes.withUnsafeBufferPointer(parse)
        #else
            self = try unsafe bytes.withUnsafeBufferPointer(parse)
        #endif
    }

    /// Reads the properties of a complete WebP file without decoding its pixels.
    ///
    /// - Parameter bytes: The contents of the file.
    /// - Throws: A ``WebPError`` if the data is not a valid WebP file.
    public init(parsing bytes: Span<UInt8>) throws(WebPError) {
        var chunks = try RIFFChunkReader(file: bytes)

        guard let first = try chunks.next(in: bytes) else {
            throw WebPError(.noChunks)
        }

        switch first.fourCC {
        case .vp8, .vp8l:
            let header = try BitstreamHeader(chunk: first, bytes: bytes)
            self.init(
                width: header.width,
                height: header.height,
                compression: header.compression,
                hasAlpha: header.hasAlpha,
                animation: nil,
                hasICCProfile: false,
                hasEXIF: false,
                hasXMP: false
            )
        case .vp8x:
            let canvas = try ExtendedHeader(chunk: first, bytes: bytes)
            if canvas.isAnimated {
                self = try Self.parseAnimation(canvas: canvas, chunks: &chunks, bytes: bytes)
            } else {
                self = try Self.parseExtendedStill(canvas: canvas, chunks: &chunks, bytes: bytes)
            }
        default:
            throw WebPError(.unexpectedFirstChunk)
        }
    }

    private static func parseExtendedStill(
        canvas: ExtendedHeader,
        chunks: inout RIFFChunkReader,
        bytes: Span<UInt8>
    ) throws(WebPError) -> WebPImageInfo {
        var metadata = MetadataPresence()
        var hasAlphaChunk = false
        var image: BitstreamHeader?

        while image == nil, let chunk = try chunks.next(in: bytes) {
            switch chunk.fourCC {
            case .vp8, .vp8l:
                image = try BitstreamHeader(chunk: chunk, bytes: bytes)
            case .alph:
                hasAlphaChunk = true
            default:
                metadata.record(chunk.fourCC)
            }
        }

        guard let image else {
            throw WebPError(.missingImageData)
        }
        guard image.width == canvas.width, image.height == canvas.height else {
            throw WebPError(.canvasSizeMismatch)
        }

        // The pixels are already reachable, so damage after them must not reject the image.
        while let chunk = try? chunks.next(in: bytes) {
            metadata.record(chunk.fourCC)
        }

        return WebPImageInfo(
            width: canvas.width,
            height: canvas.height,
            compression: image.compression,
            hasAlpha: canvas.declaresAlpha || hasAlphaChunk || image.hasAlpha,
            animation: nil,
            hasICCProfile: metadata.hasICCProfile,
            hasEXIF: metadata.hasEXIF,
            hasXMP: metadata.hasXMP
        )
    }

    private static func parseAnimation(
        canvas: ExtendedHeader,
        chunks: inout RIFFChunkReader,
        bytes: Span<UInt8>
    ) throws(WebPError) -> WebPImageInfo {
        var metadata = MetadataPresence()
        var parameters: AnimationParameters?
        var frameCount = 0
        var compression: WebPCompression?
        var hasAlpha = canvas.declaresAlpha

        while let chunk = try chunks.next(in: bytes) {
            switch chunk.fourCC {
            case .anim:
                guard parameters == nil else {
                    throw WebPError(.duplicateANIM)
                }
                parameters = try AnimationParameters(chunk: chunk, bytes: bytes)
            case .anmf:
                guard parameters != nil else {
                    throw WebPError(.frameBeforeANIM)
                }
                let frame = try AnimationFrame(chunk: chunk, canvas: canvas, bytes: bytes)
                frameCount += 1
                hasAlpha = hasAlpha || frame.hasAlpha
                compression = compression.merged(with: frame.compression)
            default:
                metadata.record(chunk.fourCC)
            }
        }

        guard let parameters else {
            throw WebPError(.missingANIM)
        }
        guard let compression else {
            throw WebPError(.missingFrames)
        }

        return WebPImageInfo(
            width: canvas.width,
            height: canvas.height,
            compression: compression,
            hasAlpha: hasAlpha,
            animation: WebPAnimationInfo(
                frameCount: frameCount,
                loopCount: parameters.loopCount,
                backgroundColor: parameters.backgroundColor
            ),
            hasICCProfile: metadata.hasICCProfile,
            hasEXIF: metadata.hasEXIF,
            hasXMP: metadata.hasXMP
        )
    }
}

extension Optional<WebPCompression> {
    fileprivate func merged(with other: WebPCompression) -> WebPCompression {
        guard let self, self != other else {
            return other
        }
        return .mixed
    }
}

/// Tracks which metadata chunks appear in a file.
private struct MetadataPresence {
    var hasICCProfile = false
    var hasEXIF = false
    var hasXMP = false

    mutating func record(_ fourCC: FourCC) {
        switch fourCC {
        case .iccp: hasICCProfile = true
        case .exif: hasEXIF = true
        case .xmp: hasXMP = true
        default: break
        }
    }
}

/// The contents of a `VP8X` chunk.
private struct ExtendedHeader {
    let width: Int
    let height: Int
    let declaresAlpha: Bool
    let isAnimated: Bool

    init(chunk: RIFFChunk, bytes: Span<UInt8>) throws(WebPError) {
        guard chunk.payload.count == 10 else {
            throw WebPError(.invalidVP8XSize)
        }

        let start = chunk.payload.lowerBound
        let flags = bytes[start]

        width = Int(bytes.littleEndianUInt24(at: start + 4)) + 1
        height = Int(bytes.littleEndianUInt24(at: start + 7)) + 1
        declaresAlpha = flags & 0x10 != 0
        isAnimated = flags & 0x02 != 0

        guard UInt64(width) * UInt64(height) <= UInt64(UInt32.max) else {
            throw WebPError(.canvasTooLarge)
        }
    }
}

/// The contents of an `ANIM` chunk.
private struct AnimationParameters {
    let backgroundColor: WebPBackgroundColor
    let loopCount: Int

    init(chunk: RIFFChunk, bytes: Span<UInt8>) throws(WebPError) {
        guard chunk.payload.count >= 6 else {
            throw WebPError(.animTooShort)
        }

        let start = chunk.payload.lowerBound
        backgroundColor = WebPBackgroundColor(
            red: bytes[start + 2],
            green: bytes[start + 1],
            blue: bytes[start],
            alpha: bytes[start + 3]
        )
        loopCount = Int(bytes.littleEndianUInt16(at: start + 4))
    }
}

/// The validated properties of an `ANMF` chunk.
private struct AnimationFrame {
    private static var headerSize: Int { 16 }

    let compression: WebPCompression
    let hasAlpha: Bool

    init(chunk: RIFFChunk, canvas: ExtendedHeader, bytes: Span<UInt8>) throws(WebPError) {
        guard chunk.payload.count >= Self.headerSize else {
            throw WebPError(.anmfTooShort)
        }

        let start = chunk.payload.lowerBound
        let x = Int(bytes.littleEndianUInt24(at: start)) * 2
        let y = Int(bytes.littleEndianUInt24(at: start + 3)) * 2
        let width = Int(bytes.littleEndianUInt24(at: start + 6)) + 1
        let height = Int(bytes.littleEndianUInt24(at: start + 9)) + 1

        guard x + width <= canvas.width, y + height <= canvas.height else {
            throw WebPError(.frameExceedsCanvas)
        }

        var frameChunks = RIFFChunkReader(range: (start + Self.headerSize)..<chunk.payload.upperBound)
        var hasAlphaChunk = false
        var image: BitstreamHeader?

        while image == nil, let frameChunk = try frameChunks.next(in: bytes) {
            switch frameChunk.fourCC {
            case .vp8, .vp8l:
                image = try BitstreamHeader(chunk: frameChunk, bytes: bytes)
            case .alph:
                hasAlphaChunk = true
            default:
                break
            }
        }

        guard let image else {
            throw WebPError(.frameMissingImageData)
        }
        guard image.width == width, image.height == height else {
            throw WebPError(.frameSizeMismatch)
        }

        compression = image.compression
        hasAlpha = hasAlphaChunk || image.hasAlpha
    }
}
