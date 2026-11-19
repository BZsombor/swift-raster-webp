/// The intra prediction modes of RFC 6386, section 12.
///
/// Predictions work in a small buffer that holds one block together with its neighbors. Row 0
/// holds the pixels above the block, with the pixel above and to the left at column 0, and column
/// 0 of the following rows holds the pixels to the left. Values outside the frame are already
/// replaced by the constants that section 12 requires.
enum VP8Prediction {
    /// The row length of the luma work buffer: the left column, 16 pixels and 4 above-right pixels.
    static var lumaStride: Int { 32 }

    /// The row length of a chroma work buffer.
    static var chromaStride: Int { 16 }

    /// Fills a square block with a 16x16 or 8x8 prediction mode.
    ///
    /// - Parameters:
    ///   - origin: The index of the block's top-left pixel. The neighbors are above and left of it.
    ///   - hasAbove: Whether the block is below the top row of the frame.
    ///   - hasLeft: Whether the block is right of the left column of the frame.
    static func predictBlock(
        _ mode: LumaMode,
        in work: inout MutableSpan<UInt8>,
        origin: Int,
        size: Int,
        stride: Int,
        hasAbove: Bool,
        hasLeft: Bool
    ) {
        let above = origin &- stride
        switch mode {
        case .vertical:
            let pixels = work.loadVector(at: above, as: SIMD16<UInt8>.self)
            for row in 0..<size {
                storeRow(pixels, in: &work, at: origin &+ row &* stride, size: size)
            }
        case .horizontal:
            for row in 0..<size {
                let target = origin &+ row &* stride
                storeRow(SIMD16(repeating: work[target &- 1]), in: &work, at: target, size: size)
            }
        case .trueMotion:
            // Each pixel is its left neighbor plus the difference of the pixel above and the corner.
            let corner = Int16(work[above &- 1])
            let gradient =
                SIMD16<Int16>(truncatingIfNeeded: work.loadVector(at: above, as: SIMD16<UInt8>.self))
                &- corner
            for row in 0..<size {
                let target = origin &+ row &* stride
                let values = (gradient &+ Int16(work[target &- 1]))
                    .lanewiseClamped(SIMD16(repeating: 0), SIMD16(repeating: 255))
                storeRow(SIMD16<UInt8>(truncatingIfNeeded: values), in: &work, at: target, size: size)
            }
        case .dc, .subblocks:
            // Only the neighbors inside the frame contribute, section 12.2.
            let shift = size == 16 ? 4 : 3
            var sum = 0
            var value = 128
            if hasAbove {
                for column in 0..<size {
                    sum &+= Int(work[above &+ column])
                }
            }
            if hasLeft {
                for row in 0..<size {
                    sum &+= Int(work[origin &+ row &* stride &- 1])
                }
            }
            switch (hasAbove, hasLeft) {
            case (true, true): value = (sum &+ (1 &<< shift)) &>> (shift &+ 1)
            case (true, false), (false, true): value = (sum &+ (1 &<< (shift &- 1))) &>> shift
            case (false, false): break
            }
            let pixels = SIMD16(repeating: UInt8(truncatingIfNeeded: value))
            for row in 0..<size {
                storeRow(pixels, in: &work, at: origin &+ row &* stride, size: size)
            }
        }
    }

    /// Stores the first 16 or 8 pixels of `pixels` as one row of a block.
    @inline(always)
    private static func storeRow(_ pixels: SIMD16<UInt8>, in work: inout MutableSpan<UInt8>, at index: Int, size: Int) {
        if size == 16 {
            work.storeVector(pixels, at: index)
        } else {
            work.storeVector(pixels.lowHalf, at: index)
        }
    }

