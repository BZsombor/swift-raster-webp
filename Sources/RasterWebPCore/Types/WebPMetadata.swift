/// The color profile and metadata stored in a WebP file.
///
/// Each property holds the payload of the first chunk of its kind, without interpretation. When
/// a file has no such chunk, the property is `nil`.
public struct WebPMetadata: Hashable, Sendable {
    /// The ICC color profile from the `ICCP` chunk. Without one, colors are sRGB.
    public let iccProfile: [UInt8]?

    /// The EXIF metadata from the `EXIF` chunk.
    public let exif: [UInt8]?

    /// The XMP metadata from the `XMP ` chunk.
    public let xmp: [UInt8]?

    /// Reads the color profile and metadata of a complete WebP file.
    ///
    /// - Parameter bytes: The contents of the file.
    /// - Throws: A ``WebPError`` if the data is not a valid WebP file.
    public init(parsing bytes: [UInt8]) throws(WebPError) {
        let parse: (UnsafeBufferPointer<UInt8>) throws(WebPError) -> WebPMetadata = { buffer throws(WebPError) in
            try unsafe WebPMetadata(parsing: buffer.span)
        }

        // Swift 6.3 requires this marker here, while Swift 6.4 reports it as unnecessary.
        #if compiler(>=6.4)
            self = try bytes.withUnsafeBufferPointer(parse)
        #else
            self = try unsafe bytes.withUnsafeBufferPointer(parse)
        #endif
    }

    /// Reads the color profile and metadata of a complete WebP file.
    ///
    /// - Parameter bytes: The contents of the file.
    /// - Throws: A ``WebPError`` if the data is not a valid WebP file.
    public init(parsing bytes: Span<UInt8>) throws(WebPError) {
        let locations = try WebPFileLayout(parsing: bytes).metadata
        iccProfile = locations.iccProfile.map { Self.copy($0, of: bytes) }
        exif = locations.exif.map { Self.copy($0, of: bytes) }
        xmp = locations.xmp.map { Self.copy($0, of: bytes) }
    }

    private static func copy(_ range: Range<Int>, of bytes: Span<UInt8>) -> [UInt8] {
        var payload: [UInt8] = []
        payload.reserveCapacity(range.count)
        for index in range {
            payload.append(bytes[index])
        }
        return payload
    }
}

/// The payloads of the first metadata chunk of each kind.
package struct MetadataLocations {
    package private(set) var iccProfile: Range<Int>?
    package private(set) var exif: Range<Int>?
    package private(set) var xmp: Range<Int>?

    /// Records a chunk if it is the first metadata chunk of its kind.
    mutating func record(_ chunk: RIFFChunk) {
        switch chunk.fourCC {
        case .iccp: iccProfile = iccProfile ?? chunk.payload
        case .exif: exif = exif ?? chunk.payload
        case .xmp: xmp = xmp ?? chunk.payload
        default: break
        }
    }
}
