import Testing

@testable import RasterWebPDecoder

@Suite("Prefix codes")
struct PrefixCodeTests {
    private func lengths(_ values: [UInt8]) -> [UInt8] {
        values
    }

    @Test func completeCodesAreAccepted() throws {
        let shape = try PrefixCodeBuilder.validate([1, 2, 3, 3], symbolCount: 4)
        #expect(shape.singleSymbol == nil)
        #expect(shape.longestCode == 3)
    }

    @Test(arguments: [UInt8(1), 3, 15])
    func singleLeafIsAcceptedWithAnyLength(length: UInt8) throws {
        let shape = try PrefixCodeBuilder.validate([0, length, 0], symbolCount: 3)
        #expect(shape.singleSymbol == 1)
    }

    @Test(arguments: [
        [UInt8(0), 0, 0],  // No symbols.
        [1, 1, 1],  // Oversubscribed.
        [1, 2, 2, 2],  // Oversubscribed.
        [2, 2, 2],  // Incomplete.
        [1, 3],  // Incomplete.
        [16, 16],  // Longer than the format allows.
    ])
    func invalidCodesAreRejected(codeLengths: [UInt8]) {
        #expect(throws: (any Error).self) {
            try PrefixCodeBuilder.validate(codeLengths, symbolCount: codeLengths.count)
        }
    }

    @Test func singleSymbolCodeConsumesNoBits() throws {
        let codeLengths: [UInt8] = [0, 0, 1]
        let shape = try PrefixCodeBuilder.validate(codeLengths, symbolCount: 3)
        var builder = PrefixCodeBuilder()
        var table: [UInt32] = []
        let code = builder.build(codeLengths, symbolCount: 3, shape: shape, into: &table)

        #expect(code.isSingleSymbol)
        #expect(table.count == 1)
    }

    /// Creates code lengths for a random complete binary tree.
    private func randomCompleteLengths(symbolCount: Int, generator: inout SplitMix64) -> [UInt8] {
        var leaves = [0]
        while leaves.count < symbolCount {
            let index = generator.next(below: leaves.count)
            guard leaves[index] < 15 else {
                continue
            }
            leaves[index] += 1
            leaves.append(leaves[index])
        }

        var codeLengths = [UInt8](repeating: 0, count: symbolCount + generator.next(below: 8))
        var positions = Array(codeLengths.indices)
        for depth in leaves {
            let position = positions.remove(at: generator.next(below: positions.count))
            codeLengths[position] = UInt8(depth)
        }
        return codeLengths
    }

    /// Assigns canonical codes as described by the format, independently of the decoder.
    private func canonicalCodes(_ codeLengths: [UInt8]) -> [(code: UInt32, length: Int)?] {
        let ordered = codeLengths.indices
            .filter { codeLengths[$0] > 0 }
            .sorted { (codeLengths[$0], $0) < (codeLengths[$1], $1) }

        var codes = [(code: UInt32, length: Int)?](repeating: nil, count: codeLengths.count)
        var code: UInt32 = 0
        var previousLength = 0
        for symbol in ordered {
            let length = Int(codeLengths[symbol])
            code <<= UInt32(length - previousLength)
            codes[symbol] = (code, length)
            code += 1
            previousLength = length
        }
        return codes
    }

    @Test func randomCodesDecodeEverySymbol() throws {
        var generator = SplitMix64(state: 0x434F_4445)

        for _ in 0..<200 {
            let symbolCount = 2 + generator.next(below: 600)
            let codeLengths = randomCompleteLengths(symbolCount: symbolCount, generator: &generator)
            let codes = canonicalCodes(codeLengths)
            let symbols = codeLengths.indices.filter { codeLengths[$0] > 0 }

            var writer = BitWriter()
            var expected: [Int] = []
            for _ in 0..<2_000 {
                let symbol = symbols[generator.next(below: symbols.count)]
                let entry = try #require(codes[symbol])
                writer.writeCode(entry.code, length: entry.length)
                expected.append(symbol)
            }

            let shape = try PrefixCodeBuilder.validate(codeLengths, symbolCount: codeLengths.count)
            var builder = PrefixCodeBuilder()
            var table: [UInt32] = []
            let code = builder.build(codeLengths, symbolCount: codeLengths.count, shape: shape, into: &table)

            let decoded: [Int] = writer.bytes.withUnsafeBufferPointer { input in
                table.withUnsafeBufferPointer { table in
                    var reader = BitReader(range: 0..<input.count)
                    return expected.indices.map { _ in
                        reader.refill(input.span)
                        return code.decode(&reader, table: table.span)
                    }
                }
            }
            #expect(decoded == expected)
        }
    }
}

@Suite("Bit reader")
struct BitReaderTests {
    @Test func readsLeastSignificantBitsFirst() {
        let bytes: [UInt8] = [0b1010_0110, 0xFF, 0x01]
        bytes.withUnsafeBufferPointer { buffer in
            var reader = BitReader(range: 0..<buffer.count)
            #expect(reader.read(1, buffer.span) == 0)
            #expect(reader.read(2, buffer.span) == 0b11)
            #expect(reader.read(5, buffer.span) == 0b10100)
            #expect(reader.read(9, buffer.span) == 0b1_1111_1111)
            #expect(!reader.isTruncated)
        }
    }

    @Test func randomReadSequencesMatchTheWrittenValues() {
        var generator = SplitMix64(state: 0x4249_5453)
        var writer = BitWriter()
        var expected: [(value: UInt32, bits: Int)] = []
        for _ in 0..<5_000 {
            let bits = 1 + generator.next(below: 32)
            let mask = bits == 32 ? UInt32.max : (1 << UInt32(bits)) - 1
            let value = generator.pixel() & mask
            writer.write(value, bits: bits)
            expected.append((value, bits))
        }

        writer.bytes.withUnsafeBufferPointer { buffer in
            var reader = BitReader(range: 0..<buffer.count)
            for item in expected {
                #expect(reader.read(item.bits, buffer.span) == item.value)
            }
            #expect(!reader.isTruncated)
        }
    }

    @Test func readingPastTheEndIsReported() {
        let bytes: [UInt8] = [0xFF, 0xFF]
        bytes.withUnsafeBufferPointer { buffer in
            var reader = BitReader(range: 0..<buffer.count)
            #expect(reader.read(16, buffer.span) == 0xFFFF)
            #expect(!reader.isTruncated)
            #expect(reader.read(1, buffer.span) == 0)
            #expect(reader.isTruncated)
        }
    }

    @Test func readerStopsAtTheEndOfItsRange() {
        let bytes = [UInt8](repeating: 0xFF, count: 32)
        bytes.withUnsafeBufferPointer { buffer in
            var reader = BitReader(range: 4..<6)
            #expect(reader.read(16, buffer.span) == 0xFFFF)
            #expect(reader.read(8, buffer.span) == 0)
            #expect(reader.isTruncated)
        }
    }
}
