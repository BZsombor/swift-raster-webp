// `Array.span` needs macOS 26, so spans come from the array's buffer pointer on older systems.
// Swift 6.3 requires the `unsafe` markers below, while Swift 6.4 reports them as unnecessary.

extension Array where Element: BitwiseCopyable {
    /// Calls a closure with a span over the array's elements.
    @inline(always)
    func withElementSpan<Result, Failure: Error>(
        _ body: (Span<Element>) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let call: (UnsafeBufferPointer<Element>) throws(Failure) -> Result = { buffer throws(Failure) in
            try unsafe body(buffer.span)
        }
        #if compiler(>=6.4)
            return try withUnsafeBufferPointer(call)
        #else
            return try unsafe withUnsafeBufferPointer(call)
        #endif
    }

    /// Calls a closure with a mutable span over the array's elements.
    @inline(always)
    mutating func withMutableElementSpan<Result, Failure: Error>(
        _ body: (inout MutableSpan<Element>) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let call: (inout UnsafeMutableBufferPointer<Element>) throws(Failure) -> Result = {
            buffer throws(Failure) in
            var span = unsafe buffer.mutableSpan
            return try body(&span)
        }
        #if compiler(>=6.4)
            return try withUnsafeMutableBufferPointer(call)
        #else
            return try unsafe withUnsafeMutableBufferPointer(call)
        #endif
    }
}

/// Calls a closure with the raw memory of a mutable span.
@inline(always)
func withRawStorage<Result, Failure: Error>(
    of span: inout MutableSpan<UInt8>,
    _ body: (UnsafeMutableRawBufferPointer) throws(Failure) -> Result
) throws(Failure) -> Result {
    #if compiler(>=6.4)
        return try span.withUnsafeMutableBytes(body)
    #else
        return try unsafe span.withUnsafeMutableBytes(body)
    #endif
}

/// Calls a closure with a mutable span over the elements of `span` in `range`.
///
/// `MutableSpan.extracting(_:)` is not stable across the supported compilers, so the part is
/// made from the span's buffer after checking the range.
@inline(always)
func withPart<Element, Result, Failure: Error>(
    of span: inout MutableSpan<Element>,
    _ range: Range<Int>,
    _ body: (inout MutableSpan<Element>) throws(Failure) -> Result
) throws(Failure) -> Result {
    precondition(range.lowerBound >= 0 && range.upperBound <= span.count, "Range out of bounds")
    let call: (UnsafeMutableBufferPointer<Element>) throws(Failure) -> Result = { buffer throws(Failure) in
        var part = unsafe UnsafeMutableBufferPointer(rebasing: buffer[range]).mutableSpan
        return try body(&part)
    }
    #if compiler(>=6.4)
        return try span.withUnsafeMutableBufferPointer(call)
    #else
        return try unsafe span.withUnsafeMutableBufferPointer(call)
    #endif
}
