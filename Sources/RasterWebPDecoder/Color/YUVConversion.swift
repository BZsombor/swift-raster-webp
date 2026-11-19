/// Converts decoded YUV 4:2:0 planes into ARGB pixels.
///
/// Neither WebP specification defines this step. The conversion uses the BT.601 limited-range
/// factors in 14-bit fixed point, and its rounding offsets are chosen to reproduce `dwebp` exactly,
/// as `Scripts/fit-yuv-offsets.py` determines. Chroma is upsampled bilinearly, weighting the
/// nearest sample 9, its horizontal and vertical neighbors 3 and the diagonal one 1.
enum YUVConversion {
    private static var lumaFactor: Int32 { 19077 }
    private static var redFromV: Int32 { 26149 }
    private static var greenFromU: Int32 { 6419 }
    private static var greenFromV: Int32 { 13320 }
    private static var blueFromU: Int32 { 33050 }
    private static var redOffset: Int32 { -14234 }
    private static var greenOffset: Int32 { 8708 }
    private static var blueOffset: Int32 { -17685 }

    /// Converts one row, interpolating the vertically blended chroma rows horizontally.
    @inline(always)
    static func convertRow(
        luma: Span<UInt8>,
        lumaStart: Int,
        uRow: borrowing MutableSpan<Int32>,
        vRow: borrowing MutableSpan<Int32>,
        width: Int,
        alpha: Span<UInt8>,
        into pixels: inout MutableSpan<UInt32>,
        at start: Int
    ) {
        let hasAlpha = !alpha.isEmpty
        let lastChroma = (width &- 1) &>> 1
        var column = 0
        for index in 0...lastChroma {
            let u3 = 3 &* uRow[index]
            let v3 = 3 &* vRow[index]
            let left = max(index &- 1, 0)
            let right = min(index &+ 1, lastChroma)

            // The even column interpolates toward the left sample, the odd one toward the right.
            let pixelAlpha = hasAlpha ? UInt32(alpha[start &+ column]) : 255
            pixels[start &+ column] = pixel(
                y: Int32(luma[lumaStart &+ column]),
                u: (u3 &+ uRow[left] &+ 8) &>> 4,
                v: (v3 &+ vRow[left] &+ 8) &>> 4,
                alpha: pixelAlpha
            )
            column &+= 1
            if column < width {
                let nextAlpha = hasAlpha ? UInt32(alpha[start &+ column]) : 255
                pixels[start &+ column] = pixel(
                    y: Int32(luma[lumaStart &+ column]),
                    u: (u3 &+ uRow[right] &+ 8) &>> 4,
                    v: (v3 &+ vRow[right] &+ 8) &>> 4,
                    alpha: nextAlpha
                )
                column &+= 1
            }
        }
    }

    /// Converts one YUV sample to an ARGB pixel.
    @inline(always)
    static func pixel(y: Int32, u: Int32, v: Int32, alpha: UInt32) -> UInt32 {
        @inline(always) func scaled(_ value: Int32, _ factor: Int32) -> Int32 {
            (value &* factor) &>> 8
        }
        @inline(always) func channel(_ value: Int32) -> UInt32 {
            UInt32(truncatingIfNeeded: min(max(value &>> 6, 0), 255))
        }
        let base = scaled(y, lumaFactor)
        let red = channel(base &+ scaled(v, redFromV) &+ redOffset)
        let green = channel(base &- scaled(u, greenFromU) &- scaled(v, greenFromV) &+ greenOffset)
        let blue = channel(base &+ scaled(u, blueFromU) &+ blueOffset)
        return alpha &<< 24 | red &<< 16 | green &<< 8 | blue
    }
}

