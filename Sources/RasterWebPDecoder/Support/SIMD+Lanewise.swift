// The standard library's `pointwiseMin`, `pointwiseMax` and `clamped` are not always inlined,
// and selecting lanes through a `SIMDMask` compiles poorly. These versions take the sign of the
// difference as a bit mask instead, which the compiler turns into a few vector instructions.
//
// The difference of the two values must not overflow, which holds for the small pixel
// arithmetic of the decoder.

extension SIMD16 where Scalar == Int16 {
    /// The larger value of each lane.
    @inline(always)
    func lanewiseMaximum(_ other: Self) -> Self {
        let difference = self &- other
        return other &+ (difference & ~(difference &>> 15))
    }

    /// The smaller value of each lane.
    @inline(always)
    func lanewiseMinimum(_ other: Self) -> Self {
        let difference = self &- other
        return other &+ (difference & (difference &>> 15))
    }

    /// Each lane limited to the range from `lower` to `upper`.
    @inline(always)
    func lanewiseClamped(_ lower: Self, _ upper: Self) -> Self {
        lanewiseMaximum(lower).lanewiseMinimum(upper)
    }
}

extension SIMD8 where Scalar == Int32 {
    /// The larger value of each lane.
    @inline(always)
    func lanewiseMaximum(_ other: Self) -> Self {
        let difference = self &- other
        return other &+ (difference & ~(difference &>> 31))
    }

    /// The smaller value of each lane.
    @inline(always)
    func lanewiseMinimum(_ other: Self) -> Self {
        let difference = self &- other
        return other &+ (difference & (difference &>> 31))
    }

    /// Each lane limited to the range from `lower` to `upper`.
    @inline(always)
    func lanewiseClamped(_ lower: Self, _ upper: Self) -> Self {
        lanewiseMaximum(lower).lanewiseMinimum(upper)
    }
}

extension SIMD4 where Scalar == Int32 {
    /// The larger value of each lane.
    @inline(always)
    func lanewiseMaximum(_ other: Self) -> Self {
        let difference = self &- other
        return other &+ (difference & ~(difference &>> 31))
    }

    /// The smaller value of each lane.
    @inline(always)
    func lanewiseMinimum(_ other: Self) -> Self {
        let difference = self &- other
        return other &+ (difference & (difference &>> 31))
    }

    /// Each lane limited to the range from `lower` to `upper`.
    @inline(always)
    func lanewiseClamped(_ lower: Self, _ upper: Self) -> Self {
        lanewiseMaximum(lower).lanewiseMinimum(upper)
    }
}
