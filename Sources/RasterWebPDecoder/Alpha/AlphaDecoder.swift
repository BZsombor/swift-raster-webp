internal import RasterWebPCore

/// Decodes the alpha plane of an `ALPH` chunk, RFC 9649 section 2.7.1.2.
enum AlphaDecoder {
    /// Returns one alpha value per pixel in scan-line order.
    static func decode(
        input: Span<UInt8>,
        payload: Range<Int>,
        width: Int,
        height: Int,
        budget: inout MemoryBudget
    ) throws(WebPError) -> [UInt8] {
        guard !payload.isEmpty else {
            throw WebPError(.alphaDataTooShort)
        }
        let header = input[payload.lowerBound]
        let compression = header & 0b11
        let filter = (header >> 2) & 0b11
        let data = (payload.lowerBound + 1)..<payload.upperBound
        let pixelCount = width * height

        try budget.reserve(count: pixelCount, elementSize: 1)
        var alpha = [UInt8](repeating: 0, count: pixelCount)

        switch compression {
        case 0:
            guard data.count >= pixelCount else {
                throw WebPError(.alphaDataTooShort)
            }
            for index in 0..<pixelCount {
                alpha[index] = input[data.lowerBound + index]
            }
        case 1:
            // The lossless stream has no header, and its green channel holds the alpha values.
            try budget.reserve(count: pixelCount, elementSize: MemoryLayout<UInt32>.stride)
            var argb = [UInt32](repeating: 0, count: pixelCount)
            let localBudget = budget
            try argb.withMutableElementSpan { (pixels) throws(WebPError) in
                try LosslessDecoder.decode(
                    input: input,
                    bitstream: data,
                    width: width,
                    height: height,
                    budget: localBudget,
                    into: &pixels
                )
            }
            for index in 0..<pixelCount {
                alpha[index] = UInt8(truncatingIfNeeded: argb[index] >> 8)
            }
        default:
            throw WebPError(.alphaInvalidCompression)
        }

        alpha.withMutableElementSpan { values in
            unfilter(&values, width: width, height: height, method: filter)
        }
        return alpha
    }

    /// Reverses the alpha filter, where every value was stored as a difference from a prediction.
    static func unfilter(_ alpha: inout MutableSpan<UInt8>, width: Int, height: Int, method: UInt8) {
        guard method != 0 else {
            return
        }

        // The first pixel is predicted from zero, the rest of the first row from the left.
        for column in 1..<max(width, 1) {
            alpha[column] = alpha[column] &+ alpha[column &- 1]
        }

        for row in 1..<max(height, 1) {
            let start = row &* width
            let above = start &- width

            // The first pixel of every other row is predicted from the pixel above it.
            alpha[start] = alpha[start] &+ alpha[above]

            for column in 1..<max(width, 1) {
                let left = Int32(alpha[start &+ column &- 1])
                let top = Int32(alpha[above &+ column])
                let prediction: Int32
                switch method {
                case 1: prediction = left
                case 2: prediction = top
                default: prediction = min(max(left &+ top &- Int32(alpha[above &+ column &- 1]), 0), 255)
                }
                alpha[start &+ column] = alpha[start &+ column] &+ UInt8(truncatingIfNeeded: prediction)
            }
        }
    }
}
