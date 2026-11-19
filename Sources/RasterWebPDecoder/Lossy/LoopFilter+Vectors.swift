/// The loop filters of RFC 6386, section 15, on 16 segments at once.
///
/// The functions here filter edges whose segments lie next to each other in memory, so one
/// vector load reads one pixel of every segment. They use the standard library's portable SIMD
/// types and produce the same pixels as the scalar functions in `LoopFilter.swift`.
///
/// The arithmetic stays on unsigned pixel values: differences are the same in the signed
/// representation of the specification, and clamping `x - 128` to the signed range and adding
/// 128 back is clamping `x` to the pixel range.
///
/// Conditions are lane masks of all ones or all zeros, combined with bitwise operations.
/// `SIMDMask` and `replacing(with:where:)` would read the cleaner, but they compile to one
/// branch per lane.
extension VP8LoopFilter {
    typealias Lanes = SIMD16<Int16>

    /// The eight pixels of 16 segments, from the fourth pixel before the edge to the fourth after.
    struct EdgeLanes {
        var p3 = Lanes()
        var p2 = Lanes()
        var p1 = Lanes()
        var p0 = Lanes()
        var q0 = Lanes()
        var q1 = Lanes()
        var q2 = Lanes()
        var q3 = Lanes()
    }

    // MARK: Edges

    /// The simple filter across a horizontal luma edge, 16 pixels wide.
    static func simpleHorizontalEdge(
        _ pixels: inout MutableSpan<UInt8>,
        start: Int,
        stride: Int,
        edgeLimit: Int32
    ) {
        let p1 = load(pixels, start &- 2 &* stride)
        let p0 = load(pixels, start &- stride)
        let q0 = load(pixels, start)
        let q1 = load(pixels, start &+ stride)
        let mask = ~greater(edgeDifference(p1, p0, q0, q1), Lanes(repeating: Int16(edgeLimit)))
        guard isAnySet(mask) else {
            return
        }
        let w = clampSigned(clampSigned(p1 &- q1) &+ 3 &* (q0 &- p0))
        let newP0 = clampPixel(p0 &+ (clampSigned(w &+ 3) &>> 3))
        let newQ0 = clampPixel(q0 &- (clampSigned(w &+ 4) &>> 3))
        store(select(mask, newP0, p0), &pixels, start &- stride)
        store(select(mask, newQ0, q0), &pixels, start)
    }

    /// The normal filter across a horizontal luma edge, 16 pixels wide.
    static func normalHorizontalEdge(
        _ pixels: inout MutableSpan<UInt8>,
        start: Int,
        stride: Int,
        strength: FilterStrength,
        edgeLimit: Int32,
        isMacroblockEdge: Bool
    ) {
        var lanes = EdgeLanes()
        lanes.p3 = load(pixels, start &- 4 &* stride)
        lanes.p2 = load(pixels, start &- 3 &* stride)
        lanes.p1 = load(pixels, start &- 2 &* stride)
        lanes.p0 = load(pixels, start &- stride)
        lanes.q0 = load(pixels, start)
        lanes.q1 = load(pixels, start &+ stride)
        lanes.q2 = load(pixels, start &+ 2 &* stride)
        lanes.q3 = load(pixels, start &+ 3 &* stride)
        guard filter(&lanes, strength: strength, edgeLimit: edgeLimit, isMacroblockEdge: isMacroblockEdge)
        else {
            return
        }
        if isMacroblockEdge {
            store(lanes.p2, &pixels, start &- 3 &* stride)
            store(lanes.q2, &pixels, start &+ 2 &* stride)
        }
        store(lanes.p1, &pixels, start &- 2 &* stride)
        store(lanes.p0, &pixels, start &- stride)
        store(lanes.q0, &pixels, start)
        store(lanes.q1, &pixels, start &+ stride)
    }

