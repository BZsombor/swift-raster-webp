// Loads and stores of whole SIMD vectors in spans. `RawSpan` and `MutableRawSpan` check the
// bounds of every access. Loads read vectors of integers, which accept every bit pattern, and
// stores write lanes of the span's own element type.

extension Span where Element: BitwiseCopyable {
    /// Loads the vector whose first lane is the element at `index`.
    @inline(always)
    func loadVector<Vector: SIMD & BitwiseCopyable>(
        at index: Int,
        as type: Vector.Type
    ) -> Vector where Vector.Scalar == Element {
        unsafe bytes.unsafeLoadUnaligned(fromByteOffset: index &* MemoryLayout<Element>.stride, as: type)
    }
}

extension MutableSpan where Element: BitwiseCopyable {
    /// Loads the vector whose first lane is the element at `index`.
    @inline(always)
    func loadVector<Vector: SIMD & BitwiseCopyable>(
        at index: Int,
        as type: Vector.Type
    ) -> Vector where Vector.Scalar == Element {
        span.loadVector(at: index, as: type)
    }

    /// Stores the lanes of a vector to the elements from `index` on.
    @inline(always)
    mutating func storeVector<Vector: SIMD & BitwiseCopyable>(
        _ vector: Vector,
        at index: Int
    ) where Vector.Scalar == Element {
        // The vector's lanes are elements, so the stored bytes are valid elements.
        // Swift 6.4 requires the second `unsafe` marker, while Swift 6.3 reports it as unnecessary.
        var bytes = unsafe mutableBytes
        let offset = index &* MemoryLayout<Element>.stride
        #if compiler(>=6.4)
            unsafe bytes.storeBytes(of: vector, toByteOffset: offset, as: Vector.self)
        #else
            bytes.storeBytes(of: vector, toByteOffset: offset, as: Vector.self)
        #endif
    }
}
