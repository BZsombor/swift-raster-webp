/// A four-character RIFF chunk identifier.
struct FourCC: Hashable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init(_ a: Unicode.Scalar, _ b: Unicode.Scalar, _ c: Unicode.Scalar, _ d: Unicode.Scalar) {
        rawValue = a.value | b.value << 8 | c.value << 16 | d.value << 24
    }

    static var riff: FourCC { FourCC("R", "I", "F", "F") }
    static var webp: FourCC { FourCC("W", "E", "B", "P") }
    static var vp8: FourCC { FourCC("V", "P", "8", " ") }
    static var vp8l: FourCC { FourCC("V", "P", "8", "L") }
    static var vp8x: FourCC { FourCC("V", "P", "8", "X") }
    static var alph: FourCC { FourCC("A", "L", "P", "H") }
    static var anim: FourCC { FourCC("A", "N", "I", "M") }
    static var anmf: FourCC { FourCC("A", "N", "M", "F") }
    static var iccp: FourCC { FourCC("I", "C", "C", "P") }
    static var exif: FourCC { FourCC("E", "X", "I", "F") }
    static var xmp: FourCC { FourCC("X", "M", "P", " ") }
}

/// A chunk located inside the file's bytes.
struct RIFFChunk {
    let fourCC: FourCC
    let payload: Range<Int>
}

/// Walks consecutive RIFF chunks in a byte range.
struct RIFFChunkReader {
    private static var chunkHeaderSize: Int { 8 }
    private static var fileHeaderSize: Int { 12 }
    private static var maximumRIFFSize: UInt32 { 0xFFFF_FFF6 }

    private let end: Int
    private var offset: Int

    /// Creates a reader for the top-level chunks of a complete WebP file.
    init(file bytes: Span<UInt8>) throws(WebPError) {
        guard Self.hasPrefix(.riff, at: 0, in: bytes), Self.hasPrefix(.webp, at: 8, in: bytes) else {
            throw WebPError(.notWebP)
        }
        guard bytes.count >= Self.fileHeaderSize else {
            throw WebPError(.truncated)
        }

        let riffSize = bytes.littleEndianUInt32(at: 4)
        guard riffSize >= UInt32(Self.fileHeaderSize), riffSize <= Self.maximumRIFFSize else {
            throw WebPError(.invalidRIFFSize)
        }

        // Compare in 64 bits because `Int` is 32 bits wide on some supported platforms.
        let fileEnd = UInt64(riffSize) + UInt64(Self.chunkHeaderSize)
        guard fileEnd <= UInt64(bytes.count) else {
            throw WebPError(.truncated)
        }

        self.init(range: Self.fileHeaderSize..<Int(fileEnd))
    }

    /// Creates a reader for the chunks nested in `range`.
    init(range: Range<Int>) {
        offset = range.lowerBound
        end = range.upperBound
    }

    /// Returns the next chunk, or `nil` at the end of the range.
    mutating func next(in bytes: Span<UInt8>) throws(WebPError) -> RIFFChunk? {
        guard offset < end else {
            return nil
        }
        guard end - offset >= Self.chunkHeaderSize else {
            throw WebPError(.incompleteChunkHeader)
        }

        let fourCC = FourCC(rawValue: bytes.littleEndianUInt32(at: offset))
        let size = bytes.littleEndianUInt32(at: offset + 4)
        let payloadStart = offset + Self.chunkHeaderSize

        let payloadEnd = UInt64(payloadStart) + UInt64(size)
        guard payloadEnd <= UInt64(end) else {
            throw WebPError(.chunkExceedsContainer)
        }

        let payload = payloadStart..<Int(payloadEnd)

        // Chunks are padded to an even size, but some writers omit the final padding byte.
        offset = min(payload.upperBound + payload.count % 2, end)
        return RIFFChunk(fourCC: fourCC, payload: payload)
    }

    /// Returns whether the available bytes at `start` agree with `fourCC`.
    private static func hasPrefix(_ fourCC: FourCC, at start: Int, in bytes: Span<UInt8>) -> Bool {
        for index in 0..<4 where start + index < bytes.count {
            let expected = UInt8(truncatingIfNeeded: fourCC.rawValue >> UInt32(index * 8))
            guard bytes[start + index] == expected else {
                return false
            }
        }
        return true
    }
}
