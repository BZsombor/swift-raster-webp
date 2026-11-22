// image-webp writes RGB for opaque images, so RGBA output includes the expansion to four bytes.
use std::io::Cursor;

fn decode_rgba(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut decoder = image_webp::WebPDecoder::new(Cursor::new(bytes)).map_err(|e| e.to_string())?;
    let mut pixels = vec![0u8; decoder.output_buffer_size().ok_or("too large")?];
    decoder.read_image(&mut pixels).map_err(|e| e.to_string())?;
    Ok(if decoder.has_alpha() { pixels } else { bench_support::rgb_to_rgba(&pixels) })
}

fn main() {
    bench_support::main(
        |bytes| {
            let mut decoder = image_webp::WebPDecoder::new(Cursor::new(bytes)).map_err(|e| e.to_string())?;
            let size = decoder.dimensions();
            let mut pixels = vec![0u8; decoder.output_buffer_size().ok_or("too large")?];
            decoder.read_image(&mut pixels).map_err(|e| e.to_string())?;
            if !decoder.has_alpha() {
                std::hint::black_box(bench_support::rgb_to_rgba(&pixels));
            }
            Ok(size)
        },
        decode_rgba,
    );
}
