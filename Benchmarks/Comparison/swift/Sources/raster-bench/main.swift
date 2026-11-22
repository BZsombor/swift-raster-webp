import BenchSupport
import RasterWebP

// RGBA with straight alpha is the decoder's default output.
Bench.main(
    decode: { bytes in
        let image = try WebPDecoder.decode(bytes)
        return (image.width, image.height)
    },
    rgba: { bytes in try WebPDecoder.decode(bytes).pixels }
)
