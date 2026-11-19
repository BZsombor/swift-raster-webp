import Testing

@testable import RasterWebPDecoder

/// A direct, per-channel transcription of the formulas in RFC 9649, section 3.5.
private enum Specification {
    static func channels(_ pixel: UInt32) -> [Int] {
        [24, 16, 8, 0].map { Int((pixel >> UInt32($0)) & 0xFF) }
    }

    static func pixel(_ channels: [Int]) -> UInt32 {
        zip([24, 16, 8, 0], channels).reduce(0) { $0 | UInt32($1.1 & 0xFF) << UInt32($1.0) }
    }

    static func average(_ a: UInt32, _ b: UInt32) -> UInt32 {
        pixel(zip(channels(a), channels(b)).map { ($0 + $1) / 2 })
    }

    static func select(_ l: UInt32, _ t: UInt32, _ tl: UInt32) -> UInt32 {
        let (cl, ct, ctl) = (channels(l), channels(t), channels(tl))
        let estimate = (0..<4).map { cl[$0] + ct[$0] - ctl[$0] }
        let pL = (0..<4).reduce(0) { $0 + abs(estimate[$1] - cl[$1]) }
        let pT = (0..<4).reduce(0) { $0 + abs(estimate[$1] - ct[$1]) }
        return pL < pT ? l : t
    }

    static func clamp(_ value: Int) -> Int {
        value < 0 ? 0 : value > 255 ? 255 : value
    }

    static func addSubtractFull(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        let (ca, cb, cc) = (channels(a), channels(b), channels(c))
        return pixel((0..<4).map { clamp(ca[$0] + cb[$0] - cc[$0]) })
    }

    static func addSubtractHalf(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let (ca, cb) = (channels(a), channels(b))
        return pixel((0..<4).map { clamp(ca[$0] + (ca[$0] - cb[$0]) / 2) })
    }

    static func predict(mode: Int, l: UInt32, t: UInt32, tr: UInt32, tl: UInt32) -> UInt32 {
        switch mode {
        case 0: 0xFF00_0000
        case 1: l
        case 2: t
        case 3: tr
        case 4: tl
        case 5: average(average(l, tr), t)
        case 6: average(l, tl)
        case 7: average(l, t)
        case 8: average(tl, t)
        case 9: average(t, tr)
        case 10: average(average(l, tl), average(t, tr))
        case 11: select(l, t, tl)
        case 12: addSubtractFull(l, t, tl)
        default: addSubtractHalf(average(l, t), tl)
        }
    }

    static func add(_ a: UInt32, _ b: UInt32) -> UInt32 {
        pixel(zip(channels(a), channels(b)).map { $0 + $1 })
    }

    static func delta(_ t: UInt8, _ c: UInt8) -> Int {
        (Int(Int8(bitPattern: t)) * Int(Int8(bitPattern: c))) >> 5
    }
}

@Suite("Inverse transforms")
struct InverseTransformTests {
    @Test(arguments: 0..<14)
    func predictionsMatchTheSpecification(mode: Int) {
        var generator = SplitMix64(state: UInt64(mode) + 0x5052_4544)
        for _ in 0..<20_000 {
            let (l, t, tr, tl) = (generator.pixel(), generator.pixel(), generator.pixel(), generator.pixel())
            let actual = InverseTransforms.predict(mode: UInt32(mode), left: l, top: t, topRight: tr, topLeft: tl)
            #expect(actual == Specification.predict(mode: mode, l: l, t: t, tr: tr, tl: tl))
        }
    }

    @Test(arguments: [UInt32(14), 15])
    func undefinedPredictionModesAreBlack(mode: UInt32) {
        let actual = InverseTransforms.predict(mode: mode, left: 1, top: 2, topRight: 3, topLeft: 4)
        #expect(actual == 0xFF00_0000)
    }

    @Test func wholeImagePredictionFollowsTheBorderRules() {
        var generator = SplitMix64(state: 0x4544_4745)

        for _ in 0..<100 {
            let width = 1 + generator.next(below: 40)
            let height = 1 + generator.next(below: 20)
            let blockBits = 2 + generator.next(below: 3)
            let blockColumns = (width + (1 << blockBits) - 1) >> blockBits
            let blockRows = (height + (1 << blockBits) - 1) >> blockBits
            let modes = (0..<(blockColumns * blockRows)).map { _ in UInt32(generator.next(below: 14)) << 8 }
            let residuals = (0..<(width * height)).map { _ in generator.pixel() }

            // Reconstruct the image from the rules in the specification.
            var expected = residuals
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    let prediction: UInt32
                    if x == 0, y == 0 {
                        prediction = 0xFF00_0000
                    } else if y == 0 {
                        prediction = expected[index - 1]
                    } else if x == 0 {
                        prediction = expected[index - width]
                    } else {
                        let mode = Int(modes[(y >> blockBits) * blockColumns + (x >> blockBits)] >> 8)
                        let topRight = x == width - 1 ? expected[y * width] : expected[index - width + 1]
                        prediction = Specification.predict(
                            mode: mode,
                            l: expected[index - 1],
                            t: expected[index - width],
                            tr: topRight,
                            tl: expected[index - width - 1]
                        )
                    }
                    expected[index] = Specification.add(residuals[index], prediction)
                }
            }

