/// The loop filters of RFC 6386, section 15.
///
/// Each function filters the segments that straddle one edge. `index` is the first pixel after
/// the edge, `step` moves across the edge, and `along` moves to the next segment.
enum VP8LoopFilter {
    /// Clamps to the signed 8-bit range, the `c` function of section 15.2.
    @inline(always)
    private static func clamp(_ value: Int32) -> Int32 {
        min(max(value, -128), 127)
    }

    /// Converts a pixel to the signed representation.
    @inline(always)
    private static func signed(_ pixel: UInt8) -> Int32 {
        Int32(pixel) &- 128
    }

    /// Clamps a signed value and converts it back to a pixel.
    @inline(always)
    private static func pixel(_ value: Int32) -> UInt8 {
        UInt8(truncatingIfNeeded: clamp(value) &+ 128)
    }

    /// Moves the two pixels next to the edge closer together and returns the adjustment.
    @inline(always)
    private static func commonAdjust(
        _ pixels: inout MutableSpan<UInt8>,
        _ index: Int,
        _ step: Int,
        usesOuterTaps: Bool
    ) -> Int32 {
        let p1 = signed(pixels[index &- 2 &* step])
        let p0 = signed(pixels[index &- step])
        let q0 = signed(pixels[index])
        let q1 = signed(pixels[index &+ step])

        var a = clamp((usesOuterTaps ? clamp(p1 &- q1) : 0) &+ 3 &* (q0 &- p0))
        let b = clamp(a &+ 3) &>> 3
        a = clamp(a &+ 4) &>> 3
        pixels[index] = pixel(q0 &- a)
        pixels[index &- step] = pixel(p0 &+ b)
        return a
    }

    /// The simple filter, section 15.2. It only applies to luma.
    static func simpleEdge(
        _ pixels: inout MutableSpan<UInt8>,
        start: Int,
        step: Int,
        along: Int,
        count: Int,
        edgeLimit: Int32
    ) {
        var index = start
        for _ in 0..<count {
            let p1 = Int32(pixels[index &- 2 &* step]), p0 = Int32(pixels[index &- step])
            let q0 = Int32(pixels[index]), q1 = Int32(pixels[index &+ step])
            if abs(p0 &- q0) &* 2 &+ abs(p1 &- q1) &>> 1 <= edgeLimit {
                _ = commonAdjust(&pixels, index, step, usesOuterTaps: true)
            }
            index &+= along
        }
    }

    /// Whether a segment may be filtered, from its 8 pixels: `filter_yes` of section 15.3.
    @inline(always)
    private static func allowsFiltering(
        _ p3: Int32,
        _ p2: Int32,
        _ p1: Int32,
        _ p0: Int32,
        _ q0: Int32,
        _ q1: Int32,
        _ q2: Int32,
        _ q3: Int32,
        edgeLimit: Int32,
        interiorLimit: Int32
    ) -> Bool {
        abs(p0 &- q0) &* 2 &+ abs(p1 &- q1) &>> 1 <= edgeLimit
            && max(abs(p3 &- p2), abs(p2 &- p1), abs(p1 &- p0)) <= interiorLimit
            && max(abs(q3 &- q2), abs(q2 &- q1), abs(q1 &- q0)) <= interiorLimit
    }

    /// The `common_adjust` step of section 15.2 on signed values, returning the new p0, q0 and a.
    @inline(always)
    private static func adjust(
        _ p1: Int32,
        _ p0: Int32,
        _ q0: Int32,
        _ q1: Int32,
        usesOuterTaps: Bool
    ) -> (p0: Int32, q0: Int32, a: Int32) {
        var a = clamp((usesOuterTaps ? clamp(p1 &- q1) : 0) &+ 3 &* (q0 &- p0))
        let b = clamp(a &+ 3) &>> 3
        a = clamp(a &+ 4) &>> 3
        return (p0 &+ b, q0 &- a, a)
    }