/// Converts the rows of a VP8 frame to ARGB pixels as the decoder delivers them.
///
/// Every output row blends its nearest chroma row with the one above or below it. The decoder
/// delivers rows in batches, so the last chroma row of each batch is kept for the next one, and
/// a final odd luma row waits until the chroma row below it arrives.
struct YUVRowConverter {
    private let width: Int
    private let height: Int
    private let chromaWidth: Int
    private let lastChromaRow: Int
    private var uRow: [Int32]
    private var vRow: [Int32]
    private var previousU: [UInt8]
    private var previousV: [UInt8]
    private var deferredLuma: [UInt8]
    private var deferredRow = -1

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        chromaWidth = (width + 1) / 2
        lastChromaRow = (height - 1) / 2
        uRow = [Int32](repeating: 0, count: chromaWidth)
        vRow = [Int32](repeating: 0, count: chromaWidth)
        previousU = [UInt8](repeating: 0, count: chromaWidth)
        previousV = [UInt8](repeating: 0, count: chromaWidth)
        deferredLuma = [UInt8](repeating: 0, count: width)
    }

    /// Converts the rows of one batch into `pixels`, which holds the whole image.
    ///
    /// - Parameter alpha: One alpha value per pixel of the image, or an empty span.
    mutating func convert(
        luma: Span<UInt8>,
        u: Span<UInt8>,
        v: Span<UInt8>,
        rows: DecodedRows,
        alpha: Span<UInt8>,
        into pixels: inout MutableSpan<UInt32>
    ) {
        var uStorage: [Int32] = []
        var vStorage: [Int32] = []
        var previousUStorage: [UInt8] = []
        var previousVStorage: [UInt8] = []
        var deferredStorage: [UInt8] = []
        swap(&uStorage, &uRow)
        swap(&vStorage, &vRow)
        swap(&previousUStorage, &previousU)
        swap(&previousVStorage, &previousV)
        swap(&deferredStorage, &deferredLuma)
        defer {
            swap(&uStorage, &uRow)
            swap(&vStorage, &vRow)
            swap(&previousUStorage, &previousU)
            swap(&previousVStorage, &previousV)
            swap(&deferredStorage, &deferredLuma)
        }

        uStorage.withMutableElementSpan { uRow in
            vStorage.withMutableElementSpan { vRow in
                previousUStorage.withMutableElementSpan { previousU in
                    previousVStorage.withMutableElementSpan { previousV in
                        deferredStorage.withMutableElementSpan { deferred in
                            convert(
                                luma: luma,
                                u: u,
                                v: v,
                                rows: rows,
                                alpha: alpha,
                                into: &pixels,
                                uRow: &uRow,
                                vRow: &vRow,
                                previousU: &previousU,
                                previousV: &previousV,
                                deferred: &deferred
                            )
                        }
                    }
                }
            }
        }
    }

    private mutating func convert(
        luma: Span<UInt8>,
        u: Span<UInt8>,
        v: Span<UInt8>,
        rows: DecodedRows,
        alpha: Span<UInt8>,
        into pixels: inout MutableSpan<UInt32>,
        uRow: inout MutableSpan<Int32>,
        vRow: inout MutableSpan<Int32>,
        previousU: inout MutableSpan<UInt8>,
        previousV: inout MutableSpan<UInt8>,
        deferred: inout MutableSpan<UInt8>
    ) {
        let firstChroma = rows.firstRow / 2
        let endChroma = firstChroma + rows.rowCount / 2
        @inline(always) func start(_ chromaRow: Int) -> Int {
            rows.chromaStart &+ (chromaRow &- firstChroma) &* rows.chromaStride
        }

        // The deferred row's nearest chroma row ended the previous batch.
        if deferredRow >= 0 {
            let other = start(firstChroma)
            for index in 0..<chromaWidth {
                uRow[index] = 3 &* Int32(previousU[index]) &+ Int32(u[other &+ index])
                vRow[index] = 3 &* Int32(previousV[index]) &+ Int32(v[other &+ index])
            }
            YUVConversion.convertRow(
                luma: deferred.span,
                lumaStart: 0,
                uRow: uRow,
                vRow: vRow,
                width: width,
                alpha: alpha,
                into: &pixels,
                at: deferredRow &* width
            )
            deferredRow = -1
        }

        for line in 0..<rows.rowCount {
            let row = rows.firstRow &+ line
            guard row < height else {
                break
            }
            let lumaStart = rows.lumaStart &+ line &* rows.lumaStride
            let nearest = row &>> 1
            let other = row & 1 == 1 ? min(nearest &+ 1, lastChromaRow) : max(nearest &- 1, 0)

            if other >= endChroma {
                for column in 0..<width {
                    deferred[column] = luma[lumaStart &+ column]
                }
                deferredRow = row
                break
            }

            let nearestStart = start(nearest)
            if other >= firstChroma {
                let otherStart = start(other)
                for index in 0..<chromaWidth {
                    uRow[index] = 3 &* Int32(u[nearestStart &+ index]) &+ Int32(u[otherStart &+ index])
                    vRow[index] = 3 &* Int32(v[nearestStart &+ index]) &+ Int32(v[otherStart &+ index])
                }
            } else {
                for index in 0..<chromaWidth {
                    uRow[index] = 3 &* Int32(u[nearestStart &+ index]) &+ Int32(previousU[index])
                    vRow[index] = 3 &* Int32(v[nearestStart &+ index]) &+ Int32(previousV[index])
                }
            }
            YUVConversion.convertRow(
                luma: luma,
                lumaStart: lumaStart,
                uRow: uRow,
                vRow: vRow,
                width: width,
                alpha: alpha,
                into: &pixels,
                at: row &* width
            )
        }

        let last = start(endChroma &- 1)
        for index in 0..<chromaWidth {
            previousU[index] = u[last &+ index]
            previousV[index] = v[last &+ index]
        }
    }
}
