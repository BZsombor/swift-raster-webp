import RasterWebP
import Testing

/// Files produced by libwebp, generated with `webp-tools fixtures`.
enum Fixtures {
    static let all: [(name: String, bytes: [UInt8])] = [
        ("lossy", PackageResources.lossy_webp),
        ("lossless", PackageResources.lossless_webp),
        ("lossless_alpha", PackageResources.lossless_alpha_webp),
        ("lossy_alpha", PackageResources.lossy_alpha_webp),
        ("metadata", PackageResources.metadata_webp),
        ("animated_mixed", PackageResources.animated_mixed_webp),
    ]
}

@Suite("libwebp fixtures")
struct FixtureTests {
    @Test func everyFixtureHasTheExpectedSize() throws {
        for fixture in Fixtures.all {
            let info = try WebPImageInfo(parsing: fixture.bytes)
            #expect(info.width == 33, "\(fixture.name)")
            #expect(info.height == 25, "\(fixture.name)")
        }
    }

    @Test func lossy() throws {
        let info = try WebPImageInfo(parsing: PackageResources.lossy_webp)
        #expect(info.compression == .lossy)
        #expect(!info.hasAlpha)
    }

    @Test func lossless() throws {
        let info = try WebPImageInfo(parsing: PackageResources.lossless_webp)
        #expect(info.compression == .lossless)
        #expect(!info.hasAlpha)
    }

    @Test func losslessWithAlpha() throws {
        let info = try WebPImageInfo(parsing: PackageResources.lossless_alpha_webp)
        #expect(info.compression == .lossless)
        #expect(info.hasAlpha)
    }

    @Test func lossyWithAlpha() throws {
        let info = try WebPImageInfo(parsing: PackageResources.lossy_alpha_webp)
        #expect(info.compression == .lossy)
        #expect(info.hasAlpha)
    }

    @Test func metadata() throws {
        let info = try WebPImageInfo(parsing: PackageResources.metadata_webp)
        #expect(info.hasICCProfile)
        #expect(info.hasEXIF)
        #expect(info.hasXMP)
    }

    @Test func animation() throws {
        let info = try WebPImageInfo(parsing: PackageResources.animated_mixed_webp)
        let animation = try #require(info.animation)

        #expect(info.compression == .mixed)
        #expect(animation.frameCount == 3)
        #expect(animation.loopCount == 3)
        #expect(animation.backgroundColor.alpha == 255)
        #expect(animation.backgroundColor.red == 10)
        #expect(animation.backgroundColor.green == 20)
        #expect(animation.backgroundColor.blue == 30)
    }
}
