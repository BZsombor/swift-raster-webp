/// The inverse transforms of RFC 6386, section 14.
///
/// Coefficients and intermediate results are 16-bit integers, as the format requires, so they
/// wrap exactly like the reference decoder's. `scratch` must hold 16 values and only avoids
/// allocating storage for every block.
enum VP8Transforms {
    private static var cosineMinusOne: Int32 { 20091 }
    private static var sine: Int32 { 35468 }

    /// Inverts the Walsh-Hadamard transform of the second-order block at `source`, section 14.3.
    ///
    /// The result at row `i`, column `j` becomes the DC coefficient of luma subblock `i * 4 + j`,
    /// whose coefficients start at `(i * 4 + j) * 16`.
    static func inverseWalshHadamard(
        _ coefficients: inout MutableSpan<Int16>,
        source: Int,
        scratch: inout MutableSpan<Int32>
    ) {
        for column in 0..<4 {
            let i0 = Int32(coefficients[source &+ column])
            let i4 = Int32(coefficients[source &+ 4 &+ column])
            let i8 = Int32(coefficients[source &+ 8 &+ column])
            let i12 = Int32(coefficients[source &+ 12 &+ column])
            let a = i0 &+ i12
            let b = i4 &+ i8
            let c = i4 &- i8
            let d = i0 &- i12
            scratch[column] = wrapped(a &+ b)
            scratch[4 &+ column] = wrapped(c &+ d)
            scratch[8 &+ column] = wrapped(a &- b)
            scratch[12 &+ column] = wrapped(d &- c)
        }
        for row in 0..<4 {
            let base = row &* 4
            let a = scratch[base] &+ scratch[base &+ 3]
            let b = scratch[base &+ 1] &+ scratch[base &+ 2]
            let c = scratch[base &+ 1] &- scratch[base &+ 2]
            let d = scratch[base] &- scratch[base &+ 3]
            coefficients[base &* 16] = Int16(truncatingIfNeeded: (a &+ b &+ 3) &>> 3)
            coefficients[(base &+ 1) &* 16] = Int16(truncatingIfNeeded: (c &+ d &+ 3) &>> 3)
            coefficients[(base &+ 2) &* 16] = Int16(truncatingIfNeeded: (a &- b &+ 3) &>> 3)
            coefficients[(base &+ 3) &* 16] = Int16(truncatingIfNeeded: (d &- c &+ 3) &>> 3)
        }
    }

    /// Adds the inverse DCT of the block at `source` to a 4x4 area of `pixels`, section 14.4.
    static func addInverseDCT(
        _ coefficients: Span<Int16>,
        source: Int,
        to pixels: inout MutableSpan<UInt8>,
        at origin: Int,
        stride: Int,
        scratch: inout MutableSpan<Int32>
    ) {
        // The first pass transforms each column.
        for column in 0..<4 {
            let i0 = Int32(coefficients[source &+ column])
            let i4 = Int32(coefficients[source &+ 4 &+ column])
            let i8 = Int32(coefficients[source &+ 8 &+ column])
            let i12 = Int32(coefficients[source &+ 12 &+ column])
            let a = i0 &+ i8
            let b = i0 &- i8
            let c = ((i4 &* sine) &>> 16) &- (i12 &+ ((i12 &* cosineMinusOne) &>> 16))
            let d = (i4 &+ ((i4 &* cosineMinusOne) &>> 16)) &+ ((i12 &* sine) &>> 16)
            scratch[column] = wrapped(a &+ d)
            scratch[12 &+ column] = wrapped(a &- d)
            scratch[4 &+ column] = wrapped(b &+ c)
            scratch[8 &+ column] = wrapped(b &- c)
        }

        // The second pass transforms each row, rounds, and adds the result to the prediction.
        for row in 0..<4 {
            let base = row &* 4
            let i0 = scratch[base]
            let i1 = scratch[base &+ 1]
            let i2 = scratch[base &+ 2]
            let i3 = scratch[base &+ 3]
            let a = i0 &+ i2
            let b = i0 &- i2
            let c = ((i1 &* sine) &>> 16) &- (i3 &+ ((i3 &* cosineMinusOne) &>> 16))
            let d = (i1 &+ ((i1 &* cosineMinusOne) &>> 16)) &+ ((i3 &* sine) &>> 16)
            let target = origin &+ row &* stride
            add(&pixels, target, wrapped((a &+ d &+ 4) &>> 3))
            add(&pixels, target &+ 3, wrapped((a &- d &+ 4) &>> 3))
            add(&pixels, target &+ 1, wrapped((b &+ c &+ 4) &>> 3))
            add(&pixels, target &+ 2, wrapped((b &- c &+ 4) &>> 3))
        }
    }

    /// Adds the inverse DCT of a block whose only non-zero coefficient is DC.
    static func addInverseDC(
        _ coefficients: Span<Int16>,
        source: Int,
        to pixels: inout MutableSpan<UInt8>,
        at origin: Int,
        stride: Int
    ) {
        let residual = wrapped((Int32(coefficients[source]) &+ 4) &>> 3)
        for row in 0..<4 {
            let target = origin &+ row &* stride
            for column in 0..<4 {
                add(&pixels, target &+ column, residual)
            }
        }
    }

    /// Returns whether a block has any non-zero coefficient after its DC coefficient.
    @inline(always)
    static func hasACCoefficients(_ coefficients: Span<Int16>, source: Int) -> Bool {
        for index in 1..<16 where coefficients[source &+ index] != 0 {
            return true
        }
        return false
    }

    /// Truncates a value to 16 bits, as the format's intermediate storage does.
    @inline(always)
    private static func wrapped(_ value: Int32) -> Int32 {
        Int32(Int16(truncatingIfNeeded: value))
    }

    /// Adds a residual to a predicted pixel and clamps the result, section 14.5.
    @inline(always)
    private static func add(_ pixels: inout MutableSpan<UInt8>, _ index: Int, _ residual: Int32) {
        let sum = Int32(pixels[index]) &+ residual
        pixels[index] = UInt8(truncatingIfNeeded: min(max(sum, 0), 255))
    }
}
