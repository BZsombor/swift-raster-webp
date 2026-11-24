import RasterWebP
import Testing

@Suite("Metadata")
struct WebPMetadataTests {
    private let icc = WebPFileBuilder.chunk("ICCP", Array("profile".utf8))
    private let exif = WebPFileBuilder.chunk("EXIF", Array("Exif\0\0".utf8))
    private let xmp = WebPFileBuilder.chunk("XMP ", Array("<x/>".utf8))

    @Test func readsEveryKindFromAFile() throws {
        let metadata = try WebPMetadata(parsing: PackageResources.metadata_webp)

        #expect(metadata.iccProfile == Array("test-icc-profile".utf8))
        #expect(metadata.exif == Array("Exif\0\0test".utf8))
        #expect(metadata.xmp == Array("<x:xmpmeta/>".utf8))
    }

    @Test func filesWithoutMetadataHaveNone() throws {
        for bytes in [
            PackageResources.lossy_webp, PackageResources.lossless_alpha_webp, PackageResources.animated_mixed_webp,
        ] {
            let metadata = try WebPMetadata(parsing: bytes)
            #expect(metadata.iccProfile == nil && metadata.exif == nil && metadata.xmp == nil)
        }
    }

    @Test func spanAndArrayInputsAgree() throws {
        let bytes = PackageResources.metadata_webp
        let fromSpan = try bytes.withUnsafeBufferPointer { try WebPMetadata(parsing: $0.span) }
        #expect(try WebPMetadata(parsing: bytes) == fromSpan)
    }

    @Test func theFirstChunkOfEachKindWins() throws {
        let second = WebPFileBuilder.chunk("ICCP", Array("other".utf8))
        let bytes = WebPFileBuilder.file(
            WebPFileBuilder.vp8x(width: 4, height: 4),
            icc,
            second,
            WebPFileBuilder.vp8l(width: 4, height: 4),
            xmp,
            WebPFileBuilder.chunk("XMP ", Array("<y/>".utf8))
        )
        let metadata = try WebPMetadata(parsing: bytes)

        #expect(metadata.iccProfile == Array("profile".utf8))
        #expect(metadata.xmp == Array("<x/>".utf8))
    }

    @Test func chunksDecideRegardlessOfOrderAndFlags() throws {
        // The flags claim nothing, and the ICC profile follows the image data.
        let bytes = WebPFileBuilder.file(
            WebPFileBuilder.vp8x(width: 4, height: 4),
            WebPFileBuilder.vp8l(width: 4, height: 4),
            exif,
            icc
        )
        let metadata = try WebPMetadata(parsing: bytes)
        let info = try WebPImageInfo(parsing: bytes)

        #expect(metadata.iccProfile == Array("profile".utf8))
        #expect(metadata.exif == Array("Exif\0\0".utf8))
        #expect(info.hasICCProfile && info.hasEXIF && !info.hasXMP)

        // The flags claim every kind, but the file has none.
        let flagged = WebPFileBuilder.file(
            WebPFileBuilder.vp8x(width: 4, height: 4, flags: 0x20 | 0x08 | 0x04),
            WebPFileBuilder.vp8l(width: 4, height: 4)
        )
        #expect(try WebPMetadata(parsing: flagged).iccProfile == nil)
    }

    @Test func invalidFilesThrow() {
        #expect(throws: WebPError.self) { try WebPMetadata(parsing: Array("RIFF".utf8)) }
    }
}
