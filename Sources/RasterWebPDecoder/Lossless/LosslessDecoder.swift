internal import RasterWebPCore

/// Tracks the working memory that a decoding operation may still allocate.
struct MemoryBudget {
    private var remainingByteCount: Int

    init(limit: Int) {
        remainingByteCount = limit
    }

    /// Reserves memory for `count` elements of `elementSize` bytes.
    mutating func reserve(count: Int, elementSize: Int) throws(WebPError) {
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: elementSize)
        guard !overflow, byteCount <= remainingByteCount else {
            throw WebPError(.memoryLimitExceeded)
        }
        remainingByteCount -= byteCount
    }
}

/// Decodes a VP8L bitstream, as described in RFC 9649, section 3.
struct LosslessDecoder {
    private static let codeLengthCodeOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    private static var codeLengthCodeCount: Int { 19 }
    private static var literalAlphabetSize: Int { 256 }
    private static var distanceAlphabetSize: Int { 40 }
    private static var greenAlphabetBaseSize: Int { 256 + 24 }
    private static var maximumColorCacheBits: Int { 11 }
    private static var maximumAlphabetSize: Int { greenAlphabetBaseSize + 1 << maximumColorCacheBits }

    private var reader: BitReader
    private var budget: MemoryBudget
    private var builder = PrefixCodeBuilder()
    private var prefixTable: [UInt32] = []
    private var groups: [PrefixCodeGroup] = []
    private var codeLengths = [UInt8](repeating: 0, count: LosslessDecoder.maximumAlphabetSize)
    private var codeLengthCodeLengths = [UInt8](repeating: 0, count: LosslessDecoder.codeLengthCodeCount)
    private var codeLengthTable: [UInt32] = []

    /// Decodes a bitstream into `pixels`, which holds `width * height` ARGB values.
    ///
    /// - Parameter bitstream: The range of `input` that follows the 5-byte VP8L header.
    static func decode(
        input: Span<UInt8>,
        bitstream: Range<Int>,
        width: Int,
        height: Int,
        budget: MemoryBudget,
        into pixels: inout MutableSpan<UInt32>
    ) throws(WebPError) {
        var decoder = LosslessDecoder(reader: BitReader(range: bitstream), budget: budget)
        do throws(WebPError) {
            try decoder.decodeImage(input: input, width: width, height: height, pixels: &pixels)
        } catch {
            // Zero bits past the end of the data can look like an invalid stream.
            if decoder.reader.isTruncated, error.kind == .malformedBitstream {
                throw WebPError(.truncated)
            }
            throw error
        }
    }

    private init(reader: BitReader, budget: MemoryBudget) {
        self.reader = reader
        self.budget = budget
    }

    private mutating func decodeImage(
        input: Span<UInt8>,
        width: Int,
        height: Int,
        pixels: inout MutableSpan<UInt32>
    ) throws(WebPError) {
        var transforms: [InverseTransform] = []
        var transformedWidth = width
        var seenTransforms: UInt32 = 0

        while reader.read(1, input) == 1 {
            let type = reader.read(2, input)
            guard seenTransforms & (1 << type) == 0 else {
                throw WebPError(.vp8lDuplicateTransform)
            }
            seenTransforms |= 1 << type
            let transform = try readTransform(type: type, width: &transformedWidth, height: height, input: input)
            transforms.append(transform)
        }

        let colorCacheBits = try readColorCacheBits(input)

        var metaBits = 0
        var metaWidth = 0
        var metaImage: [UInt32] = []
        var groupCount = 1
        var usedGroups: [Bool] = []

        if reader.read(1, input) == 1 {
            metaBits = Int(reader.read(3, input)) + 2
            metaWidth = Self.subsampled(transformedWidth, bits: metaBits)
            let metaHeight = Self.subsampled(height, bits: metaBits)
            metaImage = try decodeSubimage(width: metaWidth, height: metaHeight, input: input)

            var largestGroup = 0
            for pixel in metaImage {
                largestGroup = max(largestGroup, Int((pixel >> 8) & 0xFFFF))
            }
            groupCount = largestGroup + 1

            try budget.reserve(count: groupCount, elementSize: 1)
            usedGroups = [Bool](repeating: false, count: groupCount)
            for pixel in metaImage {
                usedGroups[Int((pixel >> 8) & 0xFFFF)] = true
            }
        }

        try readPrefixCodeGroups(
            count: groupCount,
            usedGroups: usedGroups,
            colorCacheBits: colorCacheBits,
            input: input
        )
        try decodeEntropyImage(
            input: input,
            pixels: &pixels,
            width: transformedWidth,
            height: height,
            metaImage: metaImage,
            metaBits: metaBits,
            metaWidth: metaWidth,
            colorCacheBits: colorCacheBits
        )

        for transform in transforms.reversed() {
            transform.apply(to: &pixels, height: height)
        }
    }

