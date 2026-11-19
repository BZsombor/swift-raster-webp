/// The inverse transforms of RFC 6386, section 14.
///
/// Coefficients and intermediate results are 16-bit integers, as the format requires, so they
/// wrap exactly like the reference decoder's.
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
    ///
    /// Each pass transforms the four columns or the four rows at once, one in each vector lane.
    static func addInverseDCT(
        _ coefficients: Span<Int16>,
        source: Int,
        to pixels: inout MutableSpan<UInt8>,
        at origin: Int,
        stride: Int
    ) {
        // The first pass transforms each column, so lane `j` holds column `j`.
        let first = transform(
            Quad(truncatingIfNeeded: coefficients.loadVector(at: source, as: SIMD4<Int16>.self)),
            Quad(truncatingIfNeeded: coefficients.loadVector(at: source &+ 4, as: SIMD4<Int16>.self)),
            Quad(truncatingIfNeeded: coefficients.loadVector(at: source &+ 8, as: SIMD4<Int16>.self)),
            Quad(truncatingIfNeeded: coefficients.loadVector(at: source &+ 12, as: SIMD4<Int16>.self)))
        let rows = transpose(wrapped(first.0), wrapped(first.1), wrapped(first.2), wrapped(first.3))

        // The second pass transforms each row, so lane `i` holds row `i`.
        let second = transform(rows.0, rows.1, rows.2, rows.3)
        let rounding = Quad(repeating: 4)
        let residuals = transpose(
            wrapped((second.0 &+ rounding) &>> 3),
            wrapped((second.1 &+ rounding) &>> 3),
            wrapped((second.2 &+ rounding) &>> 3),
            wrapped((second.3 &+ rounding) &>> 3))

        add(residuals.0, to: &pixels, at: origin)
        add(residuals.1, to: &pixels, at: origin &+ stride)
        add(residuals.2, to: &pixels, at: origin &+ 2 &* stride)
        add(residuals.3, to: &pixels, at: origin &+ 3 &* stride)
    }

    /// Adds the inverse DCT of a block whose only non-zero coefficient is DC.
    static func addInverseDC(
        _ coefficients: Span<Int16>,
        source: Int,
        to pixels: inout MutableSpan<UInt8>,
        at origin: Int,
        stride: Int
    ) {
        let residual = Quad(repeating: wrapped((Int32(coefficients[source]) &+ 4) &>> 3))
        for row in 0..<4 {
            add(residual, to: &pixels, at: origin &+ row &* stride)
        }
    }

    typealias Quad = SIMD4<Int32>

    /// The one-dimensional inverse DCT of four inputs in each lane, in output order 0, 1, 2, 3.
    @inline(always)
    private static func transform(
        _ i0: Quad,
        _ i1: Quad,
        _ i2: Quad,
        _ i3: Quad
    ) -> (Quad, Quad, Quad, Quad) {
        let a = i0 &+ i2
        let b = i0 &- i2
        let c = ((i1 &* sine) &>> 16) &- (i3 &+ ((i3 &* cosineMinusOne) &>> 16))
        let d = (i1 &+ ((i1 &* cosineMinusOne) &>> 16)) &+ ((i3 &* sine) &>> 16)
        return (a &+ d, b &+ c, b &- c, a &- d)
    }

    /// Swaps the rows and columns of a 4x4 block.
    @inline(always)
    private static func transpose(
        _ r0: Quad,
        _ r1: Quad,
        _ r2: Quad,
        _ r3: Quad
    ) -> (Quad, Quad, Quad, Quad) {
        // Element `c` of row `r` is at position 4r + c. Two rounds of even and odd splits group
        // the positions by their value modulo 4, which gives the columns.
        @inline(always) func split(_ low: Quad, _ high: Quad) -> (even: Quad, odd: Quad) {
            let joined = SIMD8(lowHalf: low, highHalf: high)
            return (joined.evenHalf, joined.oddHalf)
        }
        let a0 = split(r0, r1), a1 = split(r2, r3)
        let even = split(a0.even, a1.even), odd = split(a0.odd, a1.odd)
        return (even.even, odd.even, even.odd, odd.odd)
    }

    /// Truncates each lane to 16 bits, as the format's intermediate storage does.
    @inline(always)
    private static func wrapped(_ value: Quad) -> Quad {
        Quad(truncatingIfNeeded: SIMD4<Int16>(truncatingIfNeeded: value))
    }

    /// Adds residuals to four predicted pixels and clamps the results, section 14.5.
    @inline(always)
    private static func add(_ residuals: Quad, to pixels: inout MutableSpan<UInt8>, at index: Int) {
        let predicted = Quad(truncatingIfNeeded: pixels.loadVector(at: index, as: SIMD4<UInt8>.self))
        let sum = (predicted &+ residuals).lanewiseClamped(Quad(repeating: 0), Quad(repeating: 255))
        pixels.storeVector(SIMD4<UInt8>(truncatingIfNeeded: sum), at: index)
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
}
