internal import RasterWebPCore

/// The location of one prefix code in a flat lookup table.
///
/// Each table entry stores the code length in its low 8 bits and a value in its high 16 bits.
/// An entry in the root table with a length above ``rootBits`` refers to a secondary table.
/// Its value is the secondary table's offset from the root, and its length is `rootBits` plus
/// the secondary table's index width.
struct PrefixCode: BitwiseCopyable {
    /// The largest number of index bits in a root table.
    static var rootBits: Int { 8 }

    /// The longest code length that the format allows.
    static var maximumCodeLength: Int { 15 }

    var tableOffset: UInt32 = 0
    var rootMask: UInt32 = 0

    /// Whether this code always yields one symbol without consuming any bits.
    var isSingleSymbol: Bool {
        rootMask == 0
    }

    /// Decodes one symbol. The reader must hold at least ``maximumCodeLength`` bits.
    @inline(always)
    func decode(_ reader: inout BitReader, table: Span<UInt32>) -> Int {
        let bits = reader.peek
        let root = Int(truncatingIfNeeded: tableOffset)
        var entry = table[root &+ Int(truncatingIfNeeded: bits & rootMask)]
        var length = entry & 0xFF

        if length > 8 {
            let indexMask = (UInt32(1) &<< (length &- 8)) &- 1
            let index = (bits &>> 8) & indexMask
            entry = table[root &+ Int(truncatingIfNeeded: entry &>> 16) &+ Int(truncatingIfNeeded: index)]
            length = entry & 0xFF
        }

        reader.consume(Int(truncatingIfNeeded: length))
        return Int(truncatingIfNeeded: entry &>> 16)
    }
}

/// Builds prefix code lookup tables from code lengths.
struct PrefixCodeBuilder {
    /// The shape of a validated set of code lengths.
    struct Shape: Equatable {
        /// The only symbol of a single-symbol code.
        var singleSymbol: Int?

        /// The longest code length in use.
        var longestCode = 0
    }

    private var lengthCounts = [UInt16](repeating: 0, count: PrefixCode.maximumCodeLength + 1)
    private var firstCodes = [UInt16](repeating: 0, count: PrefixCode.maximumCodeLength + 1)
    private var nextCodes = [UInt16](repeating: 0, count: PrefixCode.maximumCodeLength + 1)
    private var secondaryBits = [UInt8](repeating: 0, count: 1 << PrefixCode.rootBits)
    private var secondaryOffsets = [Int](repeating: 0, count: 1 << PrefixCode.rootBits)

    /// Checks that the code lengths describe a complete binary tree.
    ///
    /// Tables are only written after this check succeeds, so an invalid code can never
    /// produce a table larger than the space computed for it.
    static func validate(_ codeLengths: [UInt8], symbolCount: Int) throws(WebPError) -> Shape {
        var shape = Shape()
        var usedSymbolCount = 0
        var remainingCodeSpace = 1 << PrefixCode.maximumCodeLength

        for symbol in 0..<symbolCount {
            let length = Int(codeLengths[symbol])
            guard length != 0 else {
                continue
            }
            guard length <= PrefixCode.maximumCodeLength else {
                throw WebPError(.vp8lInvalidPrefixCode)
            }
            usedSymbolCount += 1
            shape.singleSymbol = symbol
            shape.longestCode = max(shape.longestCode, length)
            remainingCodeSpace -= 1 << (PrefixCode.maximumCodeLength - length)
        }

        // A single leaf is complete regardless of the length recorded for it.
        if usedSymbolCount == 1 {
            return shape
        }
        guard usedSymbolCount > 1, remainingCodeSpace == 0 else {
            throw WebPError(.vp8lInvalidPrefixCode)
        }
        shape.singleSymbol = nil
        return shape
    }