    /// The normal filter for edges between subblocks, section 15.3.
    static func subblockEdge(
        _ pixels: inout MutableSpan<UInt8>,
        start: Int,
        step: Int,
        along: Int,
        count: Int,
        strength: FilterStrength,
        edgeLimit: Int32
    ) {
        let interiorLimit = strength.interiorLimit
        let threshold = strength.highEdgeVarianceThreshold
        var index = start
        for _ in 0..<count {
            let p3 = Int32(pixels[index &- 4 &* step]), p2 = Int32(pixels[index &- 3 &* step])
            let p1 = Int32(pixels[index &- 2 &* step]), p0 = Int32(pixels[index &- step])
            let q0 = Int32(pixels[index]), q1 = Int32(pixels[index &+ step])
            let q2 = Int32(pixels[index &+ 2 &* step]), q3 = Int32(pixels[index &+ 3 &* step])

            if allowsFiltering(p3, p2, p1, p0, q0, q1, q2, q3, edgeLimit: edgeLimit, interiorLimit: interiorLimit) {
                let highVariance = abs(p1 &- p0) > threshold || abs(q1 &- q0) > threshold
                let result = adjust(p1 &- 128, p0 &- 128, q0 &- 128, q1 &- 128, usesOuterTaps: highVariance)
                pixels[index &- step] = pixel(result.p0)
                pixels[index] = pixel(result.q0)
                if !highVariance {
                    let a = (result.a &+ 1) &>> 1
                    pixels[index &+ step] = pixel(q1 &- 128 &- a)
                    pixels[index &- 2 &* step] = pixel(p1 &- 128 &+ a)
                }
            }
            index &+= along
        }
    }

    /// The normal filter for edges between macroblocks, section 15.3.
    static func macroblockEdge(
        _ pixels: inout MutableSpan<UInt8>,
        start: Int,
        step: Int,
        along: Int,
        count: Int,
        strength: FilterStrength,
        edgeLimit: Int32
    ) {
        let interiorLimit = strength.interiorLimit
        let threshold = strength.highEdgeVarianceThreshold
        var index = start
        for _ in 0..<count {
            let p3 = Int32(pixels[index &- 4 &* step]), p2 = Int32(pixels[index &- 3 &* step])
            let p1 = Int32(pixels[index &- 2 &* step]), p0 = Int32(pixels[index &- step])
            let q0 = Int32(pixels[index]), q1 = Int32(pixels[index &+ step])
            let q2 = Int32(pixels[index &+ 2 &* step]), q3 = Int32(pixels[index &+ 3 &* step])

            if allowsFiltering(p3, p2, p1, p0, q0, q1, q2, q3, edgeLimit: edgeLimit, interiorLimit: interiorLimit) {
                let sp2 = p2 &- 128, sp1 = p1 &- 128, sp0 = p0 &- 128
                let sq0 = q0 &- 128, sq1 = q1 &- 128, sq2 = q2 &- 128
                if abs(p1 &- p0) > threshold || abs(q1 &- q0) > threshold {
                    let result = adjust(sp1, sp0, sq0, sq1, usesOuterTaps: true)
                    pixels[index &- step] = pixel(result.p0)
                    pixels[index] = pixel(result.q0)
                } else {
                    let w = clamp(clamp(sp1 &- sq1) &+ 3 &* (sq0 &- sp0))
                    var a = clamp((27 &* w &+ 63) &>> 7)
                    pixels[index] = pixel(sq0 &- a)
                    pixels[index &- step] = pixel(sp0 &+ a)
                    a = clamp((18 &* w &+ 63) &>> 7)
                    pixels[index &+ step] = pixel(sq1 &- a)
                    pixels[index &- 2 &* step] = pixel(sp1 &+ a)
                    a = clamp((9 &* w &+ 63) &>> 7)
                    pixels[index &+ 2 &* step] = pixel(sq2 &- a)
                    pixels[index &- 3 &* step] = pixel(sp2 &+ a)
                }
            }
            index &+= along
        }
    }
}
