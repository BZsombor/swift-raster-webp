/// The properties of a WebP file and the location of its still image data.
package struct WebPFileLayout {
    /// The properties of the file.
    package let info: WebPImageInfo

    /// The payload of the still image's `VP8 ` or `VP8L` chunk, or `nil` for an animation.
    package let imagePayload: Range<Int>?

    /// The payload of the `ALPH` chunk that belongs to a lossy still image, if there is one.
    package let alphaPayload: Range<Int>?

    /// The payloads of the color profile and metadata chunks.
    package let metadata: MetadataLocations

    /// A reader positioned before the first frame, or `nil` for a still image.
    package let frames: AnimationFrameReader?

    /// The number of pixels in all frames together, or `Int.max` if that does not fit in `Int`.
    package let framePixelCount: Int

    init(
        info: WebPImageInfo,
        imagePayload: Range<Int>?,
        alphaPayload: Range<Int>? = nil,
        metadata: MetadataLocations = MetadataLocations(),
        frames: AnimationFrameReader? = nil,
        framePixelCount: Int? = nil
    ) {
        self.info = info
        self.imagePayload = imagePayload
        self.alphaPayload = alphaPayload
        self.metadata = metadata
        self.frames = frames
        self.framePixelCount = framePixelCount ?? area(info.width, info.height)
    }

    /// Locates the contents of a complete WebP file.
    package init(parsing bytes: Span<UInt8>) throws(WebPError) {
        var chunks = try RIFFChunkReader(file: bytes)

        guard let first = try chunks.next(in: bytes) else {
            throw WebPError(.noChunks)
        }

        switch first.fourCC {
        case .vp8, .vp8l:
            let header = try BitstreamHeader(chunk: first, bytes: bytes)
            let info = WebPImageInfo(
                width: header.width,
                height: header.height,
                compression: header.compression,
                hasAlpha: header.hasAlpha,
                animation: nil,
                hasICCProfile: false,
                hasEXIF: false,
                hasXMP: false
            )
            self.init(info: info, imagePayload: first.payload)
        case .vp8x:
            self = try WebPImageInfo.parseExtendedFile(first: first, chunks: &chunks, bytes: bytes)
        default:
            throw WebPError(.unexpectedFirstChunk)
        }
    }
}