    /// The normal filter across a horizontal edge of both chroma planes, 8 pixels wide each.
    static func normalHorizontalEdge(
        u: inout MutableSpan<UInt8>,
        v: inout MutableSpan<UInt8>,
        start: Int,
        stride: Int,
        strength: FilterStrength,
        edgeLimit: Int32,
        isMacroblockEdge: Bool
    ) {
        var lanes = EdgeLanes()
        lanes.p3 = load(u, v, start &- 4 &* stride)
        lanes.p2 = load(u, v, start &- 3 &* stride)
        lanes.p1 = load(u, v, start &- 2 &* stride)
        lanes.p0 = load(u, v, start &- stride)
        lanes.q0 = load(u, v, start)
        lanes.q1 = load(u, v, start &+ stride)
        lanes.q2 = load(u, v, start &+ 2 &* stride)
        lanes.q3 = load(u, v, start &+ 3 &* stride)
        guard filter(&lanes, strength: strength, edgeLimit: edgeLimit, isMacroblockEdge: isMacroblockEdge)
        else {
            return
        }
        if isMacroblockEdge {
            store(lanes.p2, &u, &v, start &- 3 &* stride)
            store(lanes.q2, &u, &v, start &+ 2 &* stride)
        }
        store(lanes.p1, &u, &v, start &- 2 &* stride)
        store(lanes.p0, &u, &v, start &- stride)
        store(lanes.q0, &u, &v, start)
        store(lanes.q1, &u, &v, start &+ stride)
    }

    /// The simple filter across a vertical luma edge, 16 pixels tall.
    static func simpleVerticalEdge(
        _ pixels: inout MutableSpan<UInt8>,
        start: Int,
        stride: Int,
        edgeLimit: Int32
    ) {
        var lanes = loadColumns(pixels, start: start, stride: stride)
        let p1 = lanes.p1, p0 = lanes.p0, q0 = lanes.q0, q1 = lanes.q1
        let mask = ~greater(edgeDifference(p1, p0, q0, q1), Lanes(repeating: Int16(edgeLimit)))
        guard isAnySet(mask) else {
            return
        }
        let w = clampSigned(clampSigned(p1 &- q1) &+ 3 &* (q0 &- p0))
        lanes.p0 = select(mask, clampPixel(p0 &+ (clampSigned(w &+ 3) &>> 3)), p0)
        lanes.q0 = select(mask, clampPixel(q0 &- (clampSigned(w &+ 4) &>> 3)), q0)
        storeColumns(lanes, &pixels, start: start, stride: stride)
    }

    /// The normal filter across a vertical luma edge, 16 pixels tall.
    static func normalVerticalEdge(
        _ pixels: inout MutableSpan<UInt8>,
        start: Int,
        stride: Int,
        strength: FilterStrength,
        edgeLimit: Int32,
        isMacroblockEdge: Bool
    ) {
        var lanes = loadColumns(pixels, start: start, stride: stride)
        guard filter(&lanes, strength: strength, edgeLimit: edgeLimit, isMacroblockEdge: isMacroblockEdge)
        else {
            return
        }
        storeColumns(lanes, &pixels, start: start, stride: stride)
    }

    /// The normal filter across a vertical edge of both chroma planes, 8 pixels tall each.
    static func normalVerticalEdge(
        u: inout MutableSpan<UInt8>,
        v: inout MutableSpan<UInt8>,
        start: Int,
        stride: Int,
        strength: FilterStrength,
        edgeLimit: Int32,
        isMacroblockEdge: Bool
    ) {
        var lanes = loadColumns(u, v, start: start, stride: stride)
        guard filter(&lanes, strength: strength, edgeLimit: edgeLimit, isMacroblockEdge: isMacroblockEdge)
        else {
            return
        }
        storeColumns(lanes, &u, &v, start: start, stride: stride)
    }

    // MARK: Filters

