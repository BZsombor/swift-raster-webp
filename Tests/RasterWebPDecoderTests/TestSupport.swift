import RasterWebP

/// Files produced by libwebp, generated with `webp-tools decoder-fixtures`.
enum Fixtures {
    static let all: [(name: String, bytes: [UInt8])] = [
        ("extended", PackageResources.extended_webp),
        ("gradient", PackageResources.gradient_webp),
        ("gradient_alpha", PackageResources.gradient_alpha_webp),
        ("mixed", PackageResources.mixed_webp),
        ("near_lossless", PackageResources.near_lossless_webp),
        ("noise", PackageResources.noise_webp),
        ("palette_16", PackageResources.palette_16_webp),
        ("palette_2", PackageResources.palette_2_webp),
        ("palette_256", PackageResources.palette_256_webp),
        ("palette_4", PackageResources.palette_4_webp),
    ]
}

/// A small deterministic generator, so that failures reproduce on every platform.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E62D
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func next(below bound: Int) -> Int {
        // Keep 31 bits so that the value stays positive where `Int` is 32 bits wide.
        Int(truncatingIfNeeded: next() >> 33) % bound
    }

    mutating func pixel() -> UInt32 {
        UInt32(truncatingIfNeeded: next())
    }
}

/// Hashes bytes with 64-bit FNV-1a, matching `webp-tools golden`.
func fnv1a(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in bytes {
        hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    return hash
}

/// Writes the least-significant-bit-first bitstream of a VP8L image.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var usedBits = 0

    mutating func write(_ value: UInt32, bits: Int) {
        for bit in 0..<bits {
            if usedBits == 0 {
                bytes.append(0)
            }
            bytes[bytes.count - 1] |= UInt8((value >> UInt32(bit)) & 1) << UInt8(usedBits)
            usedBits = (usedBits + 1) % 8
        }
    }

    /// Writes a canonical code word, whose most significant bit comes first in the stream.
    mutating func writeCode(_ code: UInt32, length: Int) {
        for bit in (0..<length).reversed() {
            write((code >> UInt32(bit)) & 1, bits: 1)
        }
    }

    /// Writes a prefix code that has one symbol below 256.
    mutating func writeSingleSymbolCode(_ symbol: UInt32) {
        write(1, bits: 1)
        write(0, bits: 1)
        write(1, bits: 1)
        write(symbol, bits: 8)
    }

    /// Writes a prefix code that has two symbols below 256.
    mutating func writeTwoSymbolCode(_ first: UInt32, _ second: UInt32) {
        write(1, bits: 1)
        write(1, bits: 1)
        write(1, bits: 1)
        write(first, bits: 8)
        write(second, bits: 8)
    }

    /// Writes a normal prefix code in which every symbol in `symbols` has the same length.
    mutating func writeUniformCode(symbols: Set<Int>, length: Int, alphabetSize: Int) {
        write(0, bits: 1)

        // The code length code has two one-bit codes: length zero and `length`.
        write(15, bits: 4)
        let order = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        for codeLength in order {
            write(codeLength == 0 || codeLength == length ? 1 : 0, bits: 3)
        }
        write(0, bits: 1)

        for symbol in 0..<alphabetSize {
            write(symbols.contains(symbol) ? 1 : 0, bits: 1)
        }
    }
}

/// Builds complete WebP files that contain handwritten VP8L bitstreams.
enum VP8LFile {
    static func make(width: Int, height: Int, body: (inout BitWriter) -> Void) -> [UInt8] {
        var writer = BitWriter()
        writer.write(UInt32(width - 1), bits: 14)
        writer.write(UInt32(height - 1), bits: 14)
        writer.write(1, bits: 1)
        writer.write(0, bits: 3)
        body(&writer)

        var payload: [UInt8] = [0x2F] + writer.bytes
        let payloadSize = UInt32(payload.count)
        if payload.count % 2 == 1 {
            payload.append(0)
        }
        let riffSize = UInt32(4 + 8 + payload.count)
        return Array("RIFF".utf8) + littleEndian(riffSize) + Array("WEBPVP8L".utf8)
            + littleEndian(payloadSize) + payload
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
    }
}

extension BitWriter {
    /// Writes the bits that declare no transforms, no color cache and no entropy image.
    mutating func writePlainImageHeader() {
        write(0, bits: 1)
        write(0, bits: 1)
        write(0, bits: 1)
    }

    /// Writes red, blue, alpha and distance codes that each have one symbol.
    mutating func writeConstantCodes(red: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 255, distance: UInt32 = 0) {
        writeSingleSymbolCode(red)
        writeSingleSymbolCode(blue)
        writeSingleSymbolCode(alpha)
        writeSingleSymbolCode(distance)
    }
}
