internal import RasterWebPCore

/// The dequantization factors of one segment. RFC 6386, section 14.1.
struct DequantizationFactors {
    var lumaDC: Int32 = 0
    var lumaAC: Int32 = 0
    var secondOrderDC: Int32 = 0
    var secondOrderAC: Int32 = 0
    var chromaDC: Int32 = 0
    var chromaAC: Int32 = 0
}

/// The loop filter strength of a macroblock. RFC 6386, section 15.4.
struct FilterStrength: Equatable {
    var level: Int32 = 0
    var interiorLimit: Int32 = 0
    var highEdgeVarianceThreshold: Int32 = 0
}

/// The parsed header of a VP8 key frame, RFC 6386, section 9.
struct FrameHeader {
    static var segmentCount: Int { 4 }

    var updatesSegmentMap = false
    var segmentProbabilities: (UInt32, UInt32, UInt32) = (255, 255, 255)
    var usesSimpleFilter = false
    var filterLevel = 0
    var skipsCoefficientsWhenFlagged = false
    var skipProbability: UInt32 = 0
    var partitionCount = 1

    /// The dequantization factors of each segment.
    var dequantization = [DequantizationFactors](repeating: DequantizationFactors(), count: 4)

    /// The filter strengths of each segment, first for 16x16 luma modes and then for subblock modes.
    var filterStrengths = [FilterStrength](repeating: FilterStrength(), count: 8)

    /// The token probabilities, indexed by block type, band, context and tree node.
    var coefficientProbabilities = VP8Tables.defaultCoefficientProbabilities

    init(decoder: inout BoolDecoder, input: Span<UInt8>) {
        // Color space and clamping type. Every decoder must clamp, so neither changes decoding.
        _ = decoder.readFlag(input)
        _ = decoder.readFlag(input)

        var segmentationEnabled = false
        var segmentsUseAbsoluteValues = false
        var segmentQuantizers = [Int](repeating: 0, count: 4)
        var segmentFilterLevels = [Int](repeating: 0, count: 4)

        if decoder.readFlag(input) {
            segmentationEnabled = true
            updatesSegmentMap = decoder.readFlag(input)
            if decoder.readFlag(input) {
                segmentsUseAbsoluteValues = decoder.readFlag(input)
                for segment in 0..<4 {
                    segmentQuantizers[segment] = decoder.readOptionalSigned(7, input)
                }
                for segment in 0..<4 {
                    segmentFilterLevels[segment] = decoder.readOptionalSigned(6, input)
                }
            }
            if updatesSegmentMap {
                func probability() -> UInt32 {
                    decoder.readFlag(input) ? UInt32(decoder.readLiteral(8, input)) : 255
                }
                segmentProbabilities = (probability(), probability(), probability())
            }
        }

        usesSimpleFilter = decoder.readFlag(input)
        filterLevel = decoder.readLiteral(6, input)
        let sharpness = decoder.readLiteral(3, input)

        var referenceFrameDeltas = [Int](repeating: 0, count: 4)
        var modeDeltas = [Int](repeating: 0, count: 4)
        let filterDeltasEnabled = decoder.readFlag(input)
        if filterDeltasEnabled, decoder.readFlag(input) {
            for index in 0..<4 {
                referenceFrameDeltas[index] = decoder.readOptionalSigned(6, input)
            }
            for index in 0..<4 {
                modeDeltas[index] = decoder.readOptionalSigned(6, input)
            }
        }

        partitionCount = 1 << decoder.readLiteral(2, input)

        let baseQuantizer = decoder.readLiteral(7, input)
        let lumaDCDelta = decoder.readOptionalSigned(4, input)
        let secondOrderDCDelta = decoder.readOptionalSigned(4, input)
        let secondOrderACDelta = decoder.readOptionalSigned(4, input)
        let chromaDCDelta = decoder.readOptionalSigned(4, input)
        let chromaACDelta = decoder.readOptionalSigned(4, input)

        // Refresh entropy probabilities, which only matters for later frames.
        _ = decoder.readFlag(input)

        let updateProbabilities = VP8Tables.coefficientUpdateProbabilities
        for index in coefficientProbabilities.indices
        where decoder.read(UInt32(updateProbabilities[index]), input) {
            coefficientProbabilities[index] = UInt8(decoder.readLiteral(8, input))
        }

        skipsCoefficientsWhenFlagged = decoder.readFlag(input)
        if skipsCoefficientsWhenFlagged {
            skipProbability = UInt32(decoder.readLiteral(8, input))
        }

        // Dequantization factors, as computed by the reference decoder's `dequant_init`.
        let dc = VP8Tables.dcQuantizers
        let ac = VP8Tables.acQuantizers
        func lookup(_ table: [UInt16], _ index: Int) -> Int32 {
            Int32(table[min(max(index, 0), 127)])
        }
        for segment in 0..<4 {
            var quantizer = baseQuantizer
            if segmentationEnabled {
                quantizer =
                    segmentsUseAbsoluteValues
                    ? segmentQuantizers[segment] : quantizer + segmentQuantizers[segment]
            }
            var factors = DequantizationFactors()
            factors.lumaDC = lookup(dc, quantizer + lumaDCDelta)
            factors.lumaAC = lookup(ac, quantizer)
            factors.secondOrderDC = lookup(dc, quantizer + secondOrderDCDelta) * 2
            factors.secondOrderAC = max(lookup(ac, quantizer + secondOrderACDelta) * 155 / 100, 8)
            factors.chromaDC = min(lookup(dc, quantizer + chromaDCDelta), 132)
            factors.chromaAC = lookup(ac, quantizer + chromaACDelta)
            dequantization[segment] = factors
        }

        // Filter strengths, as computed by the reference decoder's `calculate_filter_parameters`.
        for segment in 0..<4 {
            var segmentLevel = filterLevel
            if segmentationEnabled {
                segmentLevel =
                    segmentsUseAbsoluteValues
                    ? segmentFilterLevels[segment] : segmentLevel + segmentFilterLevels[segment]
            }
            segmentLevel = min(max(segmentLevel, 0), 63)

            for usesSubblocks in [false, true] {
                var level = segmentLevel
                if filterDeltasEnabled {
                    // Key frames only contain intra macroblocks, the first reference frame.
                    level += referenceFrameDeltas[0]
                    if usesSubblocks {
                        level += modeDeltas[0]
                    }
                }
                level = min(max(level, 0), 63)

                var interiorLimit = level
                if sharpness > 0 {
                    interiorLimit >>= sharpness > 4 ? 2 : 1
                    interiorLimit = min(interiorLimit, 9 - sharpness)
                }
                interiorLimit = max(interiorLimit, 1)

                let threshold = level >= 40 ? 2 : level >= 15 ? 1 : 0
                filterStrengths[segment * 2 + (usesSubblocks ? 1 : 0)] = FilterStrength(
                    level: Int32(level),
                    interiorLimit: Int32(interiorLimit),
                    highEdgeVarianceThreshold: Int32(threshold)
                )
            }
        }
    }
}
