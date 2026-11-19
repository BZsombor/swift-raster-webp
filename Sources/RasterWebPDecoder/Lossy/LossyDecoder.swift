internal import RasterWebPCore

/// The decoded Y, U and V planes of a VP8 frame, padded to whole macroblocks.
struct YUVPlanes {
    var y: [UInt8]
    var u: [UInt8]
    var v: [UInt8]
    let lumaStride: Int
    let chromaStride: Int
    let width: Int
    let height: Int
}

/// The location of rows that the VP8 decoder hands over once they are final.
struct DecodedRows {
    /// The index of the first luma value in the luma rows.
    let lumaStart: Int
    /// The index of the first value in the chroma rows.
    let chromaStart: Int
    let lumaStride: Int
    let chromaStride: Int
    /// The image row of the first luma row, which is always even.
    let firstRow: Int
    /// The number of luma rows, which is always even. There are half as many chroma rows.
    let rowCount: Int
}

/// The rows that the VP8 decoder keeps in memory.
struct RowCaches {
    /// The macroblock row being decoded, preceded by the last rows of the previous one.
    var luma: [UInt8]
    var u: [UInt8]
    var v: [UInt8]
    /// The unfiltered bottom rows of the previous macroblock row, which predictions use.
    var lumaAbove: [UInt8]
    var uAbove: [UInt8]
    var vAbove: [UInt8]
}

/// Decodes a VP8 key frame, as described in RFC 6386.
struct LossyDecoder {
    private static var frameHeaderSize: Int { 10 }
    private static var coefficientCount: Int { 25 * 16 }
    private static var secondOrderBlock: Int { 24 * 16 }

    /// Decodes the frame in the payload of a `VP8 ` chunk.
    ///
    /// Rows go to `deliver` from top to bottom as soon as the loop filter no longer changes them,
    /// so only a few macroblock rows are kept in memory. Rows below the image may be included,
    /// because the frame is padded to whole macroblocks.
    static func decode(
        input: Span<UInt8>,
        payload: Range<Int>,
        width: Int,
        height: Int,
        budget: inout MemoryBudget,
        deliver: (Span<UInt8>, Span<UInt8>, Span<UInt8>, DecodedRows) -> Void
    ) throws(WebPError) {
        let start = payload.lowerBound
        let frameTag = Int(input[start]) | Int(input[start + 1]) << 8 | Int(input[start + 2]) << 16
        let firstPartitionSize = frameTag >> 5
        let firstPartitionStart = start + frameHeaderSize
        guard firstPartitionSize <= payload.upperBound - firstPartitionStart else {
            throw WebPError(.vp8InvalidPartitions)
        }

        var headerDecoder = BoolDecoder(range: firstPartitionStart..<(firstPartitionStart + firstPartitionSize))
        let header = FrameHeader(decoder: &headerDecoder, input: input)
        let partitions = try tokenPartitions(
            count: header.partitionCount,
            start: firstPartitionStart + firstPartitionSize,
            end: payload.upperBound,
            input: input
        )

        let macroblockColumns = (width + 15) / 16
        let macroblockRows = (height + 15) / 16
        let lumaStride = macroblockColumns * 16
        let chromaStride = macroblockColumns * 8

        // The normal filter reads 4 rows above a macroblock edge and the simple filter 2, so the
        // cache keeps that many rows of the previous macroblock row, rounded up to keep chroma
        // rows aligned with luma rows.
        let extraRows = header.filterLevel == 0 ? 0 : header.usesSimpleFilter ? 2 : 8
        let lumaCount = (extraRows + 16) * lumaStride
        let chromaCount = (extraRows / 2 + 8) * chromaStride
        try budget.reserve(
            count: lumaCount + 2 * chromaCount + lumaStride + 2 * chromaStride + macroblockColumns,
            elementSize: 1
        )

        var filterInfo = [UInt8](repeating: 0, count: macroblockColumns)

        var decoder = LossyDecoder(
            header: header,
            headerDecoder: headerDecoder,
            tokenDecoders: partitions.map { BoolDecoder(range: $0) },
            macroblockColumns: macroblockColumns,
            macroblockRows: macroblockRows,
            extraRows: extraRows
        )

        var caches = RowCaches(
            luma: [UInt8](repeating: 0, count: lumaCount),
            u: [UInt8](repeating: 0, count: chromaCount),
            v: [UInt8](repeating: 0, count: chromaCount),
            lumaAbove: [UInt8](repeating: 0, count: lumaStride),
            uAbove: [UInt8](repeating: 0, count: chromaStride),
            vAbove: [UInt8](repeating: 0, count: chromaStride)
        )

        try filterInfo.withMutableElementSpan { (filterInfo) throws(WebPError) in
            try decoder.decodeMacroblocks(input: input, caches: &caches, filterInfo: &filterInfo, deliver: deliver)
        }
    }