            var actual = residuals
            actual.withUnsafeMutableBufferPointer { buffer in
                var pixels = buffer.mutableSpan
                modes.withUnsafeBufferPointer { modes in
                    InverseTransforms.addPredictions(
                        to: &pixels,
                        width: width,
                        height: height,
                        blockBits: blockBits,
                        blockColumns: blockColumns,
                        modes: modes.span
                    )
                }
            }
            #expect(actual == expected)
        }
    }

    @Test func colorTransformMatchesTheSpecification() {
        var generator = SplitMix64(state: 0x434F_4C52)
        let width = 37
        let height = 23
        let blockBits = 3
        let blockColumns = (width + 7) >> blockBits
        let blockRows = (height + 7) >> blockBits
        let elements = (0..<(blockColumns * blockRows)).map { _ in generator.pixel() }
        let source = (0..<(width * height)).map { _ in generator.pixel() }

        var expected = source
        for y in 0..<height {
            for x in 0..<width {
                let element = elements[(y >> blockBits) * blockColumns + (x >> blockBits)]
                let greenToRed = UInt8(truncatingIfNeeded: element)
                let greenToBlue = UInt8(truncatingIfNeeded: element >> 8)
                let redToBlue = UInt8(truncatingIfNeeded: element >> 16)

                let pixel = source[y * width + x]
                let green = UInt8(truncatingIfNeeded: pixel >> 8)
                let red = Int((pixel >> 16) & 0xFF) + Specification.delta(greenToRed, green)
                var blue = Int(pixel & 0xFF) + Specification.delta(greenToBlue, green)
                blue += Specification.delta(redToBlue, UInt8(truncatingIfNeeded: red))

                expected[y * width + x] =
                    (pixel & 0xFF00_FF00) | UInt32(red & 0xFF) << 16 | UInt32(blue & 0xFF)
            }
        }

        var actual = source
        actual.withUnsafeMutableBufferPointer { buffer in
            var pixels = buffer.mutableSpan
            elements.withUnsafeBufferPointer { elements in
                InverseTransforms.addColorDeltas(
                    to: &pixels,
                    width: width,
                    height: height,
                    blockBits: blockBits,
                    blockColumns: blockColumns,
                    elements: elements.span
                )
            }
        }
        #expect(actual == expected)
    }

    @Test func subtractGreenAddsGreenToRedAndBlue() {
        var pixels: [UInt32] = [0x10F0_8020, 0xFF00_FFFF]
        let count = pixels.count
        pixels.withUnsafeMutableBufferPointer { buffer in
            var span = buffer.mutableSpan
            InverseTransforms.addGreen(to: &span, count: count)
        }
        #expect(pixels == [0x1070_80A0, 0xFFFF_FFFE])
    }

    @Test(arguments: [(3, 2), (2, 4), (1, 16), (0, 256)])
    func colorIndexesExpandFromPackedRows(widthBits: Int, colorCount: Int) {
        var generator = SplitMix64(state: UInt64(widthBits) + 0x494E_4458)
        let width = 29
        let height = 7
        let bundleSize = 1 << widthBits
        let packedWidth = (width + bundleSize - 1) >> widthBits
        let bitsPerIndex = 8 >> widthBits

        var colors = [UInt32](repeating: 0, count: 256)
        for index in 0..<colorCount {
            colors[index] = generator.pixel()
        }

        var indexes = [Int](repeating: 0, count: width * height)
        var packed = [UInt32](repeating: 0xFF00_0000, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = generator.next(below: colorCount)
                indexes[y * width + x] = index
                let shift = UInt32((x & (bundleSize - 1)) * bitsPerIndex)
                packed[y * packedWidth + (x >> widthBits)] |= UInt32(index) << (8 + shift)
            }
        }

        packed.withUnsafeMutableBufferPointer { buffer in
            var pixels = buffer.mutableSpan
            colors.withUnsafeBufferPointer { colors in
                InverseTransforms.expandColorIndexes(
                    in: &pixels,
                    width: width,
                    packedWidth: packedWidth,
                    height: height,
                    widthBits: widthBits,
                    colors: colors.span
                )
            }
        }
        #expect(packed == indexes.map { colors[$0] })
    }
}

@Suite("Pixel conversion")
struct PixelConversionTests {
    @Test func premultiplicationRoundsToTheNearestValue() {
        for value in UInt32(0)...255 {
            for alpha in UInt32(0)...255 {
                let expected = (value * alpha * 2 + 255) / 510
                #expect(PixelConversion.multiply(value, by: alpha) == expected)
            }
        }
    }
}