    /// Applies the normal filter, section 15.3, and returns whether any segment changed.
    @inline(always)
    private static func filter(
        _ lanes: inout EdgeLanes,
        strength: FilterStrength,
        edgeLimit: Int32,
        isMacroblockEdge: Bool
    ) -> Bool {
        let p2 = lanes.p2, p1 = lanes.p1, p0 = lanes.p0
        let q0 = lanes.q0, q1 = lanes.q1, q2 = lanes.q2

        // `filter_yes`: the edge difference and every interior difference are small enough.
        let p1p0 = absoluteDifference(p1, p0)
        let q1q0 = absoluteDifference(q1, q0)
        let interior = absoluteDifference(lanes.p3, p2).lanewiseMaximum(absoluteDifference(p2, p1))
            .lanewiseMaximum(absoluteDifference(lanes.q3, q2).lanewiseMaximum(absoluteDifference(q2, q1)))
            .lanewiseMaximum(p1p0.lanewiseMaximum(q1q0))
        let mask = ~(
            greater(edgeDifference(p1, p0, q0, q1), Lanes(repeating: Int16(edgeLimit)))
                | greater(interior, Lanes(repeating: Int16(strength.interiorLimit))))
        guard isAnySet(mask) else {
            return false
        }

        let highVariance = greater(
            p1p0.lanewiseMaximum(q1q0), Lanes(repeating: Int16(strength.highEdgeVarianceThreshold)))
        let lowVariance = mask & ~highVariance
        let outerTaps = clampSigned(p1 &- q1)
        let inner = 3 &* (q0 &- p0)

        if isMacroblockEdge {
            // High variance segments only move p0 and q0, the others spread the change over 6 pixels.
            let w = clampSigned(outerTaps &+ inner)
            let a = clampSigned(w &+ 4) &>> 3
            let b = clampSigned(w &+ 3) &>> 3
            let highMask = mask & highVariance
            let near = clampSigned((27 &* w &+ 63) &>> 7)
            let middle = clampSigned((18 &* w &+ 63) &>> 7)
            let far = clampSigned((9 &* w &+ 63) &>> 7)
            lanes.p0 = select(lowVariance, clampPixel(p0 &+ near), select(highMask, clampPixel(p0 &+ b), p0))
            lanes.q0 = select(lowVariance, clampPixel(q0 &- near), select(highMask, clampPixel(q0 &- a), q0))
            lanes.p1 = select(lowVariance, clampPixel(p1 &+ middle), p1)
            lanes.q1 = select(lowVariance, clampPixel(q1 &- middle), q1)
            lanes.p2 = select(lowVariance, clampPixel(p2 &+ far), p2)
            lanes.q2 = select(lowVariance, clampPixel(q2 &- far), q2)
        } else {
            // Only high variance segments use the outer taps, and the others also move p1 and q1.
            let w = clampSigned((outerTaps & highVariance) &+ inner)
            let a = clampSigned(w &+ 4) &>> 3
            let b = clampSigned(w &+ 3) &>> 3
            let outer = (a &+ 1) &>> 1
            lanes.p0 = select(mask, clampPixel(p0 &+ b), p0)
            lanes.q0 = select(mask, clampPixel(q0 &- a), q0)
            lanes.p1 = select(lowVariance, clampPixel(p1 &+ outer), p1)
            lanes.q1 = select(lowVariance, clampPixel(q1 &- outer), q1)
        }
        return true
    }

    // MARK: Arithmetic

    /// All ones in the lanes where `a` is greater than `b`. The difference must not overflow.
    @inline(always)
    private static func greater(_ a: Lanes, _ b: Lanes) -> Lanes {
        (b &- a) &>> 15
    }

    /// The lanes of `chosen` where `mask` is set, and of `other` elsewhere.
    @inline(always)
    private static func select(_ mask: Lanes, _ chosen: Lanes, _ other: Lanes) -> Lanes {
        (chosen & mask) | (other & ~mask)
    }

    @inline(always)
    private static func isAnySet(_ mask: Lanes) -> Bool {
        mask.min() < 0
    }

