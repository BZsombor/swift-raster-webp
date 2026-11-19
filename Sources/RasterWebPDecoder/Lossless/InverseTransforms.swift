/// An inverse transform that restores the pixels of a VP8L image.
enum InverseTransform {
    case predictor(blockBits: Int, blockColumns: Int, width: Int, modes: [UInt32])
    case color(blockBits: Int, blockColumns: Int, width: Int, elements: [UInt32])
    case subtractGreen(width: Int)
    case colorIndexing(widthBits: Int, packedWidth: Int, width: Int, colors: [UInt32])

    /// Applies the transform in place to an image of the given height.
    func apply(to pixels: inout MutableSpan<UInt32>, height: Int) {
        switch self {
        case .predictor(let blockBits, let blockColumns, let width, let modes):
            modes.withElementSpan { modes in
                InverseTransforms.addPredictions(
                    to: &pixels,
                    width: width,
                    height: height,
                    blockBits: blockBits,
                    blockColumns: blockColumns,
                    modes: modes
                )
            }
        case .color(let blockBits, let blockColumns, let width, let elements):
            elements.withElementSpan { elements in
                InverseTransforms.addColorDeltas(
                    to: &pixels,
                    width: width,
                    height: height,
                    blockBits: blockBits,
                    blockColumns: blockColumns,
                    elements: elements
                )
            }
        case .subtractGreen(let width):
            InverseTransforms.addGreen(to: &pixels, count: width * height)
        case .colorIndexing(let widthBits, let packedWidth, let width, let colors):
            colors.withElementSpan { colors in
                InverseTransforms.expandColorIndexes(
                    in: &pixels,
                    width: width,
                    packedWidth: packedWidth,
                    height: height,
                    widthBits: widthBits,
                    colors: colors
                )
            }
        }
    }
}

/// The inverse transforms of RFC 9649, section 3.5.
enum InverseTransforms {
    /// Adds two pixels channel by channel.
    @inline(always)
    static func add(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let alphaGreen = (a & 0xFF00_FF00) &+ (b & 0xFF00_FF00)
        let redBlue = (a & 0x00FF_00FF) &+ (b & 0x00FF_00FF)
        return (alphaGreen & 0xFF00_FF00) | (redBlue & 0x00FF_00FF)
    }

    /// Averages two pixels channel by channel, rounding down.
    @inline(always)
    static func average(_ a: UInt32, _ b: UInt32) -> UInt32 {
        (((a ^ b) & 0xFEFE_FEFE) &>> 1) &+ (a & b)
    }

    /// Returns one color channel of a pixel as a signed value.
    @inline(always)
    private static func channel(_ pixel: UInt32, _ shift: UInt32) -> Int32 {
        Int32(truncatingIfNeeded: (pixel &>> shift) & 0xFF)
    }

    /// Limits a value to the range of a color channel and moves it to its position in a pixel.
    @inline(always)
    private static func clamped(_ value: Int32, _ shift: UInt32) -> UInt32 {
        UInt32(truncatingIfNeeded: min(max(value, 0), 255)) &<< shift
    }

    /// Chooses the left or top pixel, whichever is closer to the gradient estimate.
    @inline(always)
    static func select(left: UInt32, top: UInt32, topLeft: UInt32) -> UInt32 {
        // The estimate is l + t - tl, so its distance to l is |t - tl| and to t is |l - tl|.
        @inline(always) func distance(_ a: UInt32, _ b: UInt32, _ shift: UInt32) -> Int32 {
            abs(channel(a, shift) &- channel(b, shift))
        }
        let leftDistance =
            distance(top, topLeft, 0) &+ distance(top, topLeft, 8)
            &+ distance(top, topLeft, 16) &+ distance(top, topLeft, 24)
        let topDistance =
            distance(left, topLeft, 0) &+ distance(left, topLeft, 8)
            &+ distance(left, topLeft, 16) &+ distance(left, topLeft, 24)
        return leftDistance < topDistance ? left : top
    }

    /// Clamps `a + b - c` for each channel.
    @inline(always)
    static func clampAddSubtractFull(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        @inline(always) func value(_ shift: UInt32) -> UInt32 {
            clamped(channel(a, shift) &+ channel(b, shift) &- channel(c, shift), shift)
        }
        return value(0) | value(8) | value(16) | value(24)
    }