    /// Reads the data of a transform and updates the width of the transformed image.
    private mutating func readTransform(
        type: UInt32,
        width: inout Int,
        height: Int,
        input: Span<UInt8>
    ) throws(WebPError) -> InverseTransform {
        switch type {
        case 0, 1:
            let blockBits = Int(reader.read(3, input)) + 2
            let columns = Self.subsampled(width, bits: blockBits)
            let rows = Self.subsampled(height, bits: blockBits)
            let data = try decodeSubimage(width: columns, height: rows, input: input)
            if type == 0 {
                return .predictor(blockBits: blockBits, blockColumns: columns, width: width, modes: data)
            }
            return .color(blockBits: blockBits, blockColumns: columns, width: width, elements: data)
        case 2:
            return .subtractGreen(width: width)
        default:
            let colorCount = Int(reader.read(8, input)) + 1
            let deltas = try decodeSubimage(width: colorCount, height: 1, input: input)

            // Indexes beyond the table must yield transparent black.
            try budget.reserve(count: 256, elementSize: MemoryLayout<UInt32>.stride)
            var colors = [UInt32](repeating: 0, count: 256)
            var color: UInt32 = 0
            for index in 0..<colorCount {
                color = InverseTransforms.add(color, deltas[index])
                colors[index] = color
            }

            let widthBits = colorCount <= 2 ? 3 : colorCount <= 4 ? 2 : colorCount <= 16 ? 1 : 0
            let outputWidth = width
            width = Self.subsampled(width, bits: widthBits)
            return .colorIndexing(widthBits: widthBits, packedWidth: width, width: outputWidth, colors: colors)
        }
    }

    /// Decodes an entropy-coded image that stores data for the main image.
    private mutating func decodeSubimage(
        width: Int,
        height: Int,
        input: Span<UInt8>
    ) throws(WebPError) -> [UInt32] {
        let colorCacheBits = try readColorCacheBits(input)
        try readPrefixCodeGroups(
            count: 1,
            usedGroups: [],
            colorCacheBits: colorCacheBits,
            input: input
        )

        let pixelCount = width * height
        try budget.reserve(count: pixelCount, elementSize: MemoryLayout<UInt32>.stride)
        var image = [UInt32](repeating: 0, count: pixelCount)

        try image.withMutableElementSpan { (pixels) throws(WebPError) in
            try decodeEntropyImage(
                input: input,
                pixels: &pixels,
                width: width,
                height: height,
                metaImage: [],
                metaBits: 0,
                metaWidth: 0,
                colorCacheBits: colorCacheBits
            )
        }
        return image
    }

