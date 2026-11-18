extension Span where Element == UInt8 {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func littleEndianUInt24(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        littleEndianUInt24(at: offset) | UInt32(self[offset + 3]) << 24
    }
}
