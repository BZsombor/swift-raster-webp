#if canImport(Foundation)
    import Foundation
    import RasterWebPCore
    import Testing

    @testable import RasterWebPDecoder

    /// The YUV plane hashes that `webp-tools golden` recorded from `dwebp -yuv`.
    private let planeEntries: [(file: String, width: Int, height: Int, hash: UInt64)] = String(
        decoding: PackageResources.libwebp_test_data_tsv,
        as: UTF8.self
    )
    .split(separator: "\n")
    .compactMap { line in
        let fields = line.split(separator: "\t").map(String.init)
        guard fields.count == 9, fields[1] == "ok", fields[4] == "lossy", let width = Int(fields[2]),
            let height = Int(fields[3]), let hash = UInt64(fields[8], radix: 16)
        else {
            return nil
        }
        return (fields[0], width, height, hash)
    }

    private let corpus: URL? = {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".corpus/libwebp-test-data")
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
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

    @Suite("VP8 planes")
    struct LossyPlaneConformanceTests {
        @Test(.enabled(if: corpus != nil, "Run Scripts/fetch-corpus.sh first"))
        func planesMatchLibwebp() throws {
            let directory = try #require(corpus)
            #expect(planeEntries.count == 88)

            var mismatches: [String] = []
            for entry in planeEntries {
                let bytes = try [UInt8](Data(contentsOf: directory.appendingPathComponent(entry.file)))
                let result: Result<UInt64, WebPError> = bytes.withUnsafeBufferPointer { buffer in
                    do throws(WebPError) {
                        let layout = try WebPFileLayout(parsing: buffer.span)
                        guard let payload = layout.imagePayload else {
                            throw WebPError(.missingImageData)
                        }
                        var budget = MemoryBudget(limit: 1 << 30)
                        let planes = try LossyDecoder.decodePlanes(
                            input: buffer.span,
                            payload: payload,
                            width: entry.width,
                            height: entry.height,
                            budget: &budget
                        )
                        return .success(planeHash(planes))
                    } catch {
                        return .failure(error)
                    }
                }
                switch result {
                case .success(let hash) where hash == entry.hash:
                    break
                case .success:
                    mismatches.append(entry.file)
                case .failure(let error):
                    mismatches.append("\(entry.file) (\(error))")
                }
            }
            #expect(mismatches.isEmpty, "\(mismatches.count) files differ: \(mismatches)")
        }
    }
#endif
