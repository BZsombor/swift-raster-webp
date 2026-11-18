import RasterWebP
import Testing

/// A small deterministic generator, so that failures reproduce on every platform.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E62D
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func next(below bound: Int) -> Int {
        // Keep 31 bits so that the value stays positive where `Int` is 32 bits wide.
        Int(truncatingIfNeeded: next() >> 33) % bound
    }
}

/// Parses untrusted bytes and checks the invariants of any accepted result.
private func parseAndCheck(_ bytes: [UInt8]) {
    guard let info = try? WebPImageInfo(parsing: bytes) else {
        return
    }
    #expect(info.width > 0)
    #expect(info.height > 0)
    #expect(info.width <= 1 << 24)
    #expect(info.height <= 1 << 24)
    if let animation = info.animation {
        #expect(animation.frameCount > 0)
    }
}

@Suite("Robustness")
struct RobustnessTests {
    @Test func everyTruncationIsReported() {
        for fixture in Fixtures.all {
            for length in 0..<fixture.bytes.count {
                #expect(throws: (any Error).self, "\(fixture.name) cut at \(length)") {
                    try WebPImageInfo(parsing: Array(fixture.bytes[..<length]))
                }
            }
        }
    }

    @Test func everySingleBitFlipIsHandled() {
        for fixture in Fixtures.all {
            var bytes = fixture.bytes
            for index in bytes.indices {
                for bit in 0..<8 {
                    bytes[index] ^= 1 << UInt8(bit)
                    parseAndCheck(bytes)
                    bytes[index] ^= 1 << UInt8(bit)
                }
            }
        }
    }

    @Test func everyByteValueInTheHeadersIsHandled() {
        for fixture in Fixtures.all {
            var bytes = fixture.bytes
            for index in 0..<min(64, bytes.count) {
                let original = bytes[index]
                for value in UInt8.min...UInt8.max {
                    bytes[index] = value
                    parseAndCheck(bytes)
                }
                bytes[index] = original
            }
        }
    }

    @Test func randomMutationsAreHandled() {
        var generator = SplitMix64(state: 0x5241_5354_4552)
        for fixture in Fixtures.all {
            for _ in 0..<5_000 {
                var bytes = fixture.bytes
                for _ in 0..<(1 + generator.next(below: 8)) {
                    let index = generator.next(below: bytes.count)
                    bytes[index] = UInt8(truncatingIfNeeded: generator.next())
                }
                parseAndCheck(bytes)
            }
        }
    }

    @Test func randomDataIsRejected() {
        var generator = SplitMix64(state: 0x5745_4250)
        for _ in 0..<5_000 {
            let count = generator.next(below: 256)
            let bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            #expect(throws: (any Error).self) {
                try WebPImageInfo(parsing: bytes)
            }
        }
    }
}