    /// The edge difference that every filter compares with its edge limit.
    @inline(always)
    private static func edgeDifference(_ p1: Lanes, _ p0: Lanes, _ q0: Lanes, _ q1: Lanes) -> Lanes {
        absoluteDifference(p0, q0) &* 2 &+ (absoluteDifference(p1, q1) &>> 1)
    }

    @inline(always)
    private static func absoluteDifference(_ a: Lanes, _ b: Lanes) -> Lanes {
        (a &- b).lanewiseMaximum(b &- a)
    }

    /// Clamps to the signed 8-bit range, the `c` function of section 15.2.
    @inline(always)
    private static func clampSigned(_ value: Lanes) -> Lanes {
        value.lanewiseClamped(Lanes(repeating: -128), Lanes(repeating: 127))
    }

    @inline(always)
    private static func clampPixel(_ value: Lanes) -> Lanes {
        value.lanewiseClamped(Lanes(repeating: 0), Lanes(repeating: 255))
    }

    // MARK: Memory

    /// Loads 16 pixels.
    @inline(always)
    private static func load(_ pixels: borrowing MutableSpan<UInt8>, _ offset: Int) -> Lanes {
        Lanes(truncatingIfNeeded: pixels.loadVector(at: offset, as: SIMD16<UInt8>.self))
    }

    /// Loads 8 pixels from each chroma plane.
    @inline(always)
    private static func load(
        _ u: borrowing MutableSpan<UInt8>,
        _ v: borrowing MutableSpan<UInt8>,
        _ offset: Int
    ) -> Lanes {
        let low = u.loadVector(at: offset, as: SIMD8<UInt8>.self)
        let high = v.loadVector(at: offset, as: SIMD8<UInt8>.self)
        return Lanes(truncatingIfNeeded: SIMD16(lowHalf: low, highHalf: high))
    }

    /// Loads the 8 pixels of one segment across a vertical edge, from p3 to q3.
    @inline(always)
    private static func loadRow(_ pixels: borrowing MutableSpan<UInt8>, _ start: Int) -> SIMD8<UInt8> {
        pixels.loadVector(at: start &- 4, as: SIMD8<UInt8>.self)
    }

    /// Stores the 8 pixels of one segment across a vertical edge.
    @inline(always)
    private static func storeRow(_ row: SIMD8<UInt8>, _ pixels: inout MutableSpan<UInt8>, _ start: Int) {
        pixels.storeVector(row, at: start &- 4)
    }

    // MARK: Transposition

    typealias Bytes = SIMD16<UInt8>

    /// Splits the 32 bytes of two vectors into the even and the odd positions.
    @inline(always)
    private static func split(_ low: Bytes, _ high: Bytes) -> (even: Bytes, odd: Bytes) {
        let joined = SIMD32(lowHalf: low, highHalf: high)
        return (joined.evenHalf, joined.oddHalf)
    }

    /// Splits a sequence of 128 bytes by position modulo 8.
    ///
    /// Three rounds of even and odd splits group the bytes by the three low bits of their
    /// position. Result `m` holds the positions `m`, `m + 8`, `m + 16`, and so on.
    @inline(always)
    private static func groupByEight(
        _ x0: Bytes, _ x1: Bytes, _ x2: Bytes, _ x3: Bytes,
        _ x4: Bytes, _ x5: Bytes, _ x6: Bytes, _ x7: Bytes
    ) -> (Bytes, Bytes, Bytes, Bytes, Bytes, Bytes, Bytes, Bytes) {
        let a0 = split(x0, x1), a1 = split(x2, x3), a2 = split(x4, x5), a3 = split(x6, x7)
        let b0 = split(a0.even, a1.even), b1 = split(a2.even, a3.even)
        let b2 = split(a0.odd, a1.odd), b3 = split(a2.odd, a3.odd)
        let c0 = split(b0.even, b1.even), c1 = split(b0.odd, b1.odd)
        let c2 = split(b2.even, b3.even), c3 = split(b2.odd, b3.odd)
        // The first split decides bit 0 of the position, the last one bit 2.
        return (c0.even, c2.even, c1.even, c3.even, c0.odd, c2.odd, c1.odd, c3.odd)
    }

