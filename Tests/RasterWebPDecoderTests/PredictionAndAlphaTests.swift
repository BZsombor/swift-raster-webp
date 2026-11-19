import Testing

@testable import RasterWebPDecoder

/// The vector block predictions must match a direct reading of RFC 6386, section 12.2.
@Suite("VP8 block prediction")
struct BlockPredictionTests {
    /// Predicts a block from the neighbors in `work`, exactly as section 12.2 describes.
    private static func reference(
        _ mode: LumaMode,
        _ work: [UInt8],
        origin: Int,
        size: Int,
        stride: Int,
        hasAbove: Bool,
        hasLeft: Bool
    ) -> [UInt8] {
        let above = (0..<size).map { Int(work[origin - stride + $0]) }
        let left = (0..<size).map { Int(work[origin + $0 * stride - 1]) }
        let corner = Int(work[origin - stride - 1])
        let shift = size == 16 ? 4 : 3

        var output = work
        for row in 0..<size {
            for column in 0..<size {
                let value: Int
                switch mode {
                case .vertical: value = above[column]
                case .horizontal: value = left[row]
                case .trueMotion: value = min(max(left[row] + above[column] - corner, 0), 255)
                case .dc, .subblocks:
                    switch (hasAbove, hasLeft) {
                    case (true, true):
                        value = (above.reduce(0, +) + left.reduce(0, +) + (1 << shift)) >> (shift + 1)
                    case (true, false): value = (above.reduce(0, +) + (1 << (shift - 1))) >> shift
                    case (false, true): value = (left.reduce(0, +) + (1 << (shift - 1))) >> shift
                    case (false, false): value = 128
                    }
                }
                output[origin + row * stride + column] = UInt8(value)
            }
        }
        return output
    }

    @Test(arguments: [16, 8])
    func everyModeMatchesTheSpecification(size: Int) {
        var generator = SplitMix64(state: UInt64(size) + 0x5052_4544)
        let stride = size == 16 ? VP8Prediction.lumaStride : VP8Prediction.chromaStride
        let origin = stride + 1

        for mode in [LumaMode.dc, .vertical, .horizontal, .trueMotion] {
            for edges in 0..<4 {
                for _ in 0..<200 {
                    let hasAbove = edges & 1 == 1
                    let hasLeft = edges & 2 == 2
                    let work = (0..<(stride * (size + 1))).map { _ in
                        UInt8(truncatingIfNeeded: generator.next(below: 256))
                    }

                    var actual = work
                    actual.withMutableElementSpan { span in
                        VP8Prediction.predictBlock(
                            mode,
                            in: &span,
                            origin: origin,
                            size: size,
                            stride: stride,
                            hasAbove: hasAbove,
                            hasLeft: hasLeft
                        )
                    }
                    let expected = Self.reference(
                        mode,
                        work,
                        origin: origin,
                        size: size,
                        stride: stride,
                        hasAbove: hasAbove,
                        hasLeft: hasLeft
                    )
                    #expect(actual == expected, "\(mode) above \(hasAbove) left \(hasLeft)")
                }
            }
        }
    }
}

/// Reversing an alpha filter must restore the values that RFC 9649, section 2.7.1.2, filtered.
@Suite("Alpha filters")
struct AlphaFilterTests {
    /// Filters an alpha plane with the predictors and border rules of the specification.
    private static func filter(_ alpha: [UInt8], width: Int, height: Int, method: UInt8) -> [UInt8] {
        func value(_ x: Int, _ y: Int) -> Int { Int(alpha[y * width + x]) }

        var filtered = alpha
        for y in 0..<height {
            for x in 0..<width {
                let prediction: Int
                if x == 0, y == 0 {
                    prediction = 0
                } else if y == 0 {
                    prediction = value(x - 1, 0)
                } else if x == 0 {
                    prediction = value(0, y - 1)
                } else {
                    switch method {
                    case 1: prediction = value(x - 1, y)
                    case 2: prediction = value(x, y - 1)
                    default:
                        prediction = min(max(value(x - 1, y) + value(x, y - 1) - value(x - 1, y - 1), 0), 255)
                    }
                }
                filtered[y * width + x] = UInt8(truncatingIfNeeded: value(x, y) - prediction)
            }
        }
        return filtered
    }

    @Test(arguments: [UInt8(1), 2, 3])
    func unfilteringRestoresTheFilteredPlane(method: UInt8) {
        var generator = SplitMix64(state: UInt64(method) + 0x414C_5048)
        for trial in 0..<300 {
            let width = 1 + generator.next(below: 40)
            let height = 1 + generator.next(below: 40)
            // Smooth planes keep the gradient predictor inside the pixel range, noise clamps it.
            let smooth = trial % 2 == 0
            let original = (0..<(width * height)).map { index in
                smooth
                    ? UInt8(truncatingIfNeeded: (index % width) * 3 + (index / width) * 2 + generator.next(below: 8))
                    : UInt8(truncatingIfNeeded: generator.next(below: 256))
            }

            // The decoder keeps alpha in the top byte of each output pixel.
            var plane = Self.filter(original, width: width, height: height, method: method).map { UInt32($0) << 24 }
            plane.withMutableElementSpan { span in
                AlphaDecoder.unfilter(&span, width: width, height: height, method: method)
            }
            #expect(plane == original.map { UInt32($0) << 24 }, "\(width)x\(height)")
        }
    }

    @Test func noFilterLeavesThePlaneUnchanged() {
        let values: [UInt32] = [3, 1, 4, 1, 5, 9].map { $0 << 24 }
        var plane = values
        plane.withMutableElementSpan { span in
            AlphaDecoder.unfilter(&span, width: 3, height: 2, method: 0)
        }
        #expect(plane == values)
    }
}
