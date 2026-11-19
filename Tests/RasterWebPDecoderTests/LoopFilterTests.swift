import Testing

@testable import RasterWebPDecoder

/// The vector loop filters must change exactly the pixels that the scalar filters change.
@Suite("Loop filters")
struct LoopFilterTests {
    private enum Kind: CaseIterable {
        case simple, subblock, macroblock
    }

    /// A random strength, with an edge limit as `filterRow` computes it.
    private static func strength(
        _ generator: inout SplitMix64,
        kind: Kind
    ) -> (FilterStrength, edgeLimit: Int32) {
        let level = Int32(1 + generator.next(below: 63))
        let interiorLimit = Int32(1 + generator.next(below: 9))
        let threshold = Int32(generator.next(below: 3))
        let edgeLimit = kind == .macroblock ? (level + 2) * 2 + interiorLimit : level * 2 + interiorLimit
        return (FilterStrength(level: level, interiorLimit: interiorLimit, highEdgeVarianceThreshold: threshold), edgeLimit)
    }

    /// A plane that is smooth on each side of an edge, so that every filter branch is reached.
    private static func plane(
        _ generator: inout SplitMix64,
        width: Int,
        height: Int,
        edge: Int,
        isVertical: Bool
    ) -> [UInt8] {
        let base = generator.next(below: 256)
        let noise = generator.next(below: 12)
        let step = generator.next(below: 81) - 40
        return (0..<(width * height)).map { index in
            let position = isVertical ? index % width : index / width
            let value = base + (position >= edge ? step : 0) + generator.next(below: 2 * noise + 1) - noise
            return UInt8(min(max(value, 0), 255))
        }
    }

    private static func scalar(
        _ pixels: inout [UInt8],
        kind: Kind,
        start: Int,
        step: Int,
        along: Int,
        count: Int,
        strength: FilterStrength,
        edgeLimit: Int32
    ) {
        pixels.withMutableElementSpan { span in
            switch kind {
            case .simple:
                VP8LoopFilter.simpleEdge(
                    &span, start: start, step: step, along: along, count: count, edgeLimit: edgeLimit)
            case .subblock:
                VP8LoopFilter.subblockEdge(
                    &span, start: start, step: step, along: along, count: count, strength: strength,
                    edgeLimit: edgeLimit)
            case .macroblock:
                VP8LoopFilter.macroblockEdge(
                    &span, start: start, step: step, along: along, count: count, strength: strength,
                    edgeLimit: edgeLimit)
            }
        }
    }

    @Test(arguments: [false, true])
    func lumaEdgesMatchTheScalarFilters(isVertical: Bool) {
        var generator = SplitMix64(state: isVertical ? 0x4C46_5654 : 0x4C46_484F)
        let stride = 32
        let start = 8 * stride + 8
        var changed = 0

        for kind in Kind.allCases {
            for _ in 0..<2000 {
                let (strength, edgeLimit) = Self.strength(&generator, kind: kind)
                let original = Self.plane(&generator, width: stride, height: 32, edge: 8, isVertical: isVertical)

                var expected = original
                Self.scalar(
                    &expected, kind: kind, start: start, step: isVertical ? 1 : stride,
                    along: isVertical ? stride : 1, count: 16, strength: strength, edgeLimit: edgeLimit)

                var actual = original
                actual.withMutableElementSpan { span in
                    switch (kind, isVertical) {
                    case (.simple, true):
                        VP8LoopFilter.simpleVerticalEdge(&span, start: start, stride: stride, edgeLimit: edgeLimit)
                    case (.simple, false):
                        VP8LoopFilter.simpleHorizontalEdge(&span, start: start, stride: stride, edgeLimit: edgeLimit)
                    case (_, true):
                        VP8LoopFilter.normalVerticalEdge(
                            &span, start: start, stride: stride, strength: strength, edgeLimit: edgeLimit,
                            isMacroblockEdge: kind == .macroblock)
                    case (_, false):
                        VP8LoopFilter.normalHorizontalEdge(
                            &span, start: start, stride: stride, strength: strength, edgeLimit: edgeLimit,
                            isMacroblockEdge: kind == .macroblock)
                    }
                }

                #expect(actual == expected, "\(kind) \(strength) edge limit \(edgeLimit)")
                if expected != original {
                    changed += 1
                }
            }
        }
        // Most cases must filter something, or the comparison proves little.
        #expect(changed > 3000)
    }

    @Test(arguments: [false, true])
    func chromaEdgesMatchTheScalarFilters(isVertical: Bool) {
        var generator = SplitMix64(state: isVertical ? 0x4346_5654 : 0x4346_484F)
        let stride = 16
        let start = 8 * stride + 4
        var changed = 0

        for kind in [Kind.subblock, .macroblock] {
            for _ in 0..<2000 {
                let (strength, edgeLimit) = Self.strength(&generator, kind: kind)
                let edge = isVertical ? 4 : 8
                let originalU = Self.plane(&generator, width: stride, height: 16, edge: edge, isVertical: isVertical)
                let originalV = Self.plane(&generator, width: stride, height: 16, edge: edge, isVertical: isVertical)

                var expectedU = originalU
                var expectedV = originalV
                let step = isVertical ? 1 : stride
                let along = isVertical ? stride : 1
                Self.scalar(
                    &expectedU, kind: kind, start: start, step: step, along: along, count: 8,
                    strength: strength, edgeLimit: edgeLimit)
                Self.scalar(
                    &expectedV, kind: kind, start: start, step: step, along: along, count: 8,
                    strength: strength, edgeLimit: edgeLimit)

                var actualU = originalU
                var actualV = originalV
                actualU.withMutableElementSpan { u in
                    actualV.withMutableElementSpan { v in
                        if isVertical {
                            VP8LoopFilter.normalVerticalEdge(
                                u: &u, v: &v, start: start, stride: stride, strength: strength,
                                edgeLimit: edgeLimit, isMacroblockEdge: kind == .macroblock)
                        } else {
                            VP8LoopFilter.normalHorizontalEdge(
                                u: &u, v: &v, start: start, stride: stride, strength: strength,
                                edgeLimit: edgeLimit, isMacroblockEdge: kind == .macroblock)
                        }
                    }
                }

                #expect(actualU == expectedU, "U \(kind) \(strength) edge limit \(edgeLimit)")
                #expect(actualV == expectedV, "V \(kind) \(strength) edge limit \(edgeLimit)")
                if expectedU != originalU || expectedV != originalV {
                    changed += 1
                }
            }
        }
        #expect(changed > 2000)
    }
}