    /// Clamps `a + (a - b) / 2` for each channel, with division rounding toward zero.
    @inline(always)
    static func clampAddSubtractHalf(_ a: UInt32, _ b: UInt32) -> UInt32 {
        @inline(always) func value(_ shift: UInt32) -> UInt32 {
            let x = channel(a, shift)
            return clamped(x &+ (x &- channel(b, shift)) / 2, shift)
        }
        return value(0) | value(8) | value(16) | value(24)
    }

    /// Returns the predicted pixel for a prediction mode.
    @inline(always)
    static func predict(
        mode: UInt32,
        left: UInt32,
        top: UInt32,
        topRight: UInt32,
        topLeft: UInt32
    ) -> UInt32 {
        switch mode {
        case 1: left
        case 2: top
        case 3: topRight
        case 4: topLeft
        case 5: average(average(left, topRight), top)
        case 6: average(left, topLeft)
        case 7: average(left, top)
        case 8: average(topLeft, top)
        case 9: average(top, topRight)
        case 10: average(average(left, topLeft), average(top, topRight))
        case 11: select(left: left, top: top, topLeft: topLeft)
        case 12: clampAddSubtractFull(left, top, topLeft)
        case 13: clampAddSubtractHalf(average(left, top), topLeft)
        // Mode 0 is solid black. The format leaves modes 14 and 15 undefined, and existing
        // decoders treat them the same way.
        default: 0xFF00_0000
        }
    }

    /// Reverses the predictor transform.
    static func addPredictions(
        to pixels: inout MutableSpan<UInt32>,
        width: Int,
        height: Int,
        blockBits: Int,
        blockColumns: Int,
        modes: Span<UInt32>
    ) {
        // The top-left pixel is predicted as black, and the rest of the top row from the left.
        pixels[0] = add(pixels[0], 0xFF00_0000)
        var column = 1
        while column < width {
            pixels[column] = add(pixels[column], pixels[column &- 1])
            column &+= 1
        }

        var row = 1
        while row < height {
            let rowStart = row &* width

            // The leftmost pixel of every other row is predicted from the pixel above it.
            pixels[rowStart] = add(pixels[rowStart], pixels[rowStart &- width])

            let modeRow = (row &>> blockBits) &* blockColumns
            var start = 1
            while start < width {
                let block = start &>> blockBits
                let end = min((block &+ 1) &<< blockBits, width)
                let mode = (modes[modeRow &+ block] &>> 8) & 0xF
                addPredictions(
                    to: &pixels,
                    mode: mode,
                    range: (rowStart &+ start)..<(rowStart &+ end),
                    width: width
                )
                start = end
            }
            row &+= 1
        }
    }

