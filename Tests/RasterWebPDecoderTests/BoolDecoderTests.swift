import Testing

@testable import RasterWebPDecoder

/// The boolean entropy encoder of RFC 6386, section 7.3, written from its description.
///
/// It keeps the low end of the coded interval in `bottom`, writes a byte whenever 8 more bits
/// are decided, and propagates carries into the bytes already written.
struct BoolEncoder {
    private(set) var bytes: [UInt8] = []
    private var range: UInt32 = 255
    private var bottom: UInt32 = 0
    private var bitCount = 24

    mutating func write(_ bit: Bool, probability: Int) {
        let split = 1 + (((range - 1) * UInt32(probability)) >> 8)
        if bit {
            bottom &+= split
            range -= split
        } else {
            range = split
        }
        while range < 128 {
            range <<= 1
            if bottom & (1 << 31) != 0 {
                propagateCarry()
            }
            bottom <<= 1
            bitCount -= 1
            if bitCount == 0 {
                bytes.append(UInt8(truncatingIfNeeded: bottom >> 24))
                bottom &= (1 << 24) - 1
                bitCount = 8
            }
        }
    }

    mutating func writeLiteral(_ value: Int, bits: Int) {
        for bit in (0..<bits).reversed() {
            write((value >> bit) & 1 == 1, probability: 128)
        }
    }

    /// Writes enough even-probability zeros to push every decided bit into the output.
    mutating func flush() {
        for _ in 0..<32 {
            write(false, probability: 128)
        }
    }

    private mutating func propagateCarry() {
        var index = bytes.count - 1
        while index >= 0, bytes[index] == 255 {
            bytes[index] = 0
            index -= 1
        }
        bytes[index] += 1
    }
}

@Suite("VP8 boolean decoder")
struct BoolDecoderTests {
    @Test func decodesWhatTheEncoderWrote() {
        var generator = SplitMix64(state: 0x424F_4F4C)
        for trial in 0..<300 {
            let count = 1 + generator.next(below: trial % 10 == 0 ? 20_000 : 300)
            // Skewed probabilities with matching bits exercise long runs without renormalization.
            let skewed = trial % 3 == 0
            var symbols: [(bit: Bool, probability: Int)] = []
            for _ in 0..<count {
                let probability = skewed ? 250 + generator.next(below: 6) : 1 + generator.next(below: 255)
                let bit = skewed ? generator.next(below: 64) == 0 : generator.next(below: 2) == 0
                symbols.append((bit, probability))
            }

            var encoder = BoolEncoder()
            for symbol in symbols {
                encoder.write(symbol.bit, probability: symbol.probability)
            }
            encoder.flush()

            let bytes = encoder.bytes
            bytes.withElementSpan { input in
                var decoder = BoolDecoder(range: 0..<input.count)
                var matches = true
                for symbol in symbols where decoder.read(UInt32(symbol.probability), input) != symbol.bit {
                    matches = false
                    break
                }
                #expect(matches, "trial \(trial)")
                #expect(!decoder.isPastEnd)
            }
        }
    }

    @Test func readsLiteralsAndSignedValues() {
        var encoder = BoolEncoder()
        encoder.writeLiteral(0x5A, bits: 7)
        // A signed value is its magnitude followed by a sign flag.
        encoder.writeLiteral(13, bits: 4)
        encoder.write(true, probability: 128)
        // An optional value is a presence flag followed by the value.
        encoder.write(false, probability: 128)
        encoder.write(true, probability: 128)
        encoder.writeLiteral(9, bits: 6)
        encoder.write(false, probability: 128)
        encoder.flush()

        encoder.bytes.withElementSpan { input in
            var decoder = BoolDecoder(range: 0..<input.count)
            #expect(decoder.readLiteral(7, input) == 0x5A)
            #expect(decoder.readSigned(4, input) == -13)
            #expect(decoder.readOptionalSigned(6, input) == 0)
            #expect(decoder.readOptionalSigned(6, input) == 9)
            #expect(!decoder.isPastEnd)
        }
    }

    @Test func readingFarPastTheEndIsReported() {
        let bytes: [UInt8] = [0x12, 0x34, 0x56]
        bytes.withElementSpan { input in
            var decoder = BoolDecoder(range: 0..<input.count)
            for _ in 0..<24 {
                _ = decoder.readFlag(input)
            }
            #expect(!decoder.isPastEnd)
            for _ in 0..<64 {
                _ = decoder.readFlag(input)
            }
            #expect(decoder.isPastEnd)
        }
    }

    @Test func emptyPartitionsDecodeAsZeros() {
        let bytes: [UInt8] = [0xFF]
        bytes.withElementSpan { input in
            // The partition is empty even though the input has a byte after it.
            var decoder = BoolDecoder(range: 1..<1)
            #expect(decoder.readLiteral(8, input) == 0)
        }
    }
}
