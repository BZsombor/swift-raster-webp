import Testing

@testable import RasterWebPDecoder

/// The vector inverse DCT must match a direct reading of RFC 6386, section 14.4.
@Suite("VP8 inverse transforms")
struct VP8TransformTests {
    /// The inverse DCT exactly as section 14.4 describes it: columns first, then rows, with
    /// 16-bit intermediate values, and the result added to the prediction with clamping.
    private static func reference(_ input: [Int16], prediction: [UInt8]) -> [UInt8] {
        func wrapped(_ value: Int32) -> Int32 { Int32(Int16(truncatingIfNeeded: value)) }
        func sine(_ value: Int32) -> Int32 { (value * 35468) >> 16 }
        func cosine(_ value: Int32) -> Int32 { value + ((value * 20091) >> 16) }

        var temporary = [Int32](repeating: 0, count: 16)
        for column in 0..<4 {
            let i0 = Int32(input[column]), i1 = Int32(input[4 + column])
            let i2 = Int32(input[8 + column]), i3 = Int32(input[12 + column])
            let a = i0 + i2, b = i0 - i2
            let c = sine(i1) - cosine(i3), d = cosine(i1) + sine(i3)
            temporary[column] = wrapped(a + d)
            temporary[4 + column] = wrapped(b + c)
            temporary[8 + column] = wrapped(b - c)
            temporary[12 + column] = wrapped(a - d)
        }

        var output = prediction
        for row in 0..<4 {
            let i0 = temporary[row * 4], i1 = temporary[row * 4 + 1]
            let i2 = temporary[row * 4 + 2], i3 = temporary[row * 4 + 3]
            let a = i0 + i2, b = i0 - i2
            let c = sine(i1) - cosine(i3), d = cosine(i1) + sine(i3)
            let residuals = [a + d, b + c, b - c, a - d].map { wrapped(($0 + 4) >> 3) }
            for column in 0..<4 {
                let sum = Int32(prediction[row * 4 + column]) + residuals[column]
                output[row * 4 + column] = UInt8(min(max(sum, 0), 255))
            }
        }
        return output
    }

    @Test func inverseDCTMatchesTheSpecification() {
        var generator = SplitMix64(state: 0x4944_4354)
        for trial in 0..<20_000 {
            // Small coefficients are typical, and full-range ones exercise the 16-bit wrapping.
            let range = trial % 4 == 0 ? 65536 : 512
            let input = (0..<16).map { _ in Int16(truncatingIfNeeded: generator.next(below: range) - range / 2) }
            let prediction = (0..<16).map { _ in UInt8(truncatingIfNeeded: generator.next(below: 256)) }

            // The block sits in a wider buffer, as in the decoder's work buffer.
            let stride = 7
            var pixels = [UInt8](repeating: 0, count: stride * 4)
            for row in 0..<4 {
                for column in 0..<4 {
                    pixels[row * stride + 1 + column] = prediction[row * 4 + column]
                }
            }
            input.withElementSpan { coefficients in
                pixels.withMutableElementSpan { span in
                    VP8Transforms.addInverseDCT(coefficients, source: 0, to: &span, at: 1, stride: stride)
                }
            }

            let expected = Self.reference(input, prediction: prediction)
            var actual = [UInt8]()
            for row in 0..<4 {
                actual += pixels[(row * stride + 1)..<(row * stride + 5)]
            }
            #expect(actual == expected, "coefficients \(input)")
        }
    }

    @Test func inverseDCOfADCOnlyBlockMatchesTheFullTransform() {
        var generator = SplitMix64(state: 0x4944_4343)
        for _ in 0..<5000 {
            var input = [Int16](repeating: 0, count: 16)
            input[0] = Int16(truncatingIfNeeded: generator.next(below: 4096) - 2048)
            let prediction = (0..<16).map { _ in UInt8(truncatingIfNeeded: generator.next(below: 256)) }

            var pixels = prediction
            input.withElementSpan { coefficients in
                pixels.withMutableElementSpan { span in
                    VP8Transforms.addInverseDC(coefficients, source: 0, to: &span, at: 0, stride: 4)
                }
            }
            #expect(pixels == Self.reference(input, prediction: prediction), "DC \(input[0])")
        }
    }
}