    /// Turns 16 rows of 8 bytes, two rows per vector, into the 8 columns of the segments.
    @inline(always)
    private static func columns(
        _ x0: Bytes, _ x1: Bytes, _ x2: Bytes, _ x3: Bytes,
        _ x4: Bytes, _ x5: Bytes, _ x6: Bytes, _ x7: Bytes
    ) -> EdgeLanes {
        // Byte `c` of row `r` sits at position 8r + c, so grouping by position modulo 8 gives columns.
        let c = groupByEight(x0, x1, x2, x3, x4, x5, x6, x7)
        var lanes = EdgeLanes()
        lanes.p3 = Lanes(truncatingIfNeeded: c.0)
        lanes.p2 = Lanes(truncatingIfNeeded: c.1)
        lanes.p1 = Lanes(truncatingIfNeeded: c.2)
        lanes.p0 = Lanes(truncatingIfNeeded: c.3)
        lanes.q0 = Lanes(truncatingIfNeeded: c.4)
        lanes.q1 = Lanes(truncatingIfNeeded: c.5)
        lanes.q2 = Lanes(truncatingIfNeeded: c.6)
        lanes.q3 = Lanes(truncatingIfNeeded: c.7)
        return lanes
    }

    /// Turns the 8 columns back into rows. Result `m` holds row `m` in its even positions and
    /// row `m + 8` in its odd positions.
    @inline(always)
    private static func rows(
        _ lanes: borrowing EdgeLanes
    ) -> (Bytes, Bytes, Bytes, Bytes, Bytes, Bytes, Bytes, Bytes) {
        // Row `r` of column `c` sits at position 16c + r, and 16c is a multiple of 8.
        groupByEight(
            Bytes(truncatingIfNeeded: lanes.p3), Bytes(truncatingIfNeeded: lanes.p2),
            Bytes(truncatingIfNeeded: lanes.p1), Bytes(truncatingIfNeeded: lanes.p0),
            Bytes(truncatingIfNeeded: lanes.q0), Bytes(truncatingIfNeeded: lanes.q1),
            Bytes(truncatingIfNeeded: lanes.q2), Bytes(truncatingIfNeeded: lanes.q3))
    }

    /// Loads 16 luma segments across a vertical edge.
    @inline(always)
    private static func loadColumns(
        _ pixels: borrowing MutableSpan<UInt8>,
        start: Int,
        stride: Int
    ) -> EdgeLanes {
        @inline(always) func pair(_ row: Int) -> Bytes {
            let offset = start &+ row &* stride
            return Bytes(lowHalf: loadRow(pixels, offset), highHalf: loadRow(pixels, offset &+ stride))
        }
        return columns(pair(0), pair(2), pair(4), pair(6), pair(8), pair(10), pair(12), pair(14))
    }

    /// Loads 8 segments of each chroma plane across a vertical edge, U first.
    @inline(always)
    private static func loadColumns(
        _ u: borrowing MutableSpan<UInt8>,
        _ v: borrowing MutableSpan<UInt8>,
        start: Int,
        stride: Int
    ) -> EdgeLanes {
        @inline(always) func pair(_ plane: borrowing MutableSpan<UInt8>, _ row: Int) -> Bytes {
            let offset = start &+ row &* stride
            return Bytes(lowHalf: loadRow(plane, offset), highHalf: loadRow(plane, offset &+ stride))
        }
        return columns(pair(u, 0), pair(u, 2), pair(u, 4), pair(u, 6), pair(v, 0), pair(v, 2), pair(v, 4), pair(v, 6))
    }

