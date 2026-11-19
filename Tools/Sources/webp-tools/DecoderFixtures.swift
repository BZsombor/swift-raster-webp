import Foundation

/// Regenerates the lossless files that are embedded in the decoder tests.
func generateDecoderFixtures(in output: URL) throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var generator = SplitMix64(state: 0x5241_5354_4552)

    func fixture(_ name: String) -> String {
        output.appendingPathComponent("\(name).webp").path
    }

    try withTemporaryDirectory { work in
        func encode(_ image: TestImage, _ name: String, _ arguments: [String] = []) throws {
            let source = work.appendingPathComponent("\(name).pam")
            try image.writePAM(to: source)
            try requireTool("cwebp", ["-quiet", "-lossless"] + arguments + [source.path, "-o", fixture(name)])
        }

        try encode(.gradient(width: 64, height: 48, translucent: false), "gradient")
        try encode(.gradient(width: 64, height: 48, translucent: true), "gradient_alpha", ["-exact"])
        for colorCount in [2, 4, 16, 256] {
            let image = TestImage.palette(width: 80, height: 60, colorCount: colorCount, generator: &generator)
            try encode(image, "palette_\(colorCount)")
        }
        try encode(.noise(width: 48, height: 48, generator: &generator, translucent: true), "noise", ["-z", "9"])
        try encode(.mixed(width: 256, height: 256, generator: &generator), "mixed", ["-z", "9"])
        try encode(.mixed(width: 96, height: 96, generator: &generator), "near_lossless", ["-near_lossless", "40"])

        let xmp = work.appendingPathComponent("metadata.xmp")
        try Data("<x:xmpmeta/>".utf8).write(to: xmp)
        try requireTool("webpmux", ["-set", "xmp", xmp.path, fixture("gradient"), "-o", fixture("extended")])
    }
}