    /// Restores a run of pixels that share a prediction mode.
    ///
    /// Every mode has its own loop, so the mode is not examined again for each pixel.
    private static func addPredictions(
        to pixels: inout MutableSpan<UInt32>,
        mode: UInt32,
        range: Range<Int>,
        width: Int
    ) {
        switch mode {
        case 1: restore(&pixels, range, width) { predict(mode: 1, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 2: restore(&pixels, range, width) { predict(mode: 2, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 3: restore(&pixels, range, width) { predict(mode: 3, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 4: restore(&pixels, range, width) { predict(mode: 4, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 5: restore(&pixels, range, width) { predict(mode: 5, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 6: restore(&pixels, range, width) { predict(mode: 6, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 7: restore(&pixels, range, width) { predict(mode: 7, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 8: restore(&pixels, range, width) { predict(mode: 8, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 9: restore(&pixels, range, width) { predict(mode: 9, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 10: restore(&pixels, range, width) { predict(mode: 10, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 11: restore(&pixels, range, width) { predict(mode: 11, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 12: restore(&pixels, range, width) { predict(mode: 12, left: $0, top: $1, topRight: $2, topLeft: $3) }
        case 13: restore(&pixels, range, width) { predict(mode: 13, left: $0, top: $1, topRight: $2, topLeft: $3) }
        default: restore(&pixels, range, width) { _, _, _, _ in 0xFF00_0000 }
        }
    }

    /// Adds predictions to a run of residuals.
    ///
    /// Rows are stored contiguously, so the top-right neighbor of a row's last pixel is the
    /// first pixel of the current row, which is the position the format requires.
    @inline(always)
    private static func restore(
        _ pixels: inout MutableSpan<UInt32>,
        _ range: Range<Int>,
        _ width: Int,
        _ prediction: (_ left: UInt32, _ top: UInt32, _ topRight: UInt32, _ topLeft: UInt32) -> UInt32
    ) {
        var left = pixels[range.lowerBound &- 1]
        var index = range.lowerBound
        while index < range.upperBound {
            let top = index &- width
            left = add(pixels[index], prediction(left, pixels[top], pixels[top &+ 1], pixels[top &- 1]))
            pixels[index] = left
            index &+= 1
        }
    }

    /// Computes the color transform delta for a signed multiplier and color channel.
    @inline(always)
    private static func colorDelta(_ multiplier: Int32, _ channel: UInt32) -> Int32 {
        (multiplier &* Int32(Int8(truncatingIfNeeded: channel))) &>> 5
    }

    /// Reverses the color transform.
    static func addColorDeltas(
        to pixels: inout MutableSpan<UInt32>,
        width: Int,
        height: Int,
        blockBits: Int,
        blockColumns: Int,
        elements: Span<UInt32>
    ) {
        var row = 0
        while row < height {
            let rowStart = row &* width
            let elementRow = (row &>> blockBits) &* blockColumns
            var start = 0
            while start < width {
                let block = start &>> blockBits
                let end = min((block &+ 1) &<< blockBits, width)
                let element = elements[elementRow &+ block]
                let greenToRed = Int32(Int8(truncatingIfNeeded: element))
                let greenToBlue = Int32(Int8(truncatingIfNeeded: element &>> 8))
                let redToBlue = Int32(Int8(truncatingIfNeeded: element &>> 16))

                var index = rowStart &+ start
                let blockEnd = rowStart &+ end
                while index < blockEnd {
                    let pixel = pixels[index]
                    let green = pixel &>> 8
                    let red =
                        UInt32(
                            truncatingIfNeeded: Int32(truncatingIfNeeded: pixel &>> 16) &+ colorDelta(greenToRed, green)
                        ) & 0xFF
                    var blue = Int32(truncatingIfNeeded: pixel & 0xFF)
                    blue &+= colorDelta(greenToBlue, green)
                    blue &+= colorDelta(redToBlue, red)
                    pixels[index] = (pixel & 0xFF00_FF00) | (red &<< 16) | (UInt32(truncatingIfNeeded: blue) & 0xFF)
                    index &+= 1
                }
                start = end
            }
            row &+= 1
        }
    }

    /// Reverses the subtract green transform.
    static func addGreen(to pixels: inout MutableSpan<UInt32>, count: Int) {
        var index = 0
        while index < count {
            let pixel = pixels[index]
            let green = (pixel &>> 8) & 0xFF
            let redBlue = (pixel & 0x00FF_00FF) &+ (green &<< 16 | green)
            pixels[index] = (pixel & 0xFF00_FF00) | (redBlue & 0x00FF_00FF)
            index &+= 1
        }
    }

    /// Replaces color indexes with colors and unpacks bundled pixels.
    ///
    /// Rows are expanded from the end of the image, so a packed value is always read before
    /// its position can be overwritten.
    static func expandColorIndexes(
        in pixels: inout MutableSpan<UInt32>,
        width: Int,
        packedWidth: Int,
        height: Int,
        widthBits: Int,
        colors: Span<UInt32>
    ) {
        let bitsPerIndex = 8 &>> widthBits
        let indexMask = UInt32(truncatingIfNeeded: (1 &<< bitsPerIndex) &- 1)
        let columnMask = (1 &<< widthBits) &- 1

        var row = height &- 1
        while row >= 0 {
            let packedRow = row &* packedWidth
            let outputRow = row &* width
            var column = width &- 1
            while column >= 0 {
                let packed = (pixels[packedRow &+ (column &>> widthBits)] &>> 8) & 0xFF
                let shift = UInt32(truncatingIfNeeded: (column & columnMask) &* bitsPerIndex)
                let index = (packed &>> shift) & indexMask
                pixels[outputRow &+ column] = colors[Int(truncatingIfNeeded: index)]
                column &-= 1
            }
            row &-= 1
        }
    }
}
