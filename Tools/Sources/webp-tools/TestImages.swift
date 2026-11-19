import Foundation

/// A small deterministic random number generator.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E62D
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func next(upTo bound: Int) -> Int {
        Int(next() >> 1) % bound
    }

    mutating func byte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }
}

/// An RGBA image that `cwebp` can read as a PAM file.
struct TestImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) {
        self.width = width
        self.height = height
        pixels = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue, alpha) = pixel(x, y)
                pixels += [red, green, blue, alpha]
            }
        }
    }

    func writePAM(to url: URL) throws {
        let header = """
            P7
            WIDTH \(width)
            HEIGHT \(height)
            DEPTH 4
            MAXVAL 255
            TUPLTYPE RGB_ALPHA
            ENDHDR

            """
        try (Data(header.utf8) + Data(pixels)).write(to: url)
    }

    static func gradient(width: Int, height: Int, translucent: Bool) -> TestImage {
        TestImage(width: width, height: height) { x, y in
            let alpha = translucent ? UInt8(x * 255 / max(width - 1, 1)) : 255
            return (UInt8((x * 7) % 256), UInt8((y * 9) % 256), UInt8(((x + y) * 5) % 256), alpha)
        }
    }

    static func noise(width: Int, height: Int, generator: inout SplitMix64, translucent: Bool) -> TestImage {
        var source = generator
        let image = TestImage(width: width, height: height) { _, _ in
            (source.byte(), source.byte(), source.byte(), translucent ? source.byte() : 255)
        }
        generator = source
        return image
    }

    static func palette(width: Int, height: Int, colorCount: Int, generator: inout SplitMix64) -> TestImage {
        let colors = (0..<colorCount).map { _ in
            (generator.byte(), generator.byte(), generator.byte(), generator.byte() | 0x80)
        }
        var source = generator
        let image = TestImage(width: width, height: height) { _, _ in
            colors[source.next(upTo: colorCount)]
        }
        generator = source
        return image
    }

    /// Combines smooth areas, flat blocks, repeated tiles and noise.
    static func mixed(width: Int, height: Int, generator: inout SplitMix64) -> TestImage {
        var source = generator
        let image = TestImage(width: width, height: height) { x, y in
            switch ((x / 32) + (y / 32) * 3) % 4 {
            case 0:
                return (UInt8((x * 3) % 256), UInt8((y * 2) % 256), UInt8((x + y) % 256), 255)
            case 1:
                return (UInt8((x / 16) * 40 % 256), 90, UInt8((y / 16) * 30 % 256), 255)
            case 2:
                return (UInt8((x % 8) * 30), UInt8((y % 8) * 30), UInt8(((x ^ y) % 8) * 30), 200)
            default:
                return (source.byte(), source.byte() & 0x1F, source.byte() | 0xE0, 255)
            }
        }
        generator = source
        return image
    }
}
