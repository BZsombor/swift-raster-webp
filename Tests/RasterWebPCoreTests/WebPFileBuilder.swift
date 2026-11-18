/// Builds minimal WebP files for tests.
enum WebPFileBuilder {
    static func file(_ chunks: [UInt8]...) -> [UInt8] {
        let body = Array("WEBP".utf8) + chunks.flatMap { $0 }
        return Array("RIFF".utf8) + littleEndian(UInt32(body.count), byteCount: 4) + body
    }

    static func chunk(_ fourCC: String, _ payload: [UInt8]) -> [UInt8] {
        let padding: [UInt8] = payload.count.isMultiple(of: 2) ? [] : [0]
        return Array(fourCC.utf8) + littleEndian(UInt32(payload.count), byteCount: 4) + payload + padding
    }

    static func vp8Payload(width: Int, height: Int, frameTag: UInt32 = 1 << 4 | 1 << 5) -> [UInt8] {
        littleEndian(frameTag, byteCount: 3) + [0x9D, 0x01, 0x2A]
            + littleEndian(UInt32(width), byteCount: 2)
            + littleEndian(UInt32(height), byteCount: 2)
    }

    static func vp8(width: Int, height: Int) -> [UInt8] {
        chunk("VP8 ", vp8Payload(width: width, height: height))
    }

    static func vp8lPayload(width: Int, height: Int, alpha: Bool = false, version: UInt32 = 0) -> [UInt8] {
        let alphaBit: UInt32 = alpha ? 1 : 0
        let fields = UInt32(width - 1) | UInt32(height - 1) << 14 | alphaBit << 28 | version << 29
        return [0x2F] + littleEndian(fields, byteCount: 4)
    }

    static func vp8l(width: Int, height: Int, alpha: Bool = false) -> [UInt8] {
        chunk("VP8L", vp8lPayload(width: width, height: height, alpha: alpha))
    }

    static func vp8x(width: Int, height: Int, flags: UInt8 = 0) -> [UInt8] {
        let payload: [UInt8] =
            [flags, 0, 0, 0]
            + littleEndian(UInt32(width - 1), byteCount: 3)
            + littleEndian(UInt32(height - 1), byteCount: 3)
        return chunk("VP8X", payload)
    }

    static func anim(loopCount: UInt16 = 0) -> [UInt8] {
        chunk("ANIM", [1, 2, 3, 4] + littleEndian(UInt32(loopCount), byteCount: 2))
    }

    static func anmf(x: Int = 0, y: Int = 0, width: Int, height: Int, image: [UInt8]) -> [UInt8] {
        let position = littleEndian(UInt32(x / 2), byteCount: 3) + littleEndian(UInt32(y / 2), byteCount: 3)
        let size = littleEndian(UInt32(width - 1), byteCount: 3) + littleEndian(UInt32(height - 1), byteCount: 3)
        let timing = littleEndian(100, byteCount: 3) + [0]
        return chunk("ANMF", position + size + timing + image)
    }

    static func littleEndian(_ value: UInt32, byteCount: Int) -> [UInt8] {
        (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
    }
}

enum VP8XFlags {
    static let alpha: UInt8 = 0x10
    static let animation: UInt8 = 0x02
}
