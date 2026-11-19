#if canImport(Foundation)
    import Foundation
    import RasterWebP
    import Testing

    /// What libwebp reports for one corpus file. Generated with `webp-tools golden`.
    private struct GoldenEntry {
        let file: String
        let width: Int
        let height: Int
        let compression: WebPCompression
        let hasAlpha: Bool
        let isAnimated: Bool
        let pixelHash: UInt64

        init?(line: Substring) {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count == 8, fields[1] == "ok", let width = Int(fields[2]), let height = Int(fields[3]),
                let pixelHash = UInt64(fields[7], radix: 16)
            else {
                return nil
            }
            self.pixelHash = pixelHash
            file = fields[0]
            self.width = width
            self.height = height
            switch fields[4] {
            case "lossless": compression = .lossless
            case "mixed": compression = .mixed
            default: compression = .lossy
            }
            hasAlpha = fields[5] == "true"
            isAnimated = fields[6] == "true"
        }
    }

    private let goldenEntries: [GoldenEntry] = String(
        decoding: PackageResources.libwebp_test_data_tsv,
        as: UTF8.self
    )
    .split(separator: "\n")
    .filter { !$0.hasPrefix("#") }
    .compactMap(GoldenEntry.init(line:))

    /// The corpus location, or `nil` when `Scripts/fetch-corpus.sh` has not been run.
    private let corpusDirectory: URL? = {
        let environment = ProcessInfo.processInfo.environment["RASTER_WEBP_CORPUS"]
        let directory =
            environment.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".corpus/libwebp-test-data")
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }()

    @Suite("libwebp conformance")
    struct MetadataConformanceTests {
        @Test func goldenDataCoversTheWholeCorpus() {
            #expect(goldenEntries.count == 131)
        }

        @Test(.enabled(if: corpusDirectory != nil, "Run Scripts/fetch-corpus.sh first"))
        func metadataMatchesLibwebp() throws {
            let directory = try #require(corpusDirectory)

            for entry in goldenEntries {
                let bytes = try [UInt8](Data(contentsOf: directory.appendingPathComponent(entry.file)))
                let info = try WebPImageInfo(parsing: bytes)

                #expect(info.width == entry.width, "\(entry.file)")
                #expect(info.height == entry.height, "\(entry.file)")
                #expect(info.compression == entry.compression, "\(entry.file)")
                #expect(info.hasAlpha == entry.hasAlpha, "\(entry.file)")
                #expect(info.isAnimated == entry.isAnimated, "\(entry.file)")
            }
        }

        @Test(.enabled(if: corpusDirectory != nil, "Run Scripts/fetch-corpus.sh first"))
        func losslessPixelsMatchLibwebp() throws {
            let directory = try #require(corpusDirectory)
            let entries = goldenEntries.filter { $0.compression == .lossless }
            #expect(entries.count > 40)

            for entry in entries {
                let bytes = try [UInt8](Data(contentsOf: directory.appendingPathComponent(entry.file)))
                let image = try WebPDecoder.decode(bytes)
                #expect(fnv1a(image.pixels) == entry.pixelHash, "\(entry.file)")
            }
        }
    }

    /// Hashes bytes with 64-bit FNV-1a, matching `webp-tools golden`.
    private func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }
#endif
