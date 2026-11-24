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
        self = try WebPFileLayout(parsing: bytes).info
    }

    /// Parses a file that starts with the given `VP8X` chunk.
    static func parseExtendedFile(
        first: RIFFChunk,
        chunks: inout RIFFChunkReader,
        bytes: Span<UInt8>
    ) throws(WebPError) -> WebPFileLayout {
        let canvas = try ExtendedHeader(chunk: first, bytes: bytes)
        if canvas.isAnimated {
            return try parseAnimation(canvas: canvas, chunks: chunks, bytes: bytes)
        }
        return try parseExtendedStill(canvas: canvas, chunks: &chunks, bytes: bytes)
    }

    private static func parseExtendedStill(
        canvas: ExtendedHeader,
        chunks: inout RIFFChunkReader,
        bytes: Span<UInt8>
    ) throws(WebPError) -> WebPFileLayout {
        var metadata = MetadataLocations()
        var alphaPayload: Range<Int>?
        var image: BitstreamHeader?
        var imagePayload: Range<Int>?

        while image == nil, let chunk = try chunks.next(in: bytes) {
            switch chunk.fourCC {
            case .vp8, .vp8l:
                image = try BitstreamHeader(chunk: chunk, bytes: bytes)
                imagePayload = chunk.payload
            case .alph:
                // The format allows one ALPH chunk, so later ones are ignored.
                alphaPayload = alphaPayload ?? chunk.payload
            default:
                metadata.record(chunk)
            }
        }

        guard let image else {
            throw WebPError(.missingImageData)
        }
        let hasAlphaChunk = alphaPayload != nil
        guard image.width == canvas.width, image.height == canvas.height else {
            throw WebPError(.canvasSizeMismatch)
        }

        // The pixels are already reachable, so damage after them must not reject the image.
        while let chunk = try? chunks.next(in: bytes) {
            metadata.record(chunk)
        }

        let info = WebPImageInfo(
            width: canvas.width,
            height: canvas.height,
            compression: image.compression,
            hasAlpha: canvas.declaresAlpha || hasAlphaChunk || image.hasAlpha,
            animation: nil,
            hasICCProfile: metadata.iccProfile != nil,
            hasEXIF: metadata.exif != nil,
            hasXMP: metadata.xmp != nil
        )
        // A lossless image carries its own alpha, so an ALPH chunk next to it is ignored.
        let lossyAlpha = image.compression == .lossy ? alphaPayload : nil
        return WebPFileLayout(
            info: info,
            imagePayload: imagePayload,
            alphaPayload: lossyAlpha,
            metadata: metadata
        )
    }

    private static func parseAnimation(
        canvas: ExtendedHeader,
        chunks: RIFFChunkReader,
        bytes: Span<UInt8>
    ) throws(WebPError) -> WebPFileLayout {
        let frames = AnimationFrameReader(chunks: chunks, canvasWidth: canvas.width, canvasHeight: canvas.height)
        var chunks = chunks
        var metadata = MetadataLocations()
        var parameters: AnimationParameters?
        var frameCount = 0
        var framePixelCount = 0
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
                let frame = try AnimationFrame(
                    chunk: chunk,
                    canvasWidth: canvas.width,
                    canvasHeight: canvas.height,
                    bytes: bytes
                )
                frameCount += 1
                framePixelCount = framePixelCount.saturatingAdd(area(frame.info.width, frame.info.height))
                hasAlpha = hasAlpha || frame.info.hasAlpha
                compression = compression.merged(with: frame.info.compression)
            default:
                metadata.record(chunk)
            }
        }

        guard let parameters else {
            throw WebPError(.missingANIM)
        }
        guard let compression else {
            throw WebPError(.missingFrames)
        }

        let info = WebPImageInfo(
            width: canvas.width,
            height: canvas.height,
            compression: compression,
            hasAlpha: hasAlpha,
            animation: WebPAnimationInfo(
                frameCount: frameCount,
                loopCount: parameters.loopCount,
                backgroundColor: parameters.backgroundColor
            ),
            hasICCProfile: metadata.iccProfile != nil,
            hasEXIF: metadata.exif != nil,
            hasXMP: metadata.xmp != nil
        )
        return WebPFileLayout(
            info: info,
            imagePayload: nil,
            metadata: metadata,
            frames: frames,
            framePixelCount: framePixelCount
        )
    }
}

/// Returns `width * height`, or `Int.max` where that does not fit, as on 32-bit platforms.
func area(_ width: Int, _ height: Int) -> Int {
    let (product, overflow) = width.multipliedReportingOverflow(by: height)
    return overflow ? Int.max : product
}

extension Int {
    fileprivate func saturatingAdd(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? Int.max : sum
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
