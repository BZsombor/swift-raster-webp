/// The properties of a WebP file and the location of its still image data.
package struct WebPFileLayout {
    /// The properties of the file.
    package let info: WebPImageInfo

    /// The payload of the still image's `VP8 ` or `VP8L` chunk, or `nil` for an animation.
    package let imagePayload: Range<Int>?

    init(info: WebPImageInfo, imagePayload: Range<Int>?) {
        self.info = info
        self.imagePayload = imagePayload
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
