import Foundation

private let fixtureWidth = 33
private let fixtureHeight = 25

/// Writes a small gradient as a PAM image, which `cwebp` reads without extra libraries.
private func writePAM(to url: URL, translucent: Bool) throws {
    let header = """
        P7
        WIDTH \(fixtureWidth)
        HEIGHT \(fixtureHeight)
        DEPTH 4
        MAXVAL 255
        TUPLTYPE RGB_ALPHA
        ENDHDR

        """
    var data = Data(header.utf8)
    for y in 0..<fixtureHeight {
        for x in 0..<fixtureWidth {
            let alpha = translucent ? UInt8(x * 255 / (fixtureWidth - 1)) : 255
            data.append(contentsOf: [
                UInt8((x * 7) % 256), UInt8((y * 9) % 256), UInt8(((x + y) * 5) % 256), alpha,
            ])
        }
    }
    try data.write(to: url)
}

/// Regenerates the small WebP files that are embedded in the unit tests.
func generateFixtures(in output: URL) throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    func fixture(_ name: String) -> String {
        output.appendingPathComponent(name).path
    }

    try withTemporaryDirectory { work in
        let opaque = work.appendingPathComponent("opaque.pam")
        let translucent = work.appendingPathComponent("translucent.pam")
        try writePAM(to: opaque, translucent: false)
        try writePAM(to: translucent, translucent: true)

        let lossy = fixture("lossy.webp")
        let lossless = fixture("lossless.webp")
        try requireTool("cwebp", ["-quiet", "-q", "50", opaque.path, "-o", lossy])
        try requireTool("cwebp", ["-quiet", "-lossless", opaque.path, "-o", lossless])
        try requireTool(
            "cwebp",
            ["-quiet", "-lossless", "-exact", translucent.path, "-o", fixture("lossless_alpha.webp")]
        )
        try requireTool("cwebp", ["-quiet", "-q", "50", translucent.path, "-o", fixture("lossy_alpha.webp")])

        let icc = work.appendingPathComponent("profile.icc")
        let exif = work.appendingPathComponent("metadata.exif")
        let xmp = work.appendingPathComponent("metadata.xmp")
        try Data("test-icc-profile".utf8).write(to: icc)
        try Data("Exif\0\0test".utf8).write(to: exif)
        try Data("<x:xmpmeta/>".utf8).write(to: xmp)

        let withICC = work.appendingPathComponent("with_icc.webp").path
        let withEXIF = work.appendingPathComponent("with_exif.webp").path
        try requireTool("webpmux", ["-set", "icc", icc.path, lossy, "-o", withICC])
        try requireTool("webpmux", ["-set", "exif", exif.path, withICC, "-o", withEXIF])
        try requireTool("webpmux", ["-set", "xmp", xmp.path, withEXIF, "-o", fixture("metadata.webp")])

        try requireTool(
            "webpmux",
            [
                "-frame", lossy, "+100+0+0+1+b",
                "-frame", lossless, "+100+0+0+1+b",
                "-frame", lossy, "+100+0+0+1+b",
                "-loop", "3",
                "-bgcolor", "255,10,20,30",
                "-o", fixture("animated_mixed.webp"),
            ]
        )
    }
}