    /// Decodes the frame into whole planes, which the tests compare with libwebp.
    static func decodePlanes(
        input: Span<UInt8>,
        payload: Range<Int>,
        width: Int,
        height: Int,
        budget: inout MemoryBudget
    ) throws(WebPError) -> YUVPlanes {
        let lumaStride = (width + 15) / 16 * 16
        let chromaStride = lumaStride / 2
        let paddedHeight = (height + 15) / 16 * 16
        var planes = YUVPlanes(
            y: [UInt8](repeating: 0, count: lumaStride * paddedHeight),
            u: [UInt8](repeating: 0, count: chromaStride * paddedHeight / 2),
            v: [UInt8](repeating: 0, count: chromaStride * paddedHeight / 2),
            lumaStride: lumaStride,
            chromaStride: chromaStride,
            width: width,
            height: height
        )
        try decode(input: input, payload: payload, width: width, height: height, budget: &budget) { luma, u, v, rows in
            for line in 0..<rows.rowCount {
                for x in 0..<lumaStride {
                    planes.y[(rows.firstRow + line) * lumaStride + x] = luma[rows.lumaStart + line * lumaStride + x]
                }
            }
            for line in 0..<(rows.rowCount / 2) {
                let target = (rows.firstRow / 2 + line) * chromaStride
                for x in 0..<chromaStride {
                    planes.u[target + x] = u[rows.chromaStart + line * chromaStride + x]
                    planes.v[target + x] = v[rows.chromaStart + line * chromaStride + x]
                }
            }
        }
        return planes
    }

    /// Locates the token partitions that follow the first partition, section 9.5.
    private static func tokenPartitions(
        count: Int,
        start: Int,
        end: Int,
        input: Span<UInt8>
    ) throws(WebPError) -> [Range<Int>] {
        let tableSize = 3 * (count - 1)
        guard tableSize <= end - start else {
            throw WebPError(.vp8InvalidPartitions)
        }
        var partitions: [Range<Int>] = []
        var position = start + tableSize
        for index in 0..<count {
            var size = end - position
            if index < count - 1 {
                let entry = start + 3 * index
                size = Int(input[entry]) | Int(input[entry + 1]) << 8 | Int(input[entry + 2]) << 16
            }
            guard size <= end - position else {
                throw WebPError(.vp8InvalidPartitions)
            }
            partitions.append(position..<(position + size))
            position += size
        }
        return partitions
    }

    private let header: FrameHeader
    private var headerDecoder: BoolDecoder
    private var tokenDecoders: [BoolDecoder]
    private let macroblockColumns: Int
    private let macroblockRows: Int
    private let extraRows: Int

    // Prediction contexts above the current row and left of the current macroblock.
    private var subblockModesAbove: [UInt8]
    private var subblockModesLeft = [UInt8](repeating: 0, count: 4)

    // Whether neighboring blocks have coefficients: bits 0-3 luma, 4-5 U, 6-7 V, 8 second order.
    private var nonZeroAbove: [UInt16]
    private var nonZeroLeft: UInt16 = 0

    private var subblockModes = [UInt8](repeating: 0, count: 16)

    private init(
        header: FrameHeader,
        headerDecoder: BoolDecoder,
        tokenDecoders: [BoolDecoder],
        macroblockColumns: Int,
        macroblockRows: Int,
        extraRows: Int
    ) {
        self.extraRows = extraRows
        self.header = header
        self.headerDecoder = headerDecoder
        self.tokenDecoders = tokenDecoders
        self.macroblockColumns = macroblockColumns
        self.macroblockRows = macroblockRows
        subblockModesAbove = [UInt8](repeating: 0, count: macroblockColumns * 4)
        nonZeroAbove = [UInt16](repeating: 0, count: macroblockColumns)
    }

    // MARK: - Macroblocks

