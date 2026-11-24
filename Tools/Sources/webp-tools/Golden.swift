import Foundation

/// Hashes bytes with 64-bit FNV-1a, which the conformance tests can reproduce on any platform.
func fnv1a(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in bytes {
        hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    return hash
}

/// The properties that libwebp reports for one file.
private struct ReferenceEntry {
    var width = 0
    var height = 0
    var hasLossy = false
    var hasLossless = false
    var hasAlpha = false
    var isAnimated = false

    /// Reads the textual report of `webpinfo`.
    init(webpinfoOutput: String) {
        var hasCanvas = false
        for rawLine in webpinfoOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Canvas size ") {
                let sizes = line.dropFirst("Canvas size ".count).split(separator: " ")
                width = Int(sizes[0]) ?? 0
                height = Int(sizes[2]) ?? 0
                hasCanvas = true
            } else if line.hasPrefix("Width: "), !hasCanvas {
                width = Int(line.dropFirst("Width: ".count)) ?? 0
            } else if line.hasPrefix("Height: "), !hasCanvas {
                height = Int(line.dropFirst("Height: ".count)) ?? 0
            } else if line == "Alpha: 1" || line.hasPrefix("Chunk ALPH") {
                hasAlpha = true
            } else if line == "Animation: 1" {
                isAnimated = true
            } else if line.hasPrefix("Format: Lossy") {
                hasLossy = true
            } else if line.hasPrefix("Format: Lossless") {
                hasLossless = true
            }
        }
    }

    var compression: String {
        switch (hasLossy, hasLossless) {
        case (true, true): "mixed"
        case (false, true): "lossless"
        default: "lossy"
        }
    }
}

/// Returns the hash of the RGBA samples in a PAM file written by `dwebp`.
func pixelHash(ofPAM url: URL) throws -> UInt64 {
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    guard let marker = data.range(of: Data("ENDHDR\n".utf8)) else {
        throw ToolFailure(description: "\(url.lastPathComponent) has no PAM header")
    }
    return data[marker.upperBound...].withUnsafeBytes(fnv1a)
}

/// Records what libwebp reports for every file in the conformance corpus.
///
/// Each line holds: file, status, width, height, compression, alpha, animated, pixel hash and,
/// for lossy images, the hash of the Y, U and V planes.
func generateGolden(corpus: URL, output: URL) throws {
    let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "webp" && !$0.lastPathComponent.hasPrefix("anim_") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var lines = ["# file\tstatus\twidth\theight\tcompression\talpha\tanimated\tpixels-fnv1a64\tyuv-fnv1a64"]

    try withTemporaryDirectory { work in
        let decoded = work.appendingPathComponent("decoded.pam")
        let planes = work.appendingPathComponent("decoded.yuv")
        for file in files {
            let name = file.lastPathComponent
            let info = try runTool("webpinfo", [file.path])
            let decode = try runTool("dwebp", ["-quiet", "-pam", file.path, "-o", decoded.path])

            guard info.succeeded, decode.succeeded else {
                lines.append("\(name)\tinvalid\t-\t-\t-\t-\t-\t-\t-")
                continue
            }

            let entry = ReferenceEntry(webpinfoOutput: info.output)
            let hash = String(try pixelHash(ofPAM: decoded), radix: 16)

            // `dwebp -yuv` writes Y, U and V planes, followed by an alpha plane when there is one.
            var planeHash = "-"
            if entry.compression == "lossy" {
                try requireTool("dwebp", ["-quiet", "-yuv", file.path, "-o", planes.path])
                let chromaCount = ((entry.width + 1) / 2) * ((entry.height + 1) / 2)
                let planeCount = entry.width * entry.height + 2 * chromaCount
                let data = try Data(contentsOf: planes)
                planeHash = String(data.prefix(planeCount).withUnsafeBytes(fnv1a), radix: 16)
            }
            lines.append(
                [
                    name, "ok", String(entry.width), String(entry.height), entry.compression,
                    String(entry.hasAlpha), String(entry.isAnimated), hash, planeHash,
                ]
                .joined(separator: "\t")
            )
        }
    }

    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: output)
    print("Recorded \(files.count) files in \(output.path)")
}
