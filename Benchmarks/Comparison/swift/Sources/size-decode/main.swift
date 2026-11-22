import RasterWebP

// The same program as size-empty, plus decoding, so the size difference is the decoder.
let bytes = Array(CommandLine.arguments.joined().utf8)
print(bytes.count)
if let image = try? WebPDecoder.decode(bytes) {
    print(image.width)
}
