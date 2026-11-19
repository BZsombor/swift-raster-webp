import RasterWebPCore
import Testing

@testable import RasterWebPDecoder

/// The YUV plane hashes that `webp-tools golden` recorded from `dwebp -yuv` for the fixtures.
private let planeHashes: [String: UInt64] = {
    var entries: [String: UInt64] = [:]
    for line in String(decoding: PackageResources.fixtures_tsv, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(separator: "\t").map(String.init)
        guard fields.count == 9, fields[1] == "ok", fields[4] == "lossy", let hash = UInt64(fields[8], radix: 16)
        else {
            continue
        }
        entries[String(fields[0].dropLast(".webp".count))] = hash
    }
    return entries
}()

/// Hashes the visible part of the planes in the flat layout that `dwebp -yuv` writes.
private func planeHash(_ planes: YUVPlanes) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    func add(_ plane: [UInt8], stride: Int, width: Int, height: Int) {
        for row in 0..<height {
            for column in 0..<width {
                hash = (hash ^ UInt64(plane[row * stride + column])) &* 0x0000_0100_0000_01B3
            }
        }
    }
    let chromaWidth = (planes.width + 1) / 2
    let chromaHeight = (planes.height + 1) / 2
    add(planes.y, stride: planes.lumaStride, width: planes.width, height: planes.height)
    add(planes.u, stride: planes.chromaStride, width: chromaWidth, height: chromaHeight)
    add(planes.v, stride: planes.chromaStride, width: chromaWidth, height: chromaHeight)
    return hash
}

/// The lossy fixtures cover the main encoder options on every platform, also without the corpus.
@Suite("Lossy fixtures")
struct LossyFixtureTests {
    @Test func planesMatchLibwebp() throws {
        #expect(planeHashes.count == 11)

        for fixture in Fixtures.all {
            guard let expected = planeHashes[fixture.name] else {
                continue
            }
            let hash = try fixture.bytes.withElementSpan { (input) throws(WebPError) -> UInt64 in
                let layout = try WebPFileLayout(parsing: input)
                guard let payload = layout.imagePayload else {
                    throw WebPError(.missingImageData)
                }
                var budget = MemoryBudget(limit: 1 << 24)
                let planes = try LossyDecoder.decodePlanes(
                    input: input,
                    payload: payload,
                    width: layout.info.width,
                    height: layout.info.height,
                    budget: &budget
                )
                return planeHash(planes)
            }
            #expect(hash == expected, "\(fixture.name)")
        }
    }
}