    /// Appends the lookup table for validated code lengths to `table`.
    mutating func build(
        _ codeLengths: [UInt8],
        symbolCount: Int,
        shape: Shape,
        into table: inout [UInt32]
    ) -> PrefixCode {
        let offset = table.count

        if let symbol = shape.singleSymbol {
            table.append(UInt32(truncatingIfNeeded: symbol) << 16)
            return PrefixCode(tableOffset: UInt32(truncatingIfNeeded: offset), rootMask: 0)
        }

        let rootBits = min(shape.longestCode, PrefixCode.rootBits)
        let rootSize = 1 << rootBits
        assignFirstCodes(codeLengths, symbolCount: symbolCount)

        let tableSize = reserveSecondaryTables(
            codeLengths,
            symbolCount: symbolCount,
            rootBits: rootBits
        )
        table.append(contentsOf: repeatElement(0, count: tableSize))

        for root in 0..<rootSize where secondaryBits[root] > 0 {
            let length = UInt32(rootBits) + UInt32(secondaryBits[root])
            table[offset + root] = UInt32(truncatingIfNeeded: secondaryOffsets[root]) << 16 | length
        }

        // Replicate each symbol over every index that ends with its reversed code.
        nextCodes = firstCodes
        for symbol in 0..<symbolCount {
            let length = Int(codeLengths[symbol])
            guard length > 0 else {
                continue
            }
            let reversed = Self.reverseBits(nextCodes[length], length: length)
            nextCodes[length] &+= 1
            let entry = UInt32(truncatingIfNeeded: symbol) << 16 | UInt32(length)

            if length <= rootBits {
                var index = reversed
                while index < rootSize {
                    table[offset + index] = entry
                    index += 1 << length
                }
            } else {
                let root = reversed & (rootSize - 1)
                let secondary = offset + secondaryOffsets[root]
                let secondarySize = 1 << Int(secondaryBits[root])
                var index = reversed >> rootBits
                while index < secondarySize {
                    table[secondary + index] = entry
                    index += 1 << (length - rootBits)
                }
            }
        }

        return PrefixCode(
            tableOffset: UInt32(truncatingIfNeeded: offset),
            rootMask: UInt32(truncatingIfNeeded: rootSize - 1)
        )
    }

    /// Computes the first canonical code of each length.
    private mutating func assignFirstCodes(_ codeLengths: [UInt8], symbolCount: Int) {
        for length in lengthCounts.indices {
            lengthCounts[length] = 0
        }
        for symbol in 0..<symbolCount {
            lengthCounts[Int(codeLengths[symbol])] += 1
        }
        lengthCounts[0] = 0

        var code: UInt16 = 0
        for length in 1...PrefixCode.maximumCodeLength {
            code = (code &+ lengthCounts[length - 1]) &<< 1
            firstCodes[length] = code
        }
    }

    /// Lays out the secondary tables and returns the size of the whole table.
    private mutating func reserveSecondaryTables(
        _ codeLengths: [UInt8],
        symbolCount: Int,
        rootBits: Int
    ) -> Int {
        let rootSize = 1 << rootBits
        for root in 0..<rootSize {
            secondaryBits[root] = 0
        }

        nextCodes = firstCodes
        for symbol in 0..<symbolCount {
            let length = Int(codeLengths[symbol])
            guard length > 0 else {
                continue
            }
            let reversed = Self.reverseBits(nextCodes[length], length: length)
            nextCodes[length] &+= 1
            if length > rootBits {
                let root = reversed & (rootSize - 1)
                secondaryBits[root] = max(secondaryBits[root], UInt8(length - rootBits))
            }
        }

        var tableSize = rootSize
        for root in 0..<rootSize where secondaryBits[root] > 0 {
            secondaryOffsets[root] = tableSize
            tableSize += 1 << Int(secondaryBits[root])
        }
        return tableSize
    }

    /// Reverses the lowest `length` bits of a code.
    private static func reverseBits(_ code: UInt16, length: Int) -> Int {
        var value = code
        value = (value & 0x5555) << 1 | (value >> 1) & 0x5555
        value = (value & 0x3333) << 2 | (value >> 2) & 0x3333
        value = (value & 0x0F0F) << 4 | (value >> 4) & 0x0F0F
        value = value.byteSwapped
        return Int(value >> UInt16(16 - length))
    }
}

/// The five prefix codes that decode one block of pixels.
struct PrefixCodeGroup: BitwiseCopyable {
    var green = PrefixCode()
    var red = PrefixCode()
    var blue = PrefixCode()
    var alpha = PrefixCode()
    var distance = PrefixCode()

    /// The red, blue and alpha bits of every literal when those three codes are single symbols.
    var constantLiteralBits: UInt32 = 0
    var hasConstantLiteralBits = false
}