    /// Decodes pixels with the prefix codes that were read most recently.
    private mutating func decodeEntropyImage(
        input: Span<UInt8>,
        pixels: inout MutableSpan<UInt32>,
        width: Int,
        height: Int,
        metaImage: [UInt32],
        metaBits: Int,
        metaWidth: Int,
        colorCacheBits: Int
    ) throws(WebPError) {
        let colorCacheSize = colorCacheBits > 0 ? 1 << colorCacheBits : 0
        try budget.reserve(count: colorCacheSize, elementSize: MemoryLayout<UInt32>.stride)
        var colorCacheStorage = [UInt32](repeating: 0, count: colorCacheSize)

        var localReader = reader
        defer { reader = localReader }

        try prefixTable.withElementSpan { (table) throws(WebPError) in
            try groups.withElementSpan { (groups) throws(WebPError) in
                try metaImage.withElementSpan { (metaImage) throws(WebPError) in
                    try colorCacheStorage.withMutableElementSpan { (colorCache) throws(WebPError) in
                        try EntropyImage.decode(
                            input: input,
                            reader: &localReader,
                            pixels: &pixels,
                            width: width,
                            height: height,
                            prefixTable: table,
                            groups: groups,
                            metaImage: metaImage,
                            metaBits: metaBits,
                            metaWidth: metaWidth,
                            colorCache: &colorCache,
                            colorCacheBits: colorCacheBits
                        )
                    }
                }
            }
        }
    }

    /// Reads the size of the color cache, where zero means that no cache is used.
    private mutating func readColorCacheBits(_ input: Span<UInt8>) throws(WebPError) -> Int {
        guard reader.read(1, input) == 1 else {
            return 0
        }
        let bits = Int(reader.read(4, input))
        guard (1...Self.maximumColorCacheBits).contains(bits) else {
            throw WebPError(.vp8lInvalidColorCacheSize)
        }
        return bits
    }

    /// Reads every prefix code group and builds tables for the groups that are in use.
    ///
    /// - Parameter usedGroups: The groups the entropy image refers to, or empty if all are in use.
    private mutating func readPrefixCodeGroups(
        count: Int,
        usedGroups: [Bool],
        colorCacheBits: Int,
        input: Span<UInt8>
    ) throws(WebPError) {
        let colorCacheSize = colorCacheBits > 0 ? 1 << colorCacheBits : 0
        let greenAlphabetSize = Self.greenAlphabetBaseSize + colorCacheSize

        try budget.reserve(count: count, elementSize: MemoryLayout<PrefixCodeGroup>.stride)
        prefixTable.removeAll(keepingCapacity: true)
        groups.removeAll(keepingCapacity: true)
        groups.reserveCapacity(count)
        var reservedTableEntries = 0

        for index in 0..<count {
            let isUsed = usedGroups.isEmpty || usedGroups[index]
            var group = PrefixCodeGroup()
            group.green = try readPrefixCode(alphabetSize: greenAlphabetSize, build: isUsed, input: input)
            group.red = try readPrefixCode(alphabetSize: Self.literalAlphabetSize, build: isUsed, input: input)
            group.blue = try readPrefixCode(alphabetSize: Self.literalAlphabetSize, build: isUsed, input: input)
            group.alpha = try readPrefixCode(alphabetSize: Self.literalAlphabetSize, build: isUsed, input: input)
            group.distance = try readPrefixCode(alphabetSize: Self.distanceAlphabetSize, build: isUsed, input: input)

            if isUsed, group.red.isSingleSymbol, group.blue.isSingleSymbol, group.alpha.isSingleSymbol {
                let red = prefixTable[Int(group.red.tableOffset)] >> 16
                let blue = prefixTable[Int(group.blue.tableOffset)] >> 16
                let alpha = prefixTable[Int(group.alpha.tableOffset)] >> 16
                group.constantLiteralBits = alpha << 24 | red << 16 | blue
                group.hasConstantLiteralBits = true
            }
            groups.append(group)

            // Charge the tables as they grow, because each group can add thousands of entries.
            let newEntries = prefixTable.count - reservedTableEntries
            try budget.reserve(count: newEntries, elementSize: MemoryLayout<UInt32>.stride)
            reservedTableEntries = prefixTable.count
        }
    }