    /// Fills a 4x4 luma subblock with a subblock prediction mode, section 12.3.
    ///
    /// The pixels above, above-right and to the left of the subblock must be in the buffer.
    static func predictSubblock(_ mode: UInt8, in work: inout MutableSpan<UInt8>, origin: Int) {
        let stride = lumaStride
        let above = origin &- stride

        // A[-1...7]: the corner, then 4 pixels above and 4 above-right. L[0...3]: the left column.
        let p = Int32(work[above &- 1])
        let a0 = Int32(work[above]), a1 = Int32(work[above &+ 1])
        let a2 = Int32(work[above &+ 2]), a3 = Int32(work[above &+ 3])
        let a4 = Int32(work[above &+ 4]), a5 = Int32(work[above &+ 5])
        let a6 = Int32(work[above &+ 6]), a7 = Int32(work[above &+ 7])
        let l0 = Int32(work[origin &- 1]), l1 = Int32(work[origin &+ stride &- 1])
        let l2 = Int32(work[origin &+ 2 &* stride &- 1]), l3 = Int32(work[origin &+ 3 &* stride &- 1])

        @inline(always) func set(_ row: Int, _ column: Int, _ value: Int32) {
            work[origin &+ row &* stride &+ column] = UInt8(truncatingIfNeeded: value)
        }
        @inline(always) func average3(_ x: Int32, _ y: Int32, _ z: Int32) -> Int32 {
            (x &+ y &+ y &+ z &+ 2) &>> 2
        }
        @inline(always) func average2(_ x: Int32, _ y: Int32) -> Int32 {
            (x &+ y &+ 1) &>> 1
        }

        switch mode {
        case SubblockMode.dc:
            let value = (a0 &+ a1 &+ a2 &+ a3 &+ l0 &+ l1 &+ l2 &+ l3 &+ 4) &>> 3
            for row in 0..<4 {
                for column in 0..<4 {
                    set(row, column, value)
                }
            }
        case SubblockMode.trueMotion:
            @inline(always) func row(_ index: Int, _ left: Int32) {
                let base = origin &+ index &* stride
                work[base] = clamp(left &+ a0 &- p)
                work[base &+ 1] = clamp(left &+ a1 &- p)
                work[base &+ 2] = clamp(left &+ a2 &- p)
                work[base &+ 3] = clamp(left &+ a3 &- p)
            }
            row(0, l0)
            row(1, l1)
            row(2, l2)
            row(3, l3)
        case SubblockMode.vertical:
            let v0 = average3(p, a0, a1), v1 = average3(a0, a1, a2)
            let v2 = average3(a1, a2, a3), v3 = average3(a2, a3, a4)
            for row in 0..<4 {
                set(row, 0, v0)
                set(row, 1, v1)
                set(row, 2, v2)
                set(row, 3, v3)
            }
        case SubblockMode.horizontal:
            @inline(always) func row(_ index: Int, _ value: Int32) {
                set(index, 0, value)
                set(index, 1, value)
                set(index, 2, value)
                set(index, 3, value)
            }
            row(0, average3(p, l0, l1))
            row(1, average3(l0, l1, l2))
            row(2, average3(l1, l2, l3))
            row(3, average3(l2, l3, l3))
        case SubblockMode.leftDown:
            set(0, 0, average3(a0, a1, a2))
            let b = average3(a1, a2, a3)
            set(0, 1, b); set(1, 0, b)
            let c = average3(a2, a3, a4)
            set(0, 2, c); set(1, 1, c); set(2, 0, c)
            let d = average3(a3, a4, a5)
            set(0, 3, d); set(1, 2, d); set(2, 1, d); set(3, 0, d)
            let e = average3(a4, a5, a6)
            set(1, 3, e); set(2, 2, e); set(3, 1, e)
            let f = average3(a5, a6, a7)
            set(2, 3, f); set(3, 2, f)
            set(3, 3, average3(a6, a7, a7))
        case SubblockMode.rightDown:
            // E[0...8] = L3, L2, L1, L0, P, A0, A1, A2, A3.
            set(3, 0, average3(l3, l2, l1))
            let b = average3(l2, l1, l0)
            set(3, 1, b); set(2, 0, b)
            let c = average3(l1, l0, p)
            set(3, 2, c); set(2, 1, c); set(1, 0, c)
            let d = average3(l0, p, a0)
            set(3, 3, d); set(2, 2, d); set(1, 1, d); set(0, 0, d)
            let e = average3(p, a0, a1)
            set(2, 3, e); set(1, 2, e); set(0, 1, e)
            let f = average3(a0, a1, a2)
            set(1, 3, f); set(0, 2, f)
            set(0, 3, average3(a1, a2, a3))
        case SubblockMode.verticalRight:
            set(3, 0, average3(l2, l1, l0))
            set(2, 0, average3(l1, l0, p))
            let b = average3(l0, p, a0)
            set(3, 1, b); set(1, 0, b)
            let c = average2(p, a0)
            set(2, 1, c); set(0, 0, c)
            let d = average3(p, a0, a1)
            set(3, 2, d); set(1, 1, d)
            let e = average2(a0, a1)
            set(2, 2, e); set(0, 1, e)
            let f = average3(a0, a1, a2)
            set(3, 3, f); set(1, 2, f)
            let g = average2(a1, a2)
            set(2, 3, g); set(0, 2, g)
            set(1, 3, average3(a1, a2, a3))
            set(0, 3, average2(a2, a3))
        case SubblockMode.verticalLeft:
            set(0, 0, average2(a0, a1))
            set(1, 0, average3(a0, a1, a2))
            let b = average2(a1, a2)
            set(2, 0, b); set(0, 1, b)
            let c = average3(a1, a2, a3)
            set(1, 1, c); set(3, 0, c)
            let d = average2(a2, a3)
            set(2, 1, d); set(0, 2, d)
            let e = average3(a2, a3, a4)
            set(3, 1, e); set(1, 2, e)
            let f = average2(a3, a4)
            set(2, 2, f); set(0, 3, f)
            let g = average3(a3, a4, a5)
            set(3, 2, g); set(1, 3, g)
            set(2, 3, average3(a4, a5, a6))
            set(3, 3, average3(a5, a6, a7))
        case SubblockMode.horizontalDown:
            set(3, 0, average2(l3, l2))
            set(3, 1, average3(l3, l2, l1))
            let b = average2(l2, l1)
            set(2, 0, b); set(3, 2, b)
            let c = average3(l2, l1, l0)
            set(2, 1, c); set(3, 3, c)
            let d = average2(l1, l0)
            set(2, 2, d); set(1, 0, d)
            let e = average3(l1, l0, p)
            set(2, 3, e); set(1, 1, e)
            let f = average2(l0, p)
            set(1, 2, f); set(0, 0, f)
            let g = average3(l0, p, a0)
            set(1, 3, g); set(0, 1, g)
            set(0, 2, average3(p, a0, a1))
            set(0, 3, average3(a0, a1, a2))
        default:
            // Horizontal up.
            set(0, 0, average2(l0, l1))
            set(0, 1, average3(l0, l1, l2))
            let b = average2(l1, l2)
            set(0, 2, b); set(1, 0, b)
            let c = average3(l1, l2, l3)
            set(0, 3, c); set(1, 1, c)
            let d = average2(l2, l3)
            set(1, 2, d); set(2, 0, d)
            let e = average3(l2, l3, l3)
            set(1, 3, e); set(2, 1, e)
            set(2, 2, l3); set(2, 3, l3); set(3, 0, l3); set(3, 1, l3); set(3, 2, l3); set(3, 3, l3)
        }
    }

    @inline(always)
    private static func clamp(_ value: Int32) -> UInt8 {
        UInt8(truncatingIfNeeded: min(max(value, 0), 255))
    }
}
