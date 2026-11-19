/// Reads the least-significant-bit-first bitstream of a VP8L image.
///
/// Reading past the end of the data supplies zero bits. Callers detect this through
/// ``isTruncated`` at convenient points, which keeps the hot paths free of end checks.
struct BitReader {
    /// The number of bits that are guaranteed to be available after a refill.
    static var minimumBitsAfterRefill: Int { 56 }

    private var window: UInt64 = 0
    private var position: Int
    private let end: Int
    private var virtualBitCount = 0

    /// The number of bits in the window, including virtual zero bits past the end of the data.
    private(set) var availableBitCount = 0

    /// Creates a reader for a range of the input.
    init(range: Range<Int>) {
        position = range.lowerBound
        end = range.upperBound
    }

    /// Whether more bits were consumed than the data contains.
    var isTruncated: Bool {
        virtualBitCount > availableBitCount
    }

    /// The next 32 bits of the stream, which are only valid up to ``availableBitCount``.
    @inline(always)
    var peek: UInt32 {
        UInt32(truncatingIfNeeded: window)
    }

    /// Fills the window so that it holds at least ``minimumBitsAfterRefill`` bits.
    @inline(always)
    mutating func refill(_ input: Span<UInt8>) {
        if end &- position >= 8 {
            let word = unsafe input.bytes.unsafeLoadUnaligned(fromByteOffset: position, as: UInt64.self)
            window |= UInt64(littleEndian: word) &<< UInt64(truncatingIfNeeded: availableBitCount)
            position &+= (63 &- availableBitCount) &>> 3
            availableBitCount |= 56
        } else {
            refillNearEnd(input)
        }
    }

    /// Removes bits that have already been inspected through ``peek``.
    @inline(always)
    mutating func consume(_ count: Int) {
        window &>>= UInt64(truncatingIfNeeded: count)
        availableBitCount &-= count
    }

    /// Reads up to 32 bits.
    @inline(always)
    mutating func read(_ count: Int, _ input: Span<UInt8>) -> UInt32 {
        if availableBitCount < count {
            refill(input)
        }
        let mask = (UInt64(1) &<< UInt64(truncatingIfNeeded: count)) &- 1
        let value = UInt32(truncatingIfNeeded: window & mask)
        consume(count)
        return value
    }

    @inline(never)
    private mutating func refillNearEnd(_ input: Span<UInt8>) {
        while availableBitCount < Self.minimumBitsAfterRefill {
            if position < end {
                window |= UInt64(input[position]) &<< UInt64(truncatingIfNeeded: availableBitCount)
                position &+= 1
            } else {
                virtualBitCount &+= 8
            }
            availableBitCount &+= 8
        }
    }
}
