/// Decodes the boolean entropy coding of RFC 6386, section 7.
///
/// The decoder keeps up to 64 bits of the coded value in a register. Instead of shifting the
/// value as the range is normalized, it lowers the position of the comparison window, and new
/// bytes are loaded only when the window runs out. Reading past the end of the partition supplies
/// zero bits, which ``isPastEnd`` reports.
struct BoolDecoder {
    /// The unread part of the coded value. Only the lowest `windowShift + 8` bits are in use.
    private var value: UInt64 = 0
    /// The current range minus one, between 127 and 254 after every read.
    private var rangeMinusOne: UInt32 = 254
    /// The number of value bits below the 8-bit comparison window.
    private var windowShift = -8
    private var position: Int
    private let end: Int
    private var virtualBitCount = 0

    /// Creates a decoder for one partition.
    init(range partition: Range<Int>) {
        position = partition.lowerBound
        end = partition.upperBound
    }

    /// The number of bits past the end that valid streams may use. The reference decoder reads
    /// ahead of the bits it has decided on, so encoders do not always pad partitions for it.
    private static var endTolerance: Int { 16 }

    /// Whether the decoder has used bits beyond the end of its partition.
    var isPastEnd: Bool {
        virtualBitCount > windowShift &+ Self.endTolerance
    }

    /// Reads one boolean whose probability of being `false` is `probability / 256`.
    @inline(always)
    mutating func read(_ probability: UInt32, _ input: Span<UInt8>) -> Bool {
        if windowShift < 0 {
            refill(input)
        }
        // With `split = 1 + (range - 1) * probability / 256`, a one leaves `range - split` and a
        // zero leaves `split`, which `splitMinusOne` expresses as the new range minus one.
        let splitMinusOne = (rangeMinusOne &* probability) &>> 8
        let scaledSplit = UInt64(splitMinusOne &+ 1) &<< UInt64(truncatingIfNeeded: windowShift)
        let bit: Bool
        if value >= scaledSplit {
            rangeMinusOne &-= splitMinusOne &+ 1
            value &-= scaledSplit
            bit = true
        } else {
            rangeMinusOne = splitMinusOne
            bit = false
        }
        // Shift until the range is at least 128 again.
        let shift = (rangeMinusOne &+ 1).leadingZeroBitCount &- 24
        rangeMinusOne = (rangeMinusOne &+ 1) &<< UInt32(truncatingIfNeeded: shift) &- 1
        windowShift &-= shift
        return bit
    }

    /// Reads one boolean with even probability.
    @inline(always)
    mutating func readFlag(_ input: Span<UInt8>) -> Bool {
        read(128, input)
    }

    /// Reads an unsigned number of `count` bits, most significant bit first.
    mutating func readLiteral(_ count: Int, _ input: Span<UInt8>) -> Int {
        var result = 0
        for _ in 0..<count {
            result = result << 1 | (readFlag(input) ? 1 : 0)
        }
        return result
    }

    /// Reads a magnitude of `count` bits followed by a sign flag.
    mutating func readSigned(_ count: Int, _ input: Span<UInt8>) -> Int {
        let magnitude = readLiteral(count, input)
        return readFlag(input) ? -magnitude : magnitude
    }

    /// Reads a flag, then a signed number if the flag is set.
    mutating func readOptionalSigned(_ count: Int, _ input: Span<UInt8>) -> Int {
        readFlag(input) ? readSigned(count, input) : 0
    }

    @inline(always)
    private mutating func refill(_ input: Span<UInt8>) {
        if end &- position >= 8 {
            // Keep `windowShift + 8` at most 64, so that the value fits in the register.
            let byteCount = (56 &- windowShift) &>> 3
            let word = unsafe input.bytes.unsafeLoadUnaligned(fromByteOffset: position, as: UInt64.self)
            let bits = UInt64(bigEndian: word) &>> UInt64(truncatingIfNeeded: 64 &- byteCount &* 8)
            value = value &<< UInt64(truncatingIfNeeded: byteCount &* 8) | bits
            position &+= byteCount
            windowShift &+= byteCount &* 8
        } else {
            refillNearEnd(input)
        }
    }

    @inline(never)
    private mutating func refillNearEnd(_ input: Span<UInt8>) {
        while windowShift < 48 {
            value &<<= 8
            if position < end {
                value |= UInt64(input[position])
                position &+= 1
            } else {
                virtualBitCount &+= 8
            }
            windowShift &+= 8
        }
    }
}
