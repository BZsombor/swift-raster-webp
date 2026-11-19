internal import RasterWebPCore

/// Decodes the alpha plane of an `ALPH` chunk, RFC 9649 section 2.7.1.2.
enum AlphaDecoder {
    /// Decodes the alpha values into the top byte of `pixels`, one pixel per value in scan-line
    /// order, and clears the other bytes.
    ///
    /// The plane needs no storage of its own: a lossless stream decodes straight into `pixels`,
    /// and its green channel moves to the alpha byte.
    static func decode(
        input: Span<UInt8>,
        payload: Range<Int>,
        width: Int,
        height: Int,
        budget: MemoryBudget,
        into pixels: inout MutableSpan<UInt32>
    ) throws(WebPError) {
        guard !payload.isEmpty else {
            throw WebPError(.alphaDataTooShort)
        }
        let header = input[payload.lowerBound]
        let compression = header & 0b11
        let filter = (header >> 2) & 0b11
        let data = (payload.lowerBound + 1)..<payload.upperBound
        let pixelCount = width * height

        switch compression {
        case 0:
            guard data.count >= pixelCount else {
                throw WebPError(.alphaDataTooShort)
            }
            for index in 0..<pixelCount {
                pixels[index] = UInt32(input[data.lowerBound &+ index]) &<< 24
            }
        case 1:
            // The lossless stream has no header, and its green channel holds the alpha values.
            try LosslessDecoder.decode(
                input: input,
                bitstream: data,
                width: width,
                height: height,
                budget: budget,
                into: &pixels
            )
            for index in 0..<pixelCount {
                pixels[index] = (pixels[index] & 0xFF00) &<< 16
            }
        default:
            throw WebPError(.alphaInvalidCompression)
        }

        unfilter(&pixels, width: width, height: height, method: filter)
    }

    /// Reverses the alpha filter, where every value was stored as a difference from a prediction.
    ///
    /// The values are in the top byte of each pixel, and the other bytes must be zero.
    static func unfilter(_ alpha: inout MutableSpan<UInt32>, width: Int, height: Int, method: UInt8) {
        guard method != 0 else {
            return
        }
        // Adding in the top byte wraps modulo 256 and leaves the zero bytes below it alone.
        @inline(always) func add(_ value: UInt32, _ prediction: UInt32) -> UInt32 {
            value &+ prediction
        }

        // The first pixel is predicted from zero, the rest of the first row from the left.
        for column in 1..<max(width, 1) {
            alpha[column] = add(alpha[column], alpha[column &- 1])
        }

        for row in 1..<max(height, 1) {
            let start = row &* width
            let above = start &- width

            // The first pixel of every other row is predicted from the pixel above it.
            alpha[start] = add(alpha[start], alpha[above])

            for column in 1..<max(width, 1) {
                let left = alpha[start &+ column &- 1]
                let top = alpha[above &+ column]
                let prediction: UInt32
                switch method {
                case 1: prediction = left
                case 2: prediction = top
                default:
                    let topLeft = Int32(alpha[above &+ column &- 1] &>> 24)
                    let gradient = Int32(left &>> 24) &+ Int32(top &>> 24) &- topLeft
                    prediction = UInt32(min(max(gradient, 0), 255)) &<< 24
                }
                alpha[start &+ column] = add(alpha[start &+ column], prediction)
            }
        }
    }
}