    /// Stores 16 luma segments across a vertical edge.
    @inline(always)
    private static func storeColumns(
        _ lanes: borrowing EdgeLanes,
        _ pixels: inout MutableSpan<UInt8>,
        start: Int,
        stride: Int
    ) {
        let r = rows(lanes)
        let low = start, high = start &+ 8 &* stride
        storeRow(r.0.evenHalf, &pixels, low)
        storeRow(r.0.oddHalf, &pixels, high)
        storeRow(r.1.evenHalf, &pixels, low &+ stride)
        storeRow(r.1.oddHalf, &pixels, high &+ stride)
        storeRow(r.2.evenHalf, &pixels, low &+ 2 &* stride)
        storeRow(r.2.oddHalf, &pixels, high &+ 2 &* stride)
        storeRow(r.3.evenHalf, &pixels, low &+ 3 &* stride)
        storeRow(r.3.oddHalf, &pixels, high &+ 3 &* stride)
        storeRow(r.4.evenHalf, &pixels, low &+ 4 &* stride)
        storeRow(r.4.oddHalf, &pixels, high &+ 4 &* stride)
        storeRow(r.5.evenHalf, &pixels, low &+ 5 &* stride)
        storeRow(r.5.oddHalf, &pixels, high &+ 5 &* stride)
        storeRow(r.6.evenHalf, &pixels, low &+ 6 &* stride)
        storeRow(r.6.oddHalf, &pixels, high &+ 6 &* stride)
        storeRow(r.7.evenHalf, &pixels, low &+ 7 &* stride)
        storeRow(r.7.oddHalf, &pixels, high &+ 7 &* stride)
    }

    /// Stores 8 segments of each chroma plane across a vertical edge.
    @inline(always)
    private static func storeColumns(
        _ lanes: borrowing EdgeLanes,
        _ u: inout MutableSpan<UInt8>,
        _ v: inout MutableSpan<UInt8>,
        start: Int,
        stride: Int
    ) {
        // Rows 0 to 7 are U and rows 8 to 15 are V.
        let r = rows(lanes)
        storeRow(r.0.evenHalf, &u, start)
        storeRow(r.0.oddHalf, &v, start)
        storeRow(r.1.evenHalf, &u, start &+ stride)
        storeRow(r.1.oddHalf, &v, start &+ stride)
        storeRow(r.2.evenHalf, &u, start &+ 2 &* stride)
        storeRow(r.2.oddHalf, &v, start &+ 2 &* stride)
        storeRow(r.3.evenHalf, &u, start &+ 3 &* stride)
        storeRow(r.3.oddHalf, &v, start &+ 3 &* stride)
        storeRow(r.4.evenHalf, &u, start &+ 4 &* stride)
        storeRow(r.4.oddHalf, &v, start &+ 4 &* stride)
        storeRow(r.5.evenHalf, &u, start &+ 5 &* stride)
        storeRow(r.5.oddHalf, &v, start &+ 5 &* stride)
        storeRow(r.6.evenHalf, &u, start &+ 6 &* stride)
        storeRow(r.6.oddHalf, &v, start &+ 6 &* stride)
        storeRow(r.7.evenHalf, &u, start &+ 7 &* stride)
        storeRow(r.7.oddHalf, &v, start &+ 7 &* stride)
    }

    /// Stores 16 pixels that are already in the pixel range.
    @inline(always)
    private static func store(_ value: Lanes, _ pixels: inout MutableSpan<UInt8>, _ offset: Int) {
        pixels.storeVector(SIMD16<UInt8>(truncatingIfNeeded: value), at: offset)
    }

    /// Stores 8 pixels to each chroma plane.
    @inline(always)
    private static func store(
        _ value: Lanes,
        _ u: inout MutableSpan<UInt8>,
        _ v: inout MutableSpan<UInt8>,
        _ offset: Int
    ) {
        let pixels = SIMD16<UInt8>(truncatingIfNeeded: value)
        u.storeVector(pixels.lowHalf, at: offset)
        v.storeVector(pixels.highHalf, at: offset)
    }
}
