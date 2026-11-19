import Foundation

/// Regenerates the files that are embedded in the decoder tests.
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

        // Lossy files, small enough for the bit flip tests, that cover the encoder's main options.
        func encodeLossy(_ image: TestImage, _ name: String, _ arguments: [String]) throws {
            let source = work.appendingPathComponent("\(name).pam")
            try image.writePAM(to: source)
            try requireTool("cwebp", ["-quiet"] + arguments + [source.path, "-o", fixture(name)])
        }
        let photo = TestImage.mixed(width: 48, height: 40, generator: &generator)
        try encodeLossy(photo, "lossy_q75", ["-q", "75"])
        try encodeLossy(photo, "lossy_q95_sharpness", ["-q", "95", "-sharpness", "7", "-m", "6"])
        try encodeLossy(photo, "lossy_simple_filter", ["-q", "60", "-nostrong", "-f", "80"])
        try encodeLossy(photo, "lossy_no_filter", ["-q", "40", "-f", "0", "-segments", "1"])
        try encodeLossy(
            .noise(width: 33, height: 17, generator: &generator, translucent: false),
            "lossy_odd_size",
            ["-q", "20", "-segments", "4", "-sns", "100"]
        )

        let translucent = TestImage.gradient(width: 40, height: 24, translucent: true)
        try encodeLossy(translucent, "lossy_alpha_raw", ["-q", "70", "-alpha_method", "0"])
        try encodeLossy(translucent, "lossy_alpha_unfiltered", ["-q", "70", "-alpha_filter", "none"])
        try encodeLossy(translucent, "lossy_alpha_quantized", ["-q", "70", "-alpha_q", "30", "-alpha_filter", "fast"])

        // `-alpha_filter best` picks the filter that suits the alpha pattern: the horizontal
        // filter for a horizontal ramp, the vertical one for columns, and the gradient for a wave.
        func alphaPattern(_ alpha: @escaping (Int, Int) -> Int) -> TestImage {
            TestImage(width: 40, height: 24) { x, y in
                (UInt8((x * 5) % 256), UInt8((y * 9) % 256), 90, UInt8(truncatingIfNeeded: alpha(x, y)))
            }
        }
        try encodeLossy(translucent, "lossy_alpha_horizontal", ["-q", "70", "-alpha_filter", "best"])
        try encodeLossy(
            alphaPattern { x, y in (x * x * 37 + x * 11) % 251 + y },
            "lossy_alpha_vertical",
            ["-q", "70", "-alpha_filter", "best"]
        )
        try encodeLossy(
            alphaPattern { x, y in Int(127 + 120 * sin(Double(x) / 3) * cos(Double(y) / 4)) },
            "lossy_alpha_gradient",
            ["-q", "70", "-alpha_filter", "best"]
        )

        let xmp = work.appendingPathComponent("metadata.xmp")
        try Data("<x:xmpmeta/>".utf8).write(to: xmp)
        try requireTool("webpmux", ["-set", "xmp", xmp.path, fixture("gradient"), "-o", fixture("extended")])
    }
}