    private mutating func decodeMacroblocks(
        input: Span<UInt8>,
        caches: inout RowCaches,
        filterInfo: inout MutableSpan<UInt8>,
        deliver: (Span<UInt8>, Span<UInt8>, Span<UInt8>, DecodedRows) -> Void
    ) throws(WebPError) {
        // Working storage that is reused for every macroblock.
        var coefficientStorage = [Int16](repeating: 0, count: Self.coefficientCount)
        var lumaWorkStorage = [UInt8](repeating: 0, count: VP8Prediction.lumaStride * 17)
        var chromaWorkStorage = [UInt8](repeating: 0, count: VP8Prediction.chromaStride * 9 * 2)
        var scratchStorage = [Int32](repeating: 0, count: 16)
        let probabilityStorage = header.coefficientProbabilities

        try caches.luma.withMutableElementSpan { (luma) throws(WebPError) in
            try caches.u.withMutableElementSpan { (u) throws(WebPError) in
                try caches.v.withMutableElementSpan { (v) throws(WebPError) in
                    try caches.lumaAbove.withMutableElementSpan { (lumaAbove) throws(WebPError) in
                        try caches.uAbove.withMutableElementSpan { (uAbove) throws(WebPError) in
                            try caches.vAbove.withMutableElementSpan { (vAbove) throws(WebPError) in
                                try coefficientStorage.withMutableElementSpan { (coefficients) throws(WebPError) in
                                    try lumaWorkStorage.withMutableElementSpan { (lumaWork) throws(WebPError) in
                                        try chromaWorkStorage.withMutableElementSpan { (chromaWork) throws(WebPError) in
                                            try scratchStorage.withMutableElementSpan { (scratch) throws(WebPError) in
                                                try probabilityStorage.withElementSpan {
                                                    (probabilities) throws(WebPError) in
                                                    try VP8Constants.coefficientBands.withElementSpan {
                                                        (bands) throws(WebPError) in
                                                        try VP8Constants.zigzag.withElementSpan {
                                                            (zigzag) throws(WebPError) in
                                                            try decodeRows(
                                                                input: input,
                                                                luma: &luma,
                                                                u: &u,
                                                                v: &v,
                                                                lumaAbove: &lumaAbove,
                                                                uAbove: &uAbove,
                                                                vAbove: &vAbove,
                                                                filterInfo: &filterInfo,
                                                                coefficients: &coefficients,
                                                                lumaWork: &lumaWork,
                                                                chromaWork: &chromaWork,
                                                                scratch: &scratch,
                                                                probabilities: probabilities,
                                                                bands: bands,
                                                                zigzag: zigzag,
                                                                deliver: deliver
                                                            )
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private mutating func decodeRows(
        input: Span<UInt8>,
        luma: inout MutableSpan<UInt8>,
        u: inout MutableSpan<UInt8>,
        v: inout MutableSpan<UInt8>,
        lumaAbove: inout MutableSpan<UInt8>,
        uAbove: inout MutableSpan<UInt8>,
        vAbove: inout MutableSpan<UInt8>,
        filterInfo: inout MutableSpan<UInt8>,
        coefficients: inout MutableSpan<Int16>,
        lumaWork: inout MutableSpan<UInt8>,
        chromaWork: inout MutableSpan<UInt8>,
        scratch: inout MutableSpan<Int32>,
        probabilities: Span<UInt8>,
        bands: Span<Int>,
        zigzag: Span<Int>,
        deliver: (Span<UInt8>, Span<UInt8>, Span<UInt8>, DecodedRows) -> Void
    ) throws(WebPError) {
        let lumaStride = macroblockColumns * 16
        let chromaStride = macroblockColumns * 8
        let chromaExtraRows = extraRows / 2

        for row in 0..<macroblockRows {
            for index in 0..<4 {
                subblockModesLeft[index] = 0
            }
            nonZeroLeft = 0
            let partition = row % tokenDecoders.count

            for column in 0..<macroblockColumns {
                let segment = header.updatesSegmentMap ? readSegment(input) : 0
                let skipsCoefficients =
                    header.skipsCoefficientsWhenFlagged
                    && headerDecoder.read(header.skipProbability, input)
                let lumaMode = readModes(column: column, input: input)
                let chromaMode = readChromaMode(input)

                var hasCoefficients = false
                if !skipsCoefficients {
                    hasCoefficients = readResiduals(
                        column: column,
                        lumaMode: lumaMode,
                        segment: segment,
                        partition: partition,
                        input: input,
                        coefficients: &coefficients,
                        probabilities: probabilities,
                        bands: bands,
                        zigzag: zigzag
                    )
                } else {
                    clearResidualContexts(column: column, hasSecondOrder: lumaMode != .subblocks)
                }

                reconstruct(
                    column: column,
                    row: row,
                    lumaMode: lumaMode,
                    chromaMode: chromaMode,
                    hasCoefficients: hasCoefficients,
                    luma: &luma,
                    u: &u,
                    v: &v,
                    lumaAbove: lumaAbove,
                    uAbove: uAbove,
                    vAbove: vAbove,
                    coefficients: &coefficients,
                    lumaWork: &lumaWork,
                    chromaWork: &chromaWork,
                    scratch: &scratch
                )

                if hasCoefficients {
                    for index in 0..<Self.coefficientCount {
                        coefficients[index] = 0
                    }
                }

                // Inner edges are filtered for subblock modes and macroblocks with coefficients.
                let usesSubblocks = lumaMode == .subblocks
                let filtersInnerEdges = usesSubblocks || hasCoefficients
                filterInfo[column] = UInt8(segment * 2 + (usesSubblocks ? 1 : 0)) | (filtersInnerEdges ? 0x80 : 0)
            }

            guard !tokenDecoders[partition].isPastEnd, !headerDecoder.isPastEnd else {
                throw WebPError(.truncated)
            }

            // The next row predicts from the unfiltered bottom rows of this one.
            let lumaBottom = (extraRows + 15) * lumaStride
            for x in 0..<lumaStride {
                lumaAbove[x] = luma[lumaBottom + x]
            }
            let chromaBottom = (chromaExtraRows + 7) * chromaStride
            for x in 0..<chromaStride {
                uAbove[x] = u[chromaBottom + x]
                vAbove[x] = v[chromaBottom + x]
            }

            if extraRows > 0 {
                filterRow(row: row, luma: &luma, u: &u, v: &v, filterInfo: filterInfo)
            }

            // Rows that the next row's filter can still change stay in the cache.
            let isLastRow = row == macroblockRows - 1
            let firstLine = row == 0 ? extraRows : 0
            let endLine = isLastRow ? extraRows + 16 : 16
            deliver(
                luma.span,
                u.span,
                v.span,
                DecodedRows(
                    lumaStart: firstLine * lumaStride,
                    chromaStart: firstLine / 2 * chromaStride,
                    lumaStride: lumaStride,
                    chromaStride: chromaStride,
                    firstRow: row * 16 - extraRows + firstLine,
                    rowCount: endLine - firstLine
                )
            )
            if !isLastRow {
                for index in 0..<(extraRows * lumaStride) {
                    luma[index] = luma[16 * lumaStride + index]
                }
                for index in 0..<(chromaExtraRows * chromaStride) {
                    u[index] = u[8 * chromaStride + index]
                    v[index] = v[8 * chromaStride + index]
                }
            }
        }
    }

    /// Reads a macroblock's segment, section 10.
    private mutating func readSegment(_ input: Span<UInt8>) -> Int {
        let probabilities = header.segmentProbabilities
        if headerDecoder.read(probabilities.0, input) {
            return 2 + (headerDecoder.read(probabilities.2, input) ? 1 : 0)
        }
        return headerDecoder.read(probabilities.1, input) ? 1 : 0
    }

    /// Reads the luma mode and the subblock modes, and updates their contexts, section 11.
    private mutating func readModes(column: Int, input: Span<UInt8>) -> LumaMode {
        let probabilities = VP8Constants.keyFrameLumaModeProbabilities
        let mode: LumaMode
        if !headerDecoder.read(probabilities.0, input) {
            mode = .subblocks
        } else if !headerDecoder.read(probabilities.1, input) {
            mode = headerDecoder.read(probabilities.2, input) ? .vertical : .dc
        } else {
            mode = headerDecoder.read(probabilities.3, input) ? .trueMotion : .horizontal
        }

        let aboveBase = column * 4
        guard mode == .subblocks else {
            let contextMode = mode.contextSubblockMode
            for index in 0..<4 {
                subblockModesAbove[aboveBase + index] = contextMode
                subblockModesLeft[index] = contextMode
            }
            return mode
        }

        VP8Tables.keyFrameSubblockModeProbabilities.withElementSpan { table in
            for index in 0..<16 {
                let row = index / 4
                let subColumn = index % 4
                let above = row == 0 ? subblockModesAbove[aboveBase + subColumn] : subblockModes[index - 4]
                let left = subColumn == 0 ? subblockModesLeft[row] : subblockModes[index - 1]
                let base = (Int(above) * 10 + Int(left)) * 9
                subblockModes[index] = readSubblockMode(table, base, input)
            }
        }
        for index in 0..<4 {
            subblockModesAbove[aboveBase + index] = subblockModes[12 + index]
            subblockModesLeft[index] = subblockModes[index * 4 + 3]
        }
        return mode
    }

    /// Reads one subblock mode with the tree of section 11.2.
    private mutating func readSubblockMode(_ table: Span<UInt8>, _ base: Int, _ input: Span<UInt8>) -> UInt8 {
        if !headerDecoder.read(UInt32(table[base]), input) { return SubblockMode.dc }
        if !headerDecoder.read(UInt32(table[base &+ 1]), input) { return SubblockMode.trueMotion }
        if !headerDecoder.read(UInt32(table[base &+ 2]), input) { return SubblockMode.vertical }
        if !headerDecoder.read(UInt32(table[base &+ 3]), input) {
            if !headerDecoder.read(UInt32(table[base &+ 4]), input) { return SubblockMode.horizontal }
            return headerDecoder.read(UInt32(table[base &+ 5]), input)
                ? SubblockMode.verticalRight : SubblockMode.rightDown
        }
        if !headerDecoder.read(UInt32(table[base &+ 6]), input) { return SubblockMode.leftDown }
        if !headerDecoder.read(UInt32(table[base &+ 7]), input) { return SubblockMode.verticalLeft }
        return headerDecoder.read(UInt32(table[base &+ 8]), input)
            ? SubblockMode.horizontalUp : SubblockMode.horizontalDown
    }

    /// Reads the chroma mode, section 11.4.
    private mutating func readChromaMode(_ input: Span<UInt8>) -> LumaMode {
        let probabilities = VP8Constants.keyFrameChromaModeProbabilities
        if !headerDecoder.read(probabilities.0, input) { return .dc }
        if !headerDecoder.read(probabilities.1, input) { return .vertical }
        return headerDecoder.read(probabilities.2, input) ? .trueMotion : .horizontal
    }

    // MARK: - Residuals

    /// Resets the coefficient contexts of a macroblock without coefficients.
    private mutating func clearResidualContexts(column: Int, hasSecondOrder: Bool) {
        // The second-order context only changes for macroblocks that have a second-order block.
        let kept: UInt16 = hasSecondOrder ? 0 : 0x100
        nonZeroAbove[column] &= kept
        nonZeroLeft &= kept
    }

    /// Reads and dequantizes the coefficients of a macroblock, section 13.
    ///
    /// - Returns: Whether any block has a non-zero coefficient.
    private mutating func readResiduals(
        column: Int,
        lumaMode: LumaMode,
        segment: Int,
        partition: Int,
        input: Span<UInt8>,
        coefficients: inout MutableSpan<Int16>,
        probabilities: Span<UInt8>,
        bands: Span<Int>,
        zigzag: Span<Int>
    ) -> Bool {
        let factors = header.dequantization[segment]
        var above = nonZeroAbove[column]
        var left = nonZeroLeft
        var decoder = tokenDecoders[partition]
        var anyNonZero = false

        var lumaType = 3
        var firstCoefficient = 0
        if lumaMode != .subblocks {
            let context = Int((above >> 8) & 1) + Int((left >> 8) & 1)
            let nonZero = Self.readBlock(
                &decoder,
                input,
                probabilities: probabilities,
                bands: bands,
                zigzag: zigzag,
                type: 1,
                context: context,
                first: 0,
                dcFactor: factors.secondOrderDC,
                acFactor: factors.secondOrderAC,
                into: &coefficients,
                at: 24 * 16
            )
            above = (above & 0xFF) | (nonZero ? 0x100 : 0)
            left = (left & 0xFF) | (nonZero ? 0x100 : 0)
            anyNonZero = anyNonZero || nonZero
            lumaType = 0
            firstCoefficient = 1
        }

        for block in 0..<16 {
            let x = block & 3
            let y = block >> 2
            let context = Int((above >> x) & 1) + Int((left >> y) & 1)
            let nonZero = Self.readBlock(
                &decoder,
                input,
                probabilities: probabilities,
                bands: bands,
                zigzag: zigzag,
                type: lumaType,
                context: context,
                first: firstCoefficient,
                dcFactor: factors.lumaDC,
                acFactor: factors.lumaAC,
                into: &coefficients,
                at: block * 16
            )
            let bit: UInt16 = nonZero ? 1 : 0
            above = (above & ~(1 << x)) | bit << x
            left = (left & ~(1 << y)) | bit << y
            anyNonZero = anyNonZero || nonZero
        }

        // Chroma blocks 16-19 are U and 20-23 are V, two by two.
        for block in 16..<24 {
            let plane = (block - 16) >> 2
            let x = 4 + plane * 2 + (block & 1)
            let y = 4 + plane * 2 + ((block >> 1) & 1)
            let context = Int((above >> x) & 1) + Int((left >> y) & 1)
            let nonZero = Self.readBlock(
                &decoder,
                input,
                probabilities: probabilities,
                bands: bands,
                zigzag: zigzag,
                type: 2,
                context: context,
                first: 0,
                dcFactor: factors.chromaDC,
                acFactor: factors.chromaAC,
                into: &coefficients,
                at: block * 16
            )
            let bit: UInt16 = nonZero ? 1 : 0
            above = (above & ~(1 << x)) | bit << x
            left = (left & ~(1 << y)) | bit << y
            anyNonZero = anyNonZero || nonZero
        }

        tokenDecoders[partition] = decoder
        nonZeroAbove[column] = above
        nonZeroLeft = left
        return anyNonZero
    }

    /// Reads the tokens of one block, section 13.2, and stores the dequantized coefficients.
    ///
    /// - Returns: Whether the block has a token before its end-of-block token.
    @inline(always)
    private static func readBlock(
        _ decoder: inout BoolDecoder,
        _ input: Span<UInt8>,
        probabilities: Span<UInt8>,
        bands: Span<Int>,
        zigzag: Span<Int>,
        type: Int,
        context: Int,
        first: Int,
        dcFactor: Int32,
        acFactor: Int32,
        into coefficients: inout MutableSpan<Int16>,
        at base: Int
    ) -> Bool {
        var context = context
        var position = first
        var previousWasZero = false

        while position < 16 {
            let node = ((type &* 8 &+ bands[position]) &* 3 &+ context) &* 11

            // An end-of-block token cannot follow a zero.
            if !previousWasZero, !decoder.read(UInt32(probabilities[node]), input) {
                break
            }
            if !decoder.read(UInt32(probabilities[node &+ 1]), input) {
                previousWasZero = true
                context = 0
                position &+= 1
                continue
            }

            var value: Int32
            if !decoder.read(UInt32(probabilities[node &+ 2]), input) {
                value = 1
                context = 1
            } else {
                value = readLargeToken(&decoder, input, probabilities, node)
                context = 2
            }

            if decoder.readFlag(input) {
                value = 0 &- value
            }
            let factor = position > 0 ? acFactor : dcFactor
            coefficients[base &+ zigzag[position]] = Int16(truncatingIfNeeded: value &* factor)
            previousWasZero = false
            position &+= 1
        }
        return position > first
    }

    /// Reads a token whose value is at least 2, after the tree's first three nodes.
    @inline(always)
    private static func readLargeToken(
        _ decoder: inout BoolDecoder,
        _ input: Span<UInt8>,
        _ probabilities: Span<UInt8>,
        _ node: Int
    ) -> Int32 {
        if !decoder.read(UInt32(probabilities[node &+ 3]), input) {
            if !decoder.read(UInt32(probabilities[node &+ 4]), input) {
                return 2
            }
            return 3 &+ (decoder.read(UInt32(probabilities[node &+ 5]), input) ? 1 : 0)
        }
        if !decoder.read(UInt32(probabilities[node &+ 6]), input) {
            if !decoder.read(UInt32(probabilities[node &+ 7]), input) {
                return 5 &+ (decoder.read(159, input) ? 1 : 0)
            }
            let high: Int32 = decoder.read(165, input) ? 2 : 0
            return 7 &+ high &+ (decoder.read(145, input) ? 1 : 0)
        }
        let high = decoder.read(UInt32(probabilities[node &+ 8]), input) ? 1 : 0
        let low = decoder.read(UInt32(probabilities[node &+ 9 &+ high]), input) ? 1 : 0
        return readExtraBits(&decoder, input, category: high &* 2 &+ low)
    }

    /// Reads the value of the `dct_cat3` to `dct_cat6` tokens, section 13.2.
    @inline(never)
    private static func readExtraBits(_ decoder: inout BoolDecoder, _ input: Span<UInt8>, category: Int) -> Int32 {
        @inline(always) func bit(_ probability: UInt32) -> Int32 {
            decoder.read(probability, input) ? 1 : 0
        }
        switch category {
        case 0:
            return 11 &+ (bit(173) &<< 2 | bit(148) &<< 1 | bit(140))
        case 1:
            return 19 &+ (bit(176) &<< 3 | bit(155) &<< 2 | bit(140) &<< 1 | bit(135))
        case 2:
            return 35 &+ (bit(180) &<< 4 | bit(157) &<< 3 | bit(141) &<< 2 | bit(134) &<< 1 | bit(130))
        default:
            var extra = bit(254) &<< 10 | bit(254) &<< 9 | bit(243) &<< 8 | bit(230) &<< 7
            extra |= bit(196) &<< 6 | bit(177) &<< 5 | bit(153) &<< 4 | bit(140) &<< 3
            extra |= bit(133) &<< 2 | bit(130) &<< 1 | bit(129)
            return 67 &+ extra
        }
    }

    // MARK: - Reconstruction

    /// Predicts a macroblock, adds its residuals and stores it in the planes, sections 12 and 14.
    private func reconstruct(
        column: Int,
        row: Int,
        lumaMode: LumaMode,
        chromaMode: LumaMode,
        hasCoefficients: Bool,
        luma: inout MutableSpan<UInt8>,
        u: inout MutableSpan<UInt8>,
        v: inout MutableSpan<UInt8>,
        lumaAbove: borrowing MutableSpan<UInt8>,
        uAbove: borrowing MutableSpan<UInt8>,
        vAbove: borrowing MutableSpan<UInt8>,
        coefficients: inout MutableSpan<Int16>,
        lumaWork work: inout MutableSpan<UInt8>,
        chromaWork: inout MutableSpan<UInt8>,
        scratch: inout MutableSpan<Int32>
    ) {
        let lumaStride = macroblockColumns * 16
        let chromaStride = macroblockColumns * 8
        let lumaRow = extraRows
        let chromaRow = extraRows / 2
        Self.loadLumaNeighbors(
            &work,
            cache: luma,
            above: lumaAbove,
            column: column,
            row: row,
            lastColumn: macroblockColumns - 1,
            stride: lumaStride,
            cacheRow: lumaRow
        )

        let stride = VP8Prediction.lumaStride
        if lumaMode == .subblocks {
            for block in 0..<16 {
                let origin = (1 + (block >> 2) * 4) * stride + 1 + (block & 3) * 4
                VP8Prediction.predictSubblock(subblockModes[block], in: &work, origin: origin)
                if hasCoefficients {
                    Self.addResidual(
                        &coefficients,
                        block * 16,
                        to: &work,
                        at: origin,
                        stride: stride,
                        scratch: &scratch
                    )
                }
            }
        } else {
            VP8Prediction.predictBlock(
                lumaMode,
                in: &work,
                origin: stride + 1,
                size: 16,
                stride: stride,
                hasAbove: row > 0,
                hasLeft: column > 0
            )
            if hasCoefficients {
                VP8Transforms.inverseWalshHadamard(&coefficients, source: Self.secondOrderBlock, scratch: &scratch)
                for block in 0..<16 {
                    let origin = (1 + (block >> 2) * 4) * stride + 1 + (block & 3) * 4
                    Self.addResidual(
                        &coefficients,
                        block * 16,
                        to: &work,
                        at: origin,
                        stride: stride,
                        scratch: &scratch
                    )
                }
            }
        }

        let lumaTarget = lumaRow * lumaStride + column * 16
        for line in 0..<16 {
            for x in 0..<16 {
                luma[lumaTarget + line * lumaStride + x] = work[(line + 1) * stride + 1 + x]
            }
        }

        let chromaStrideInWork = VP8Prediction.chromaStride
        let planeSize = chromaStrideInWork * 9
        Self.loadChromaNeighbors(
            &chromaWork,
            base: 0,
            cache: u,
            above: uAbove,
            column: column,
            row: row,
            stride: chromaStride,
            cacheRow: chromaRow
        )
        Self.loadChromaNeighbors(
            &chromaWork,
            base: planeSize,
            cache: v,
            above: vAbove,
            column: column,
            row: row,
            stride: chromaStride,
            cacheRow: chromaRow
        )

        for plane in 0..<2 {
            let origin = plane * planeSize + chromaStrideInWork + 1
            VP8Prediction.predictBlock(
                chromaMode,
                in: &chromaWork,
                origin: origin,
                size: 8,
                stride: chromaStrideInWork,
                hasAbove: row > 0,
                hasLeft: column > 0
            )
            if hasCoefficients {
                for block in 0..<4 {
                    let blockOrigin = origin + (block >> 1) * 4 * chromaStrideInWork + (block & 1) * 4
                    Self.addResidual(
                        &coefficients,
                        (16 + plane * 4 + block) * 16,
                        to: &chromaWork,
                        at: blockOrigin,
                        stride: chromaStrideInWork,
                        scratch: &scratch
                    )
                }
            }
        }

        let chromaTarget = chromaRow * chromaStride + column * 8
        for line in 0..<8 {
            for x in 0..<8 {
                u[chromaTarget + line * chromaStride + x] = chromaWork[(line + 1) * chromaStrideInWork + 1 + x]
                v[chromaTarget + line * chromaStride + x] =
                    chromaWork[planeSize + (line + 1) * chromaStrideInWork + 1 + x]
            }
        }
    }

    /// Adds the residual of one block, using the cheaper transform when only DC is set.
    @inline(always)
    private static func addResidual(
        _ coefficients: inout MutableSpan<Int16>,
        _ source: Int,
        to work: inout MutableSpan<UInt8>,
        at origin: Int,
        stride: Int,
        scratch: inout MutableSpan<Int32>
    ) {
        if VP8Transforms.hasACCoefficients(coefficients.span, source: source) {
            VP8Transforms.addInverseDCT(
                coefficients.span,
                source: source,
                to: &work,
                at: origin,
                stride: stride,
                scratch: &scratch
            )
        } else if coefficients[source] != 0 {
            VP8Transforms.addInverseDC(coefficients.span, source: source, to: &work, at: origin, stride: stride)
        }
    }

    /// Copies the unfiltered neighbors of a luma macroblock into the work buffer.
    ///
    /// Pixels above the frame are 127 and pixels to the left of it are 129, section 12.
    private static func loadLumaNeighbors(
        _ work: inout MutableSpan<UInt8>,
        cache: borrowing MutableSpan<UInt8>,
        above: borrowing MutableSpan<UInt8>,
        column: Int,
        row: Int,
        lastColumn: Int,
        stride planeStride: Int,
        cacheRow: Int
    ) {
        let stride = VP8Prediction.lumaStride
        let x = column * 16

        if row == 0 {
            for index in 0...20 {
                work[index] = 127
            }
        } else {
            work[0] = column == 0 ? 129 : above[x - 1]
            for index in 0..<16 {
                work[1 + index] = above[x + index]
            }
            for index in 0..<4 {
                // The rightmost macroblock repeats the last pixel above it, section 12.3.
                work[17 + index] = column < lastColumn ? above[x + 16 + index] : above[x + 15]
            }
        }

        // Subblocks on the right edge use the pixels above and to the right of the macroblock.
        for line in Swift.stride(from: 4, through: 12, by: 4) {
            for index in 0..<4 {
                work[line * stride + 17 + index] = work[17 + index]
            }
        }

        for line in 0..<16 {
            work[(line + 1) * stride] = column == 0 ? 129 : cache[(cacheRow + line) * planeStride + x - 1]
        }
    }

    /// Copies the unfiltered neighbors of a chroma block into the work buffer.
    private static func loadChromaNeighbors(
        _ work: inout MutableSpan<UInt8>,
        base: Int,
        cache: borrowing MutableSpan<UInt8>,
        above: borrowing MutableSpan<UInt8>,
        column: Int,
        row: Int,
        stride planeStride: Int,
        cacheRow: Int
    ) {
        let stride = VP8Prediction.chromaStride
        let x = column * 8

        if row == 0 {
            for index in 0...8 {
                work[base + index] = 127
            }
        } else {
            work[base] = column == 0 ? 129 : above[x - 1]
            for index in 0..<8 {
                work[base + 1 + index] = above[x + index]
            }
        }
        for line in 0..<8 {
            work[base + (line + 1) * stride] = column == 0 ? 129 : cache[(cacheRow + line) * planeStride + x - 1]
        }
    }

    // MARK: - Loop filter

    /// Applies the loop filter to the macroblock row in the cache, section 15.
    ///
    /// Macroblocks are filtered in the same order as the format describes for the whole frame.
    private func filterRow(
        row: Int,
        luma: inout MutableSpan<UInt8>,
        u: inout MutableSpan<UInt8>,
        v: inout MutableSpan<UInt8>,
        filterInfo: borrowing MutableSpan<UInt8>
    ) {
        let simple = header.usesSimpleFilter
        let strengths = header.filterStrengths
        let lumaStride = macroblockColumns * 16
        let chromaStride = macroblockColumns * 8
        do {
            for column in 0..<macroblockColumns {
                let info = filterInfo[column]
                let strength = strengths[Int(info & 0x7F)]
                guard strength.level > 0 else {
                    continue
                }
                let filtersInnerEdges = info & 0x80 != 0
                let macroblockLimit = (strength.level + 2) * 2 + strength.interiorLimit
                let subblockLimit = strength.level * 2 + strength.interiorLimit

                let lumaOrigin = extraRows * lumaStride + column * 16
                let chromaOrigin = extraRows / 2 * chromaStride + column * 8

                if simple {
                    if column > 0 {
                        VP8LoopFilter.simpleEdge(
                            &luma,
                            start: lumaOrigin,
                            step: 1,
                            along: lumaStride,
                            count: 16,
                            edgeLimit: macroblockLimit
                        )
                    }
                    if filtersInnerEdges {
                        for offset in Swift.stride(from: 4, through: 12, by: 4) {
                            VP8LoopFilter.simpleEdge(
                                &luma,
                                start: lumaOrigin + offset,
                                step: 1,
                                along: lumaStride,
                                count: 16,
                                edgeLimit: subblockLimit
                            )
                        }
                    }
                    if row > 0 {
                        VP8LoopFilter.simpleEdge(
                            &luma,
                            start: lumaOrigin,
                            step: lumaStride,
                            along: 1,
                            count: 16,
                            edgeLimit: macroblockLimit
                        )
                    }
                    if filtersInnerEdges {
                        for offset in Swift.stride(from: 4, through: 12, by: 4) {
                            VP8LoopFilter.simpleEdge(
                                &luma,
                                start: lumaOrigin + offset * lumaStride,
                                step: lumaStride,
                                along: 1,
                                count: 16,
                                edgeLimit: subblockLimit
                            )
                        }
                    }
                    continue
                }

                if column > 0 {
                    VP8LoopFilter.macroblockEdge(
                        &luma,
                        start: lumaOrigin,
                        step: 1,
                        along: lumaStride,
                        count: 16,
                        strength: strength,
                        edgeLimit: macroblockLimit
                    )
                    VP8LoopFilter.macroblockEdge(
                        &u,
                        start: chromaOrigin,
                        step: 1,
                        along: chromaStride,
                        count: 8,
                        strength: strength,
                        edgeLimit: macroblockLimit
                    )
                    VP8LoopFilter.macroblockEdge(
                        &v,
                        start: chromaOrigin,
                        step: 1,
                        along: chromaStride,
                        count: 8,
                        strength: strength,
                        edgeLimit: macroblockLimit
                    )
                }
                if filtersInnerEdges {
                    for offset in Swift.stride(from: 4, through: 12, by: 4) {
                        VP8LoopFilter.subblockEdge(
                            &luma,
                            start: lumaOrigin + offset,
                            step: 1,
                            along: lumaStride,
                            count: 16,
                            strength: strength,
                            edgeLimit: subblockLimit
                        )
                    }
                    VP8LoopFilter.subblockEdge(
                        &u,
                        start: chromaOrigin + 4,
                        step: 1,
                        along: chromaStride,
                        count: 8,
                        strength: strength,
                        edgeLimit: subblockLimit
                    )
                    VP8LoopFilter.subblockEdge(
                        &v,
                        start: chromaOrigin + 4,
                        step: 1,
                        along: chromaStride,
                        count: 8,
                        strength: strength,
                        edgeLimit: subblockLimit
                    )
                }
                if row > 0 {
                    VP8LoopFilter.macroblockEdge(
                        &luma,
                        start: lumaOrigin,
                        step: lumaStride,
                        along: 1,
                        count: 16,
                        strength: strength,
                        edgeLimit: macroblockLimit
                    )
                    VP8LoopFilter.macroblockEdge(
                        &u,
                        start: chromaOrigin,
                        step: chromaStride,
                        along: 1,
                        count: 8,
                        strength: strength,
                        edgeLimit: macroblockLimit
                    )
                    VP8LoopFilter.macroblockEdge(
                        &v,
                        start: chromaOrigin,
                        step: chromaStride,
                        along: 1,
                        count: 8,
                        strength: strength,
                        edgeLimit: macroblockLimit
                    )
                }
                if filtersInnerEdges {
                    for offset in Swift.stride(from: 4, through: 12, by: 4) {
                        VP8LoopFilter.subblockEdge(
                            &luma,
                            start: lumaOrigin + offset * lumaStride,
                            step: lumaStride,
                            along: 1,
                            count: 16,
                            strength: strength,
                            edgeLimit: subblockLimit
                        )
                    }
                    VP8LoopFilter.subblockEdge(
                        &u,
                        start: chromaOrigin + 4 * chromaStride,
                        step: chromaStride,
                        along: 1,
                        count: 8,
                        strength: strength,
                        edgeLimit: subblockLimit
                    )
                    VP8LoopFilter.subblockEdge(
                        &v,
                        start: chromaOrigin + 4 * chromaStride,
                        step: chromaStride,
                        along: 1,
                        count: 8,
                        strength: strength,
                        edgeLimit: subblockLimit
                    )
                }
            }
        }
    }
}