    /// Reads the code lengths of one prefix code and optionally builds its lookup table.
    private mutating func readPrefixCode(
        alphabetSize: Int,
        build: Bool,
        input: Span<UInt8>
    ) throws(WebPError) -> PrefixCode {
        for symbol in 0..<alphabetSize {
            codeLengths[symbol] = 0
        }

        if reader.read(1, input) == 1 {
            try readSimpleCodeLengths(alphabetSize: alphabetSize, input: input)
        } else {
            try readNormalCodeLengths(alphabetSize: alphabetSize, input: input)
        }
        guard !reader.isTruncated else {
            throw WebPError(.truncated)
        }

        let shape = try PrefixCodeBuilder.validate(codeLengths, symbolCount: alphabetSize)
        guard build else {
            return PrefixCode()
        }
        return builder.build(codeLengths, symbolCount: alphabetSize, shape: shape, into: &prefixTable)
    }

    /// Reads a code that has one or two symbols.
    private mutating func readSimpleCodeLengths(
        alphabetSize: Int,
        input: Span<UInt8>
    ) throws(WebPError) {
        let symbolCount = reader.read(1, input) + 1
        let firstSymbolBits = reader.read(1, input) == 1 ? 8 : 1
        let first = Int(reader.read(firstSymbolBits, input))
        guard first < alphabetSize else {
            throw WebPError(.vp8lInvalidCodeLengths)
        }
        codeLengths[first] = 1

        if symbolCount == 2 {
            let second = Int(reader.read(8, input))
            guard second < alphabetSize else {
                throw WebPError(.vp8lInvalidCodeLengths)
            }
            codeLengths[second] = 1
        }
    }

    /// Reads code lengths that are themselves prefix coded.
    private mutating func readNormalCodeLengths(
        alphabetSize: Int,
        input: Span<UInt8>
    ) throws(WebPError) {
        for symbol in 0..<Self.codeLengthCodeCount {
            codeLengthCodeLengths[symbol] = 0
        }
        let order = Self.codeLengthCodeOrder
        let codeCount = Int(reader.read(4, input)) + 4
        for index in 0..<codeCount {
            codeLengthCodeLengths[order[index]] = UInt8(reader.read(3, input))
        }

        let shape = try PrefixCodeBuilder.validate(codeLengthCodeLengths, symbolCount: Self.codeLengthCodeCount)
        codeLengthTable.removeAll(keepingCapacity: true)
        let code = builder.build(
            codeLengthCodeLengths,
            symbolCount: Self.codeLengthCodeCount,
            shape: shape,
            into: &codeLengthTable
        )

        var remainingTokens = alphabetSize
        if reader.read(1, input) == 1 {
            let lengthBits = 2 + 2 * Int(reader.read(3, input))
            remainingTokens = 2 + Int(reader.read(lengthBits, input))
            guard remainingTokens <= alphabetSize else {
                throw WebPError(.vp8lInvalidCodeLengths)
            }
        }

        var symbol = 0
        var previousLength: UInt8 = 8
        while symbol < alphabetSize, remainingTokens > 0 {
            remainingTokens -= 1
            reader.refill(input)

            // Code length codes are at most 7 bits long, so they never use a secondary table.
            let entry = codeLengthTable[Int(reader.peek & code.rootMask)]
            reader.consume(Int(entry & 0xFF))
            let token = Int(entry >> 16)

            if token < 16 {
                codeLengths[symbol] = UInt8(token)
                symbol += 1
                if token != 0 {
                    previousLength = UInt8(token)
                }
                continue
            }

            let extraBits = token == 16 ? 2 : token == 17 ? 3 : 7
            let base = token == 18 ? 11 : 3
            let repeatCount = base + Int(reader.read(extraBits, input))
            guard repeatCount <= alphabetSize - symbol else {
                throw WebPError(.vp8lInvalidCodeLengths)
            }
            let length = token == 16 ? previousLength : 0
            for _ in 0..<repeatCount {
                codeLengths[symbol] = length
                symbol += 1
            }
        }
    }

    /// Divides a size by a power of two, rounding up.
    private static func subsampled(_ size: Int, bits: Int) -> Int {
        (size + (1 << bits) - 1) >> bits
    }
}
